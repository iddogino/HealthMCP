import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomBytes} from 'node:crypto';
import {Buffer} from 'node:buffer';
import {OAuthProvider,getOAuthApi,OAuthError,type OAuthProviderOptions} from '@cloudflare/workers-oauth-provider';
import {fixture} from './helpers/worker-fixture';
import {OAuthStateStorage,withOAuthStorage} from '../apps/worker/src/oauth-storage';
import type {Env} from '../apps/worker/src/types';
import worker from '../apps/worker/src/index';

function kvFixture() {
  const current=new Map<string,{value:string;expiration?:number}>(),visible=new Map<string,{value:string;expiration?:number}>();
  let stale=false;
  const kv={
    async get(key:string,options?:string|{type?:string}) {const value=visible.get(key)?.value;if(value===undefined)return null;return (typeof options==='string'?options:options?.type)==='json'?JSON.parse(value):value;},
    async put(key:string,value:string,options?:KVNamespacePutOptions) {
      const entry={value,expiration:options?.expiration??(options?.expirationTtl?Math.floor(Date.now()/1000)+options.expirationTtl:undefined)};
      current.set(key,entry);if(!stale||!key.startsWith('grant:')||!visible.has(key))visible.set(key,entry);
    },
    async delete(key:string){current.delete(key);visible.delete(key);},
    async list(options:{prefix?:string}={}){return {keys:[...current].filter(([key])=>key.startsWith(options.prefix??'')).map(([name,value])=>({name,expiration:value.expiration})),list_complete:true,cursor:''};}
  };
  return {kv:kv as unknown as KVNamespace,current,stallGrantWrites(){stale=true;}};
}
const origin='https://test.invalid',redirect='http://127.0.0.1:18943/callback';
const ctx={waitUntil(){},passThroughOnException(){}} as unknown as ExecutionContext;
const options:OAuthProviderOptions<Env>={apiRoute:'/mcp',apiHandler:{fetch:async()=>Response.json({ok:true})},defaultHandler:{fetch:async()=>new Response('Not found',{status:404})},authorizeEndpoint:'/authorize',tokenEndpoint:'/token',clientRegistrationEndpoint:'/register',allowPlainPKCE:false,allowImplicitFlow:false,scopesSupported:['health:read','offline_access'],accessTokenTTL:3600,refreshTokenTTL:90*86400};
function setup(mode:'kv'|'d1'='d1') {
  const f=fixture(),legacy=kvFixture();
  const raw:Env={...f.env,OAUTH_KV:legacy.kv,OAUTH_STORAGE_MODE:mode};
  const environment=()=>{const env=withOAuthStorage(raw);delete (env as Partial<Env>).OAUTH_PROVIDER;return env;};
  const provider=new OAuthProvider(options);
  const send=(path:string,init:RequestInit)=>provider.fetch(new Request(origin+path,init),environment(),ctx);
  const refresh=(token:string,clientId:string)=>send('/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:token,client_id:clientId,resource:origin+'/mcp'})});
  async function pair() {
    const registered=await send('/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'Synthetic storage regression',redirect_uris:[redirect],token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']})});
    assert.equal(registered.status,201);const client=await registered.json() as {client_id:string};
    const verifier=Buffer.from(randomBytes(32)).toString('base64url'),challenge=createHash('sha256').update(verifier).digest('base64url');
    const helpers=getOAuthApi(options,environment());
    const request=await helpers.parseAuthRequest(new Request(origin+'/authorize?'+new URLSearchParams({client_id:client.client_id,redirect_uri:redirect,response_type:'code',scope:'health:read offline_access',code_challenge:challenge,code_challenge_method:'S256',resource:origin+'/mcp'})));
    const completed=await helpers.completeAuthorization({request,userId:f.user().id,scope:request.scope,metadata:{synthetic:true},props:{userId:f.user().id},revokeExistingGrants:false});
    const code=new URL(completed.redirectTo).searchParams.get('code')!;
    const exchange=(codeVerifier:string)=>send('/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'authorization_code',code,client_id:client.client_id,redirect_uri:redirect,code_verifier:codeVerifier,resource:origin+'/mcp'})});
    assert.equal((await exchange('wrong-verifier')).status,400);
    const response=await exchange(verifier);assert.equal(response.status,200);
    const tokens=await response.json() as {access_token:string;refresh_token:string};
    return {clientId:client.client_id,...tokens};
  }
  return {...f,raw,legacy,environment,provider,send,refresh,pair};
}

test('reproduces first-refresh invalid_grant when KV serves the pre-exchange grant',async()=>{
  const s=setup('kv');s.legacy.stallGrantWrites();
  const auth=await s.pair();
  const failed=await s.refresh(auth.refresh_token,auth.clientId);
  assert.equal(failed.status,400);
  assert.deepEqual(await failed.json(),{error:'invalid_grant',error_description:'Invalid refresh token'});
});

test('D1 issues usable tokens through repeated rotations even with stale KV grant reads',async()=>{
  const s=setup();s.legacy.stallGrantWrites();
  const auth=await s.pair();let refreshToken=auth.refresh_token;
  for(let i=0;i<8;i++) {
    const response=await s.refresh(refreshToken,auth.clientId);assert.equal(response.status,200);
    const tokens=await response.json() as {access_token:string;refresh_token:string};refreshToken=tokens.refresh_token;
    assert.equal((await s.send('/mcp',{headers:{Authorization:'Bearer '+tokens.access_token}})).status,200);
  }
  assert.equal((await s.refresh(auth.refresh_token,auth.clientId)).status,400,'Old token outside the provider grace window stays invalid');
  assert.equal(s.legacy.current.size,0,'New OAuth records must never be written to eventually consistent KV');
});

