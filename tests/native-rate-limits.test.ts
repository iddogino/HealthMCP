import test from 'node:test';
import assert from 'node:assert/strict';
import {limitRequests,durableRateLimit,requestLimiters} from '../apps/worker/src/rate-limits';
import {authenticateDevice,sha256,bytes} from '../apps/worker/src/security';
import {upload,updateSeries,signedBlobURL,blob} from '../apps/worker/src/storage';
import {handleMcp} from '../apps/worker/src/mcp';
import {fixture,envelope,request} from './helpers/worker-fixture';
import {configuredLimiters,nativeRateLimitFixture} from './helpers/native-rate-limit-fixture';

test('production and local bindings cover every request class with isolated namespaces and matching limits',()=>{
  const expected=Object.values(requestLimiters).flat().sort();
  const prod=configuredLimiters('apps/worker/wrangler.jsonc'),local=configuredLimiters();
  assert.deepEqual(prod.map(x=>x.name).sort(),expected);assert.deepEqual(local.map(x=>x.name).sort(),expected);
  const ids=[...prod,...local].map(x=>x.namespace_id);assert.equal(new Set(ids).size,ids.length);
  for(const p of prod) {assert.deepEqual(p.simple,local.find(x=>x.name===p.name)!.simple);assert.equal(p.simple.period,60);assert.match(p.namespace_id,/^[1-9]\d*$/);}
  assert.deepEqual(prod.map(x=>x.simple.limit),[1200,12000,600,6000,300,3000,1200,12000]);
});
for(const kind of Object.keys(requestLimiters) as (keyof typeof requestLimiters)[]) {
  test(`${kind}: each user has a separate budget, and all users share the global key`,async()=>{
    const f=nativeRateLimitFixture(),[user,global]=requestLimiters[kind];
    f.setLimit(user,1);f.setLimit(global,2);
    await limitRequests(f.bindings,kind,'alice');
    await assert.rejects(limitRequests(f.bindings,kind,'alice'),(e:any)=>e.status===429 && e.retryAfter===60);
    assert.equal(f.calls.filter(x=>x.binding===global).length,1,'A blocked user must not drain the shared budget');
    await limitRequests(f.bindings,kind,'bob');
    await assert.rejects(limitRequests(f.bindings,kind,'charlie'),(e:any)=>e.status===429);
    assert.deepEqual([...new Set(f.calls.filter(x=>x.binding===global).map(x=>x.key))],[`${kind}:global`]);
    assert.deepEqual([...new Set(f.calls.filter(x=>x.binding===user).map(x=>x.key))],[`${kind}:user:alice`,`${kind}:user:bob`,`${kind}:user:charlie`]);
    f.advance(60);await limitRequests(f.bindings,kind,'alice');
  });
}
test('limiter outages and missing bindings reject work instead of falling back to database counters or bypassing limits',async()=>{
  for(const binding of requestLimiters.upload) {
    const f=fixture();f.throttles.fail(binding);
    await assert.rejects(upload(request(),f.env,f.user(),envelope()),(e:any)=>e.status===503 && e.retryAfter===5);
    assert.equal(f.objects.size,0);assert.equal(f.executedSQL.length,0);
  }
  await assert.rejects(limitRequests({} as any,'device','alice'),(e:any)=>e.status===503);
});

