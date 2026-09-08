import assert from 'node:assert/strict';
import {Buffer} from 'node:buffer';
import {createCipheriv,createHash,generateKeyPairSync,randomBytes,sign} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {writeFileSync,mkdirSync} from 'node:fs';
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import {canonicalRequest,checksum,objectPath,type Envelope} from '../packages/protocol/index';
// @ts-expect-error Reference deliberately ships as dependency-free JavaScript.
import {decrypt} from '../packages/protocol/decrypt.mjs';

const base=process.env.HEALTHMCP_BASE_URL??'http://localhost:8787';
const checks:string[]=[];
const passed=(name:string)=>{checks.push(name);console.log('PASS '+name);};
const hash=(data:string)=>createHash('sha256').update(data).digest('hex');
function device() {
  const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
  const raw=Buffer.from(publicKey.export({type:'spki',format:'der'}).subarray(-65)).toString('base64');
  let id='';
  const signed=(method:string,target:string,value?:unknown)=>{
    const body=value===undefined?'':JSON.stringify(value),timestamp=String(Math.floor(Date.now()/1000)),nonce=Buffer.from(randomBytes(18)).toString('base64url');
    const signature=Buffer.from(sign('sha256',Buffer.from(canonicalRequest(method,target,timestamp,nonce,hash(body))),{key:privateKey,dsaEncoding:'ieee-p1363'})).toString('base64');
    return {method,headers:{'Content-Type':'application/json','X-User-ID':id,'X-Timestamp':timestamp,'X-Nonce':nonce,'X-Signature':signature},...(body?{body}:{})};
  };
  const call=async(method:string,target:string,value?:unknown)=>fetch(base+target,signed(method,target,value));
  return {signed,call,get id(){return id},async register(){const response=await call('POST','/v1/register',{device_pubkey:raw});assert.equal(response.status,201);const data=await response.json() as {id:string};id=data.id;return id;}};
}
const keyPayload=Array.from(randomBytes(16),b=>'0123456789ABCDEFGHJKMNPQRSTVWXYZ'[b&31]).join('');
const userKey=keyPayload+checksum(keyPayload);
function encrypt(value:unknown,path:string):Envelope {
  const iv=randomBytes(12),key=createHash('sha256').update('healthmcp/v1:'+userKey).digest(),aes=createCipheriv('aes-256-gcm',key,iv);
  aes.setAAD(Buffer.from(path));const ct=Buffer.concat([aes.update(gzipSync(Buffer.from(JSON.stringify(value)))),aes.final(),aes.getAuthTag()]);
  return {v:1,alg:'A256GCM',kdf:'sha256',iv:Buffer.from(iv).toString('base64'),ct:ct.toString('base64')};
}
async function pair(d:ReturnType<typeof device>) {
  const verifier=Buffer.from(randomBytes(32)).toString('base64url'),challenge=createHash('sha256').update(verifier).digest('base64url');
  const redirect='http://localhost:18943/callback';
  const registration=await fetch(base+'/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'Health MCP E2E (synthetic)',redirect_uris:[redirect],token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']})});
  assert.equal(registration.status,201);
  const client=await registration.json() as {client_id:string};
  const params=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:redirect,scope:'health:read offline_access',state:'e2e-state',code_challenge:challenge,code_challenge_method:'S256',resource:base+'/mcp'});
  const auth=await fetch(base+'/authorize?'+params);assert.equal(auth.status,200);
  const html=await auth.text(),cookie=auth.headers.get('set-cookie')!.split(';')[0];
  const code=html.match(/id="pairing-code">(\d{3}) (\d{3})/)!.slice(1).join('');
  const pairingId=JSON.parse(html.match(/const pairingId=("[^"]+")/)![1]);
  const preview=await d.call('POST','/v1/pair/preview',{code});assert.equal(preview.status,200);const details=await preview.json() as {pairing_id:string;client_name:string};
  assert.equal(details.client_name,'Health MCP E2E (synthetic)');
  const noConsent=await d.call('POST','/v1/pair/approve',{code});assert.equal(noConsent.status,409);
  const approval=await d.call('POST','/v1/pair/approve',{code,pairing_id:details.pairing_id});assert.equal(approval.status,200);
  const unauthorized=await fetch(base+'/authorize/poll',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:pairingId})});assert.equal(unauthorized.status,403);
  const poll=await fetch(base+'/authorize/poll',{method:'POST',headers:{'Content-Type':'application/json',cookie},body:JSON.stringify({id:pairingId})});assert.equal(poll.status,200);
  const {redirect_to}=await poll.json() as {redirect_to:string};const callback=new URL(redirect_to);assert.equal(callback.searchParams.get('state'),'e2e-state');
  const tokenRequest=(codeVerifier:string)=>fetch(base+'/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'authorization_code',client_id:client.client_id,code:callback.searchParams.get('code')!,redirect_uri:redirect,code_verifier:codeVerifier,resource:base+'/mcp'})});
  const wrong=await tokenRequest('wrong-verifier');assert.equal(wrong.status,400);
  const token=await tokenRequest(verifier);assert.equal(token.status,200);const tokens=await token.json() as {access_token:string;refresh_token:string};
  return {...tokens,connectionId:pairingId,clientId:client.client_id};
}
const primary=device(),other=device();
try {
  const health=await fetch(base+'/health');assert.equal(health.status,200);passed('Worker + D1 health');
  const unauth=await fetch(base+'/mcp',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});assert.equal(unauth.status,401);assert.match(unauth.headers.get('www-authenticate')??'',/resource_metadata/);passed('OAuth discovery and unauthenticated MCP rejection');
  const discovery=await fetch(base+'/.well-known/oauth-protected-resource');assert.equal(discovery.status,200);assert.equal((await discovery.json() as {resource:string}).resource,base+'/mcp');
  await primary.register();await other.register();passed('P-256 device registration and proof of possession');
  const replay=primary.signed('GET','/v1/status');assert.equal((await fetch(base+'/v1/status',replay)).status,200);assert.equal((await fetch(base+'/v1/status',replay)).status,409);passed('Atomic replay rejection');
  const forged=other.signed('GET','/v1/status');forged.headers['X-User-ID']=primary.id;assert.equal((await fetch(base+'/v1/status',forged)).status,401);passed('Cross-user device isolation');
  const fixture=[{t0:'2026-09-01T06:00:00Z',t1:'2026-09-01T07:00:00Z',v:812,src:'E2E synthetic'}];
  for(const [series,period,value] of [['check','single','ok'],['steps','2026-09-01',fixture],['body_mass','2026-09',[{t:'2026-09-01T12:00:00Z',v:72,src:'E2E synthetic'}]],['profile','single',{biological_sex:'notSet'}],['daily_summary','2026-09',[{d:'2026-09-01',steps:812}]],['workouts','2026-09-01/00000000-0000-4000-8000-000000000001',{type:'running',duration_s:60,route:[]}]] as const) {
    const envelope=encrypt(value,objectPath(primary.id,series,period));const response=await primary.call('PUT','/v1/upload?'+new URLSearchParams({series,period}),envelope);assert.equal(response.status,200,await response.text());
    if(series!=='check') assert.equal((await primary.call('PUT','/v1/series',{series,first_day:'2026-09-01',last_day:'2026-09-01',total_samples:1})).status,200);
  }
  assert.equal((await primary.call('POST','/v1/sync/complete',{})).status,200);passed('Encrypted daily, monthly, workout, profile, summary and key-check uploads');
  const plaintext=await primary.call('PUT','/v1/upload?series=steps&period=2026-09-02',{v:812});assert.equal(plaintext.status,400);
  const traversal=await primary.call('PUT','/v1/upload?series=steps&period=..%2Fprofile',encrypt(fixture,primary.id+'/steps'));assert.equal(traversal.status,400);passed('Plaintext and path traversal rejection');
  const auth=await pair(primary);passed('Consent pairing, browser binding, PKCE and token exchange');
  const client=new Client({name:'healthmcp-e2e',version:'1.0.0'});
  await client.connect(new StreamableHTTPClientTransport(new URL(base+'/mcp'),{requestInit:{headers:{Authorization:'Bearer '+auth.access_token}}}));
  assert.equal((await client.listTools()).tools.length,6);assert.match(client.getInstructions()??'',/Never ask for the key/);passed('Official MCP SDK initialize and tool discovery');
  const resultData=(r:any)=>r.structuredContent??JSON.parse(r.content[0].text);
  const catalog=resultData(await client.callTool({name:'list_series',arguments:{}}));assert.equal(catalog.series.length,5);
  const check=await (await fetch(catalog.check_url)).json();assert.equal(decrypt(check,userKey,catalog.check_path),'ok');passed('Local key-check decryption');
  const manifest=resultData(await client.callTool({name:'get_samples',arguments:{series:'steps',start:'2026-09-01',end:'2026-09-01'}}));assert.equal(manifest.chunks.length,1);
  const chunk=manifest.chunks[0],envelope=await (await fetch(chunk.url)).json();assert.deepEqual(decrypt(envelope,userKey,chunk.path),fixture);assert.throws(()=>decrypt(envelope,userKey,chunk.path+'x'));passed('Sandbox decryption, gzip, source values, and AAD authentication');
  const empty=resultData(await client.callTool({name:'get_samples',arguments:{series:'steps',start:'2026-08-01',end:'2026-08-31'}}));assert.equal(empty.chunks.length,0);
  for(const name of ['get_workouts','get_daily_summary','get_profile']) {const result=resultData(await client.callTool({name,arguments:name==='get_profile'?{}:{start:'2026-09-01',end:'2026-09-01'}}));assert.equal(result.chunks.length,1);}
  assert.equal((await client.readResource({uri:'health://decrypt/node'})).contents.length,1);
  assert.equal((await client.readResource({uri:'health://decrypt/python'})).contents.length,1);passed('All read tools, exact range resolution, and reference resources');
  const sync=resultData(await client.callTool({name:'request_sync',arguments:{}}));assert.equal(sync.push_status,'device_not_registered');passed('Honest best-effort sync response when push is unavailable');
  const pending=async()=>((await (await primary.call('GET','/v1/status')).json()) as {pending_sync_at:number|null}).pending_sync_at;
  assert.ok(await pending());
  for(const [series,value] of [['check','ok'],['profile',{biological_sex:'notSet'}]] as const) {
    assert.equal((await primary.call('PUT','/v1/upload?'+new URLSearchParams({series,period:'single'}),encrypt(value,objectPath(primary.id,series,'single')))).status,200);
    assert.ok(await pending());
  }
  assert.equal((await primary.call('PUT','/v1/upload?series=steps&period=2026-09-01',encrypt(fixture,objectPath(primary.id,'steps','2026-09-01')))).status,200);
  assert.equal(await pending(),null);passed('Key-check and profile uploads preserve the push fallback until health data arrives');
  await primary.call('POST','/v1/sync/complete',{});
  assert.equal(resultData(await client.callTool({name:'request_sync',arguments:{}})).push_status,'already_requested');passed('Sync request throttle survives completed uploads');
  const refresh=await fetch(base+'/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:auth.refresh_token,client_id:auth.clientId,resource:base+'/mcp'})});assert.equal(refresh.status,200);passed('OAuth refresh-token flow');
  await primary.call('DELETE','/v1/upload?series=steps&period=2026-09-01');assert.equal((await fetch(chunk.url)).status,404);passed('HealthKit deletion propagation');
  assert.equal((await primary.call('DELETE','/v1/series?series=body_mass')).status,200);
  assert.equal(resultData(await client.callTool({name:'get_samples',arguments:{series:'body_mass',start:'2026-09-01',end:'2026-09-30'}})).chunks.length,0);
  assert.equal(resultData(await client.callTool({name:'list_series',arguments:{}})).series.some((s:any)=>s.series==='body_mass'),false);passed('Disabling an optional series removes its chunks and catalog');
  await primary.call('DELETE','/v1/connections/'+auth.connectionId);assert.equal((await fetch(catalog.check_url)).status,403);
  const revoked=await fetch(base+'/mcp',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+auth.access_token},body:'{}'});assert.equal(revoked.status,401);passed('Immediate connection and signed-download revocation');
  await client.close();
  assert.equal((await primary.call('POST','/v1/cache/reset',{})).status,200);const status=await (await primary.call('GET','/v1/status')).json() as any;assert.equal(status.usage.chunks,0);assert.equal(status.cache_generation,2);passed('Cache rotation clears catalog and advances generation');
  if(process.env.HEALTHMCP_TEST_APNS==='1') {
    for(const environment of ['sandbox','production']) {
      const pushDevice=device(); await pushDevice.register();
      try {
        assert.equal((await pushDevice.call('POST','/v1/apns',{token:'0'.repeat(64),environment})).status,200);
        const connection=await pair(pushDevice);
        const probe=new Client({name:'healthmcp-apns-probe',version:'1.0.0'});
        await probe.connect(new StreamableHTTPClientTransport(new URL(base+'/mcp'),{requestInit:{headers:{Authorization:'Bearer '+connection.access_token}}}));
        const response=resultData(await probe.callTool({name:'request_sync',arguments:{}}));
        assert.equal(response.push_status,'apns_BadDeviceToken',JSON.stringify(response));
        await probe.close(); passed('APNs '+environment+' endpoint accepts the request format and rejects a synthetic device token');
      } finally { assert.equal((await pushDevice.call('DELETE','/v1/account')).status,200); }
    }
  }
} finally {
  for(const d of [primary,other]) if(d.id) {const response=await d.call('DELETE','/v1/account');assert.equal(response.status,200);}
  passed('Synthetic test accounts and encrypted data cleaned up');
  mkdirSync('artifacts',{recursive:true});writeFileSync('artifacts/e2e-'+new URL(base).hostname+'.json',JSON.stringify({base,completed_at:new Date().toISOString(),checks},null,2));
}
console.log(`\n${checks.length} end-to-end checks passed against ${base}`);
