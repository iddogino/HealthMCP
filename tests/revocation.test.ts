import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomBytes} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {OAuthProvider,getOAuthApi,type OAuthProviderOptions} from '@cloudflare/workers-oauth-provider';
import {fixture} from './helpers/worker-fixture';
import {withOAuthStorage} from '../apps/worker/src/oauth-storage';
import {handleMcp} from '../apps/worker/src/mcp';
import {rejectRevokedRefresh} from '../apps/worker/src/index';
import {HttpError,type Env} from '../apps/worker/src/types';

const origin='https://test.invalid',redirect='http://127.0.0.1:18943/callback',connectionId='conn-1';
const ctx={waitUntil(){},passThroughOnException(){}} as unknown as ExecutionContext;
const noKV={async get(){return null;},async put(){},async delete(){},async list(){return {keys:[],list_complete:true,cursor:''};}} as unknown as KVNamespace;

function setup() {
  const f=fixture(),user=f.user();
  f.db.prepare('INSERT INTO connections(id,user_id,client_id,client_name,created_at) VALUES(?,?,?,?,?)').run(connectionId,user.id,'client','Claude',1);
  const raw:Env={...f.env,OAUTH_KV:noKV,OAUTH_STORAGE_MODE:'d1'};
  const options:OAuthProviderOptions<Env>={apiRoute:'/mcp',apiHandler:{fetch:async()=>Response.json({ok:true})},defaultHandler:{fetch:async()=>new Response('',{status:404})},
    authorizeEndpoint:'/authorize',tokenEndpoint:'/token',clientRegistrationEndpoint:'/register',allowPlainPKCE:false,allowImplicitFlow:false,
    scopesSupported:['health:read','offline_access'],accessTokenTTL:3600,refreshTokenTTL:90*86400,tokenExchangeCallback:rejectRevokedRefresh(raw)};
  const environment=()=>{const env=withOAuthStorage(raw);delete (env as Partial<Env>).OAUTH_PROVIDER;return env;};
  const provider=new OAuthProvider(options);
  const send=(path:string,init:RequestInit)=>provider.fetch(new Request(origin+path,init),environment(),ctx);
  const form=(body:Record<string,string>)=>send('/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({...body,resource:origin+'/mcp'})});
  async function pair() {
    const client=await (await send('/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'Claude',redirect_uris:[redirect],token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']})})).json() as {client_id:string};
    const verifier=Buffer.from(randomBytes(32)).toString('base64url'),challenge=createHash('sha256').update(verifier).digest('base64url');
    const helpers=getOAuthApi(options,environment());
    const request=await helpers.parseAuthRequest(new Request(origin+'/authorize?'+new URLSearchParams({client_id:client.client_id,redirect_uri:redirect,response_type:'code',scope:'health:read offline_access',code_challenge:challenge,code_challenge_method:'S256',resource:origin+'/mcp'})));
    const done=await helpers.completeAuthorization({request,userId:user.id,scope:request.scope,metadata:{connectionId},props:{userId:user.id,connectionId,scope:['health:read']},revokeExistingGrants:false});
    const tokens=await (await form({grant_type:'authorization_code',code:new URL(done.redirectTo).searchParams.get('code')!,client_id:client.client_id,redirect_uri:redirect,code_verifier:verifier})).json() as {refresh_token:string};
    return {clientId:client.client_id,refresh:tokens.refresh_token};
  }
  return {f,user,raw,form,pair};
}

test('refresh works while the connection is active and fails with invalid_grant after revocation',async()=>{
  const s=setup(),auth=await s.pair();
  const ok=await s.form({grant_type:'refresh_token',refresh_token:auth.refresh,client_id:auth.clientId});
  assert.equal(ok.status,200);
  const next=(await ok.json() as {refresh_token:string}).refresh_token;
  s.f.db.prepare('UPDATE connections SET revoked_at=1 WHERE id=?').run(connectionId);
  const denied=await s.form({grant_type:'refresh_token',refresh_token:next,client_id:auth.clientId});
  assert.equal(denied.status,400);
  assert.equal((await denied.json() as {error:string}).error,'invalid_grant');
});

test('refresh fails once the account is resetting or deleted',async()=>{
  const s=setup(),auth=await s.pair();
  s.f.db.prepare("UPDATE users SET state='resetting'").run();
  assert.equal((await s.form({grant_type:'refresh_token',refresh_token:auth.refresh,client_id:auth.clientId})).status,400);
});

test('MCP calls on a revoked connection revoke only that connection\'s grant',async()=>{
  const s=setup(),revoked:string[]=[];
  (s.f.env as any).OAUTH_PROVIDER={listUserGrants:async()=>({items:[{id:'g-1',metadata:{connectionId}},{id:'g-2',metadata:{connectionId:'other'}}]}),revokeGrant:async(id:string)=>{revoked.push(id);}};
  s.f.db.prepare('UPDATE connections SET revoked_at=1 WHERE id=?').run(connectionId);
  const req=new Request(origin+'/mcp',{method:'POST',headers:{'content-type':'application/json',accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/list'})});
  await assert.rejects(handleMcp(req,s.f.env,{userId:s.user.id,connectionId,scope:['health:read']}),(e:unknown)=>e instanceof HttpError&&e.status===401);
  assert.deepEqual(revoked,['g-1']);
});
