import assert from 'node:assert/strict';
import {Buffer} from 'node:buffer';
import {createHash,generateKeyPairSync,randomBytes,sign} from 'node:crypto';
import {execFileSync,spawn,type ChildProcess} from 'node:child_process';
import {once} from 'node:events';
import {closeSync,mkdtempSync,openSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {canonicalRequest} from '../packages/protocol/index';

// Exercise real native bindings and the HTTP error handler in workerd. All
// resources and reduced test budgets are isolated locally; never deploy this config.
const root=resolve('.'),scratch=mkdtempSync(join(tmpdir(),'healthmcp-rate-limits-'));
const configFile=join(scratch,'wrangler.json'),state=join(scratch,'state');
const logFile=join(scratch,'worker.log'),wrangler=join(root,'node_modules/wrangler/bin/wrangler.js');
let child:ChildProcess|undefined,logFD:number|undefined;
try {
  const socket=createServer();socket.listen(0,'127.0.0.1');await once(socket,'listening');
  const port=(socket.address() as {port:number}).port;await new Promise<void>(resolve=>socket.close(()=>resolve()));
  const base=`http://localhost:${port}`;
  const config=JSON.parse(readFileSync('apps/worker/wrangler.local.json','utf8'));
  delete config.$schema;
  config.name='healthmcp-rate-limit-test';config.main=join(root,'apps/worker/src/index.ts');
  config.vars.PUBLIC_ORIGIN=base;config.dev={host:`localhost:${port}`,port,upstream_protocol:'http'};
  for(const db of config.d1_databases) db.migrations_dir=join(root,'apps/worker/migrations');
  for(const [i,binding] of config.ratelimits.entries()) {
    binding.namespace_id=String(1780962501+i);
    if(binding.name==='UPLOAD_USER_LIMITER') binding.simple.limit=3;
    if(binding.name==='UPLOAD_GLOBAL_LIMITER') binding.simple.limit=5;
  }
  writeFileSync(configFile,JSON.stringify(config));
  execFileSync(process.execPath,[wrangler,'d1','migrations','apply','healthmcp-db','--local','--config',configFile,'--persist-to',state],{cwd:root,env:{...process.env,CI:'1'},input:'y\n',stdio:'pipe'});
  logFD=openSync(logFile,'w');
  child=spawn(process.execPath,[wrangler,'dev','--local','--config',configFile,'--persist-to',state,'--ip','127.0.0.1','--inspector-port','0'],{cwd:root,env:{...process.env,CI:'1'},stdio:['ignore',logFD,logFD]});
  let ready=false;
  for(let attempt=0;attempt<150;attempt++) {
    if(child.exitCode!==null || child.signalCode!==null) throw new Error('Local Worker exited before becoming ready');
    try {const response=await fetch(base+'/health',{signal:AbortSignal.timeout(500)});if(response.ok){ready=true;break;}} catch {}
    await delay(200);
  }
  assert.ok(ready,'Local Worker did not become ready');
  function device() {
    const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
    const raw=Buffer.from(publicKey.export({type:'spki',format:'der'}).subarray(-65)).toString('base64');
    let id='';
    const call=async(method:string,target:string,value?:unknown)=>{
      const body=value===undefined?'':JSON.stringify(value),timestamp=String(Math.floor(Date.now()/1000)),nonce=Buffer.from(randomBytes(18)).toString('base64url');
      const canonical=canonicalRequest(method,target,timestamp,nonce,createHash('sha256').update(body).digest('hex'));
      const signature=Buffer.from(sign('sha256',Buffer.from(canonical),{key:privateKey,dsaEncoding:'ieee-p1363'})).toString('base64');
      return fetch(base+target,{method,headers:{'Content-Type':'application/json','X-User-ID':id,'X-Timestamp':timestamp,'X-Nonce':nonce,'X-Signature':signature},...(body?{body}:{}),signal:AbortSignal.timeout(5000)});
    };
    return {call,async register(){const response=await call('POST','/v1/register',{device_pubkey:raw});assert.equal(response.status,201);id=(await response.json() as {id:string}).id;}};
  }
  const alice=device(),bob=device();await alice.register();await bob.register();
  // Keep this short burst clear of the minute boundary in the local simulator.
  const remaining=60_000-Date.now()%60_000;if(remaining<10_000) await delay(remaining+100);
  const target='/v1/upload?series=steps&period=2026-09-01';
  for(let i=0;i<3;i++) assert.equal((await alice.call('DELETE',target)).status,200);
  const perUser=await alice.call('DELETE',target);
  assert.equal(perUser.status,429);assert.equal(perUser.headers.get('Retry-After'),'60');
  assert.match((await perUser.json() as {error:string}).error,/Too many requests/);
  console.log('PASS native per-user limit returns HTTP 429 and Retry-After');
  for(let i=0;i<2;i++) assert.equal((await bob.call('DELETE',target)).status,200);
  console.log('PASS a second user has a separate allowance; a denied user does not consume the shared budget');
  const shared=await bob.call('DELETE',target);
  assert.equal(shared.status,429);assert.equal(shared.headers.get('Retry-After'),'60');
  console.log('PASS native shared key limits the combined upload traffic');
  for(const d of [alice,bob]) {
    assert.equal((await d.call('GET','/v1/status')).status,200);
    assert.equal((await d.call('DELETE','/v1/account')).status,200);
  }
  console.log('PASS status and account cleanup remain available when upload budgets are exhausted');
} catch(error) {
  if(logFD!==undefined) console.error(readFileSync(logFile,'utf8'));
  throw error;
} finally {
  if(child && child.exitCode===null && child.signalCode===null) {
    const exited=once(child,'exit');child.kill('SIGTERM');
    const timeout=setTimeout(()=>child?.kill('SIGKILL'),5000);
    await exited;clearTimeout(timeout);
  }
  if(logFD!==undefined) closeSync(logFD);
  rmSync(scratch,{recursive:true,force:true});
}
