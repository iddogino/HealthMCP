import assert from 'node:assert/strict';
import {Buffer} from 'node:buffer';
import {createCipheriv,createHash,generateKeyPairSync,randomBytes,sign} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {mkdirSync,writeFileSync} from 'node:fs';
import {dirname} from 'node:path';
import {canonicalRequest} from '../packages/protocol/index';

// Explicit target only. Uses a disposable synthetic account, no real health
// data, and removes its account and objects even when a measurement fails.
const base=process.env.HEALTHMCP_BASE_URL;
if(!base) throw new Error('Set HEALTHMCP_BASE_URL explicitly');
const output=process.argv[2];
if(!output) throw new Error('Pass an output JSON path');
const concurrency=Number(process.env.BENCH_CONCURRENCY??4);
assert.ok([4,8].includes(concurrency),'BENCH_CONCURRENCY must be 4 or 8');
const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const pub=Buffer.from(publicKey.export({type:'spki',format:'der'}).subarray(-65)).toString('base64');
const key=randomBytes(32);
let id='';
type Timing={ms:number;bytes:number;server:Record<string,number>};
async function call(method:string,path:string,value?:unknown):Promise<{data:any;timing:Timing}> {
  const body=value===undefined?'':JSON.stringify(value),timestamp=String(Math.floor(Date.now()/1000)),nonce=Buffer.from(randomBytes(18)).toString('base64url');
  const signature=Buffer.from(sign('sha256',Buffer.from(canonicalRequest(method,path,timestamp,nonce,createHash('sha256').update(body).digest('hex'))),{key:privateKey,dsaEncoding:'ieee-p1363'})).toString('base64');
  const start=performance.now();
  const response=await fetch(base+path,{method,headers:{'Content-Type':'application/json','X-User-ID':id,'X-Timestamp':timestamp,'X-Nonce':nonce,'X-Signature':signature,'X-Sync-Metrics':'1'},...(body?{body}:{}),signal:AbortSignal.timeout(90_000)});
  const data=await response.json();
  assert.ok(response.ok,`${method} ${path.split('?')[0]} returned ${response.status}`);
  const server:Record<string,number>={};
  for(const match of (response.headers.get('server-timing')??'').matchAll(/([\w_]+);dur=([\d.]+)/g)) server[match[1]]=Number(match[2]);
  return {data,timing:{ms:performance.now()-start,bytes:Buffer.byteLength(body),server}};
}
function payload(period:string) {
  const iv=randomBytes(12),aes=createCipheriv('aes-256-gcm',key,iv);
  aes.setAAD(Buffer.from(`${id}/steps/${period}`));
  const plain=JSON.stringify({synthetic:true,padding:Buffer.from(randomBytes(2800)).toString('base64')});
  const ct=Buffer.concat([aes.update(gzipSync(Buffer.from(plain))),aes.final(),aes.getAuthTag()]);
  return {v:1,alg:'A256GCM',kdf:'sha256',iv:Buffer.from(iv).toString('base64'),ct:ct.toString('base64')};
}
function summary(samples:Timing[],elapsed:number) {
  const sorted=samples.map(s=>s.ms).sort((a,b)=>a-b);
  const names=[...new Set(samples.flatMap(s=>Object.keys(s.server)))];
  return {requests:samples.length,seconds:elapsed/1000,requests_per_second:samples.length/(elapsed/1000),mean_ms:sorted.reduce((a,b)=>a+b,0)/sorted.length,p50_ms:sorted[Math.floor(sorted.length*0.5)],p95_ms:sorted[Math.floor(sorted.length*0.95)],mean_bytes:samples.reduce((a,b)=>a+b.bytes,0)/samples.length,server_mean_ms:Object.fromEntries(names.map(n=>[n,samples.reduce((a,b)=>a+(b.server[n]??0),0)/samples.length]))};
}
const measurements:Record<string,unknown>={};
let cleaned=false;
try {
  id=(await call('POST','/v1/register',{device_pubkey:pub})).data.id;
  for(const [name,method] of [['new','PUT'],['replacement','PUT'],['empty_delete','DELETE']] as const) {
    const samples:Timing[]=[],start=performance.now();
    for(let offset=0;offset<24;offset+=concurrency) {
      const batch=await Promise.allSettled(Array.from({length:concurrency},async(_,j)=>{
        const period=`2026-08-${String(offset+j+1).padStart(2,'0')}`;
        const target=method==='DELETE'?period.replace('08','07'):period;
        return (await call(method,'/v1/upload?'+new URLSearchParams({series:'steps',period:target,first_day:target,last_day:target}),method==='PUT'?payload(period):undefined)).timing;
      }));
      for(const result of batch) { if(result.status==='rejected') throw result.reason;samples.push(result.value); }
    }
    measurements[name]=summary(samples,performance.now()-start);
    console.log(name,JSON.stringify(measurements[name]));
  }
  const samples:Timing[]=[],start=performance.now();
  for(let i=0;i<8;i++) samples.push((await call('PUT','/v1/series',{series:'steps',first_day:'2026-08-01',last_day:'2026-08-24',total_samples:24})).timing);
  measurements.catalog=summary(samples,performance.now()-start);
  console.log('catalog',JSON.stringify(measurements.catalog));
} finally {
  if(id) { await call('DELETE','/v1/account'); cleaned=true; }
  mkdirSync(dirname(output),{recursive:true});
  writeFileSync(output,JSON.stringify({at:new Date().toISOString(),base,concurrency,cleaned,measurements},null,2)+'\n');
}