test('D1 migration preserves existing access/refresh tokens, expiry and revocation',async()=>{
  const s=setup('kv'),auth=await s.pair();
  for(const [key,entry] of s.legacy.current) s.db.prepare('INSERT INTO oauth_state(key,value,expires_at) VALUES(?,?,?)').run(key,entry.value,entry.expiration??null);
  s.raw.OAUTH_STORAGE_MODE='d1';
  assert.equal((await s.send('/mcp',{headers:{Authorization:'Bearer '+auth.access_token}})).status,200);
  const response=await s.refresh(auth.refresh_token,auth.clientId);assert.equal(response.status,200);
  const tokens=await response.json() as {access_token:string;refresh_token:string};
  const grants=await getOAuthApi(options,s.environment()).listUserGrants(s.user().id,{limit:1});
  assert.equal(grants.items.length,1);
  await getOAuthApi(options,s.environment()).revokeGrant(grants.items[0].id,s.user().id);
  assert.equal((await s.send('/mcp',{headers:{Authorization:'Bearer '+tokens.access_token}})).status,401);
  assert.equal((await s.refresh(tokens.refresh_token,auth.clientId)).status,400);
  assert.ok(s.legacy.current.size>0,'Stale legacy copies must not resurrect revoked authority');
});

test('competing grant writes and revocation cannot overwrite a committed revision',async()=>{
  const {env}=fixture(),legacy=kvFixture(),key='grant:u:one';
  const first=new OAuthStateStorage(env.DB,legacy.kv,'d1'),second=new OAuthStateStorage(env.DB,legacy.kv,'d1');
  await first.put(key,'{"step":0}');
  await second.get(key,'json');await first.get(key,'json');
  await first.put(key,'{"step":1}');
  await assert.rejects(second.put(key,'{"step":2}'),(error:unknown)=>error instanceof OAuthError&&error.code==='temporarily_unavailable');
  assert.deepEqual(await new OAuthStateStorage(env.DB,legacy.kv,'d1').get(key,'json'),{step:1});
  await second.get(key,'json');await first.delete(key);
  await assert.rejects(second.put(key,'{"step":3}'),OAuthError);
});

test('grant revocation fences token issuance even after an earlier token listing',async()=>{
  const {env}=fixture(),legacy=kvFixture();
  const issuer=new OAuthStateStorage(env.DB,legacy.kv,'d1'),revoker=new OAuthStateStorage(env.DB,legacy.kv,'d1');
  await issuer.put('grant:u:one','{}');
  assert.equal((await revoker.list({prefix:'token:u:one:'})).keys.length,0);
  await issuer.put('token:u:one:first','{}');
  await revoker.delete('grant:u:one');
  assert.equal(await issuer.get('token:u:one:first'),null);
  await assert.rejects(issuer.put('token:u:one:late','{}'),OAuthError);
});

test('expired entries and tombstones stay absent; paginated deletion covers every grant/token',async()=>{
  const {env}=fixture(),legacy=kvFixture();let now=1000;
  const storage=new OAuthStateStorage(env.DB,legacy.kv,'d1',()=>now);
  for(let i=0;i<5;i++) await storage.put('grant:u:'+i,'{}',{expirationTtl:i===0?1:100});
  await storage.put('grant:other:0','{}');await storage.delete('grant:u:1');now+=2;
  let cursor:string|undefined,seen:string[]=[];
  do {
    const page=await storage.list({prefix:'grant:u:',limit:1,cursor});
    for(const key of page.keys){seen.push(key.name);await storage.delete(key.name);}
    cursor=page.list_complete?undefined:page.cursor;
  }while(cursor);
  assert.deepEqual(seen,['grant:u:2','grant:u:3','grant:u:4']);
  assert.equal(await storage.get('grant:u:0'),null);
  assert.deepEqual(await storage.get('grant:other:0','json'),{});
});

test('migration freezes OAuth issuance but preserves existing access and fences deletes against import',async()=>{
  const s=setup('kv'),auth=await s.pair();s.raw.OAUTH_STORAGE_MODE='migrating';
  for(const path of ['/token','/register','/authorize/poll']) {
    const response=await worker.fetch(new Request(origin+path,{method:'POST'}),s.raw,ctx);
    assert.equal(response.status,503);assert.equal(response.headers.get('Retry-After'),'60');
    assert.equal((await response.json() as {error:string}).error,'temporarily_unavailable');
  }
  assert.equal((await s.send('/mcp',{headers:{Authorization:'Bearer '+auth.access_token}})).status,200);
  const key=[...s.legacy.current.keys()].find(key=>key.startsWith('grant:'))!,snapshot=s.legacy.current.get(key)!;
  await new OAuthStateStorage(s.env.DB,s.legacy.kv,'migrating').delete(key);
  s.db.prepare('INSERT OR IGNORE INTO oauth_state(key,value,expires_at) VALUES(?,?,?)').run(key,snapshot.value,snapshot.expiration??null);
  assert.equal(await new OAuthStateStorage(s.env.DB,s.legacy.kv,'d1').get(key),null);
});