async function signedDevice(f:ReturnType<typeof fixture>) {
  const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
  f.db.prepare('UPDATE users SET device_pubkey=?').run(Buffer.from(await crypto.subtle.exportKey('raw',keys.publicKey)).toString('base64'));
  const sign=async(method:string,path:string,body='')=>{
    const timestamp=String(Math.floor(Date.now()/1000)),nonce=crypto.randomUUID();
    const canonical=[method,path,timestamp,nonce,await sha256(body)].join('\n');
    const signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},keys.privateKey,bytes(canonical))).toString('base64');
    return new Request('https://test.invalid'+path,{method,headers:{'content-type':'application/json','x-user-id':f.user().id,'x-timestamp':timestamp,'x-nonce':nonce,'x-signature':signature},...(body?{body}:{})});
  };
  return sign;
}
test('successful signed uploads execute five write statements with no D1 rate counters; replay remains atomic',async()=>{
  const f=fixture(),sign=await signedDevice(f),body=envelope();
  const incoming=await sign('PUT','/v1/upload?series=steps&period=2026-09-01',body);
  f.failAlways('INSERT INTO rate_limits');
  const user=await authenticateDevice(incoming,f.env,body);await upload(incoming,f.env,user,body);
  assert.equal(f.executedSQL.filter(sql=>/^\s*(INSERT|UPDATE|DELETE)\b/.test(sql)).length,5);
  assert.equal(f.executedSQL.some(sql=>sql.includes('rate_limits')),false);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM nonces').get()!.n,1);
  assert.equal(f.db.prepare("SELECT objects FROM quota_usage WHERE scope='global'").get()!.objects,1);
  await assert.rejects(authenticateDevice(incoming,f.env,body),(e:any)=>e.status===409);
  assert.equal(f.objects.size,1);
});
test('a forged device identity cannot spend the victim native budget',async()=>{
  const f=fixture(),sign=await signedDevice(f),incoming=await sign('GET','/v1/status');
  incoming.headers.set('x-signature','invalid');
  await assert.rejects(authenticateDevice(incoming,f.env,''),(e:any)=>e.status===401);
  assert.equal(f.throttles.calls.length,0);assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM nonces').get()!.n,0);
});
test('throttled device calls never claim a nonce',async()=>{
  const f=fixture(),sign=await signedDevice(f);f.throttles.setLimit('DEVICE_USER_LIMITER',0);
  await assert.rejects(authenticateDevice(await sign('GET','/v1/status'),f.env,''),(e:any)=>e.status===429 && e.retryAfter===60);
  assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM nonces').get()!.n,0);
});
test('MCP and downloads use their native bindings without writing rate counters',async()=>{
  const f=fixture(),user=f.user(),props={userId:user.id,connectionId:'test-connection',scope:['health:read']};
  f.db.prepare('INSERT INTO connections(id,user_id,client_id,client_name,created_at) VALUES(?,?,?,?,?)').run(props.connectionId,user.id,'test','Test',1);
  await upload(request(),f.env,user,envelope());
  await updateSeries(f.env,user,JSON.stringify({series:'workouts',first_day:'2026-09-01',last_day:'2026-09-01',total_samples:1}));
  f.failAlways('INSERT INTO rate_limits');
  const stored=f.db.prepare('SELECT object_key FROM chunks').get()!.object_key as string;
  const {url}=await signedBlobURL(f.env,user,props.connectionId,stored.slice(0,-4));
  assert.equal((await blob(new Request(url),f.env)).status,200);
  const mcpRequest=()=>new Request('https://test.invalid/mcp',{method:'POST',headers:{'content-type':'application/json',accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'Test',version:'1'}}})});
  assert.equal((await handleMcp(mcpRequest(),f.env,props)).status,200);
  for(const binding of [...requestLimiters.download,...requestLimiters.mcp]) assert.ok(f.throttles.calls.some(x=>x.binding===binding));
  f.throttles.setLimit('DOWNLOAD_USER_LIMITER',1);f.throttles.setLimit('MCP_GLOBAL_LIMITER',1);
  await assert.rejects(blob(new Request(url),f.env),(e:any)=>e.status===429);
  await assert.rejects(handleMcp(mcpRequest(),f.env,props),(e:any)=>e.status===429);
  assert.equal(f.executedSQL.some(sql=>sql.includes('rate_limits')),false);
});
test('long-window security limits still use durable counters',async()=>{
  const f=fixture();await durableRateLimit(f.env,`pair:${f.user().id}`,1,300);
  await assert.rejects(durableRateLimit(f.env,`pair:${f.user().id}`,1,300),(e:any)=>e.status===429 && e.retryAfter>0 && e.retryAfter<=300);
  assert.equal(f.throttles.calls.length,0);
});
