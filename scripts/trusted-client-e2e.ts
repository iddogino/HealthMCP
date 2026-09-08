import assert from 'node:assert/strict';
import {generateKeyPairSync,randomBytes,createHash,createCipheriv,sign} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StdioClientTransport} from '@modelcontextprotocol/sdk/client/stdio.js';
import {checksum,canonicalRequest,objectPath} from '../packages/protocol/index';
const base=process.env.HEALTHMCP_BASE_URL??'http://localhost:8787';
const directory=mkdtempSync(join(tmpdir(),'healthmcp-client-e2e-'));
const bundle=resolve('artifacts/trusted-client/healthmcp-client.mjs');
const env=Object.fromEntries(Object.entries({...process.env,HEALTHMCP_CONFIG_DIR:directory,HEALTHMCP_ORIGIN:base,HEALTHMCP_NO_BROWSER:'1'}).filter((e):e is [string,string]=>typeof e[1]==='string' && e[0]!=='HEALTHMCP_KEY'));
const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
let id='',child:ReturnType<typeof spawn>|undefined,local:Client|undefined;
const keyPayload=Array.from(randomBytes(26),b=>'0123456789ABCDEFGHJKMNPQRSTVWXYZ'[b&31]).join(''),key=keyPayload+checksum(keyPayload);
async function device(method:string,path:string,value?:unknown) {
  const body=value===undefined?'':JSON.stringify(value),timestamp=String(Math.floor(Date.now()/1000)),nonce=Buffer.from(randomBytes(18)).toString('base64url');
  const canonical=canonicalRequest(method,path,timestamp,nonce,createHash('sha256').update(body).digest('hex'));
  const signature=Buffer.from(sign('sha256',Buffer.from(canonical),{key:privateKey,dsaEncoding:'ieee-p1363'})).toString('base64');
  return fetch(base+path,{method,headers:{'content-type':'application/json','x-user-id':id,'x-timestamp':timestamp,'x-nonce':nonce,'x-signature':signature},...(body?{body}:{})});
}
function encrypted(value:unknown,path:string){const iv=randomBytes(12),aes=createCipheriv('aes-256-gcm',createHash('sha256').update('healthmcp/v2:'+key).digest(),iv);aes.setAAD(Buffer.from(path));const ct=Buffer.concat([aes.update(gzipSync(JSON.stringify(value))),aes.final(),aes.getAuthTag()]);return {v:1,alg:'A256GCM',kdf:'sha256',iv:Buffer.from(iv).toString('base64'),ct:ct.toString('base64')};}
try {
  const registration=await device('POST','/v1/register',{device_pubkey:Buffer.from(publicKey.export({type:'spki',format:'der'}).subarray(-65)).toString('base64')});assert.equal(registration.status,201);id=(await registration.json() as any).id;
  for(const [series,period,data] of [['check','single','ok'],['daily_summary','2026-09',[{d:'2026-09-01',steps:812}]]] as const){
    const response=await device('PUT','/v1/upload?'+new URLSearchParams({series,period,first_day:'2026-09-01',last_day:'2026-09-01'}),encrypted(data,objectPath(id,series,period)));assert.equal(response.status,200);
  }
  assert.equal((await device('PUT','/v1/series',{series:'daily_summary',first_day:'2026-09-01',last_day:'2026-09-01',total_samples:1})).status,200);
  child=spawn(process.execPath,[bundle,'connect'],{env,stdio:['ignore','pipe','pipe']});
  const finished=new Promise<number|null>(resolve=>child!.once('exit',resolve));
  const authorization=await new Promise<string>((resolve,reject)=>{
    let stderr='';const timer=setTimeout(()=>reject(new Error('No authorization URL from client')),30_000);
    child!.stderr!.on('data',data=>{
      stderr+=data.toString();
      const match=stderr.match(/https?:\/\/[^\s]+/g)?.find(value=>{const url=new URL(value);return url.origin===new URL(base).origin && url.pathname==='/authorize';});
      if(match){clearTimeout(timer);resolve(match);}
    });
    child!.once('exit',code=>{clearTimeout(timer);if(code!==0)reject(new Error('Client connection failed before authorization: '+stderr));});
  });
  const auth=await fetch(authorization),html=await auth.text(),cookie=auth.headers.get('set-cookie')!.split(';')[0];
  const code=html.match(/id="pairing-code">(\d{3}) (\d{3})/)!.slice(1).join(''),pairingId=JSON.parse(html.match(/const pairingId=("[^"]+")/)![1]);
  const preview=await device('POST','/v1/pair/preview',{code});assert.equal(preview.status,200);assert.equal((await preview.json() as any).client_name,'Health MCP Private Client');
  assert.equal((await device('POST','/v1/pair/approve',{code,pairing_id:pairingId})).status,200);
  const poll=await fetch(base+'/authorize/poll',{method:'POST',headers:{cookie,'Content-Type':'application/json'},body:JSON.stringify({id:pairingId})});assert.equal(poll.status,200);
  const {redirect_to}=await poll.json() as any;assert.equal((await fetch(redirect_to)).status,200);assert.equal(await finished,0);child=undefined;
  console.log('PASS distributed client OAuth browser flow, phone consent, callback state and PKCE');
  await new Promise<void>((resolve,reject)=>{
    const save=spawn(process.execPath,[bundle,'key'],{env,stdio:['pipe','ignore','pipe']});save.once('exit',code=>code===0?resolve():reject(new Error('Key setup failed')));save.stdin!.end(key);
  });
  const checked=await promisify(execFile)(process.execPath,[bundle,'check'],{env,timeout:30_000});assert.match(checked.stderr,/local decryption verified/);assert.equal(checked.stderr.includes(key),false);
  console.log('PASS private key setup and decryption check without key output');
  // Force an invalid access token while retaining the valid refresh token.
  const connection=JSON.parse(readFileSync(join(directory,'connection.json'),'utf8'));assert.ok(connection.tokens.refresh_token);connection.tokens.access_token='synthetic-expired-token';writeFileSync(join(directory,'connection.json'),JSON.stringify(connection),{mode:0o600});
  local=new Client({name:'Health MCP distributed client test',version:'1.0.0'});
  const transport=new StdioClientTransport({command:process.execPath,args:[bundle],env,stderr:'pipe'});await local.connect(transport);
  assert.equal((await local.listTools()).tools.length,6);
  const result=await local.callTool({name:'get_daily_summary',arguments:{start:'2026-09-01',end:'2026-09-01'}});assert.equal(result.isError,undefined);
  const value=JSON.parse((result.content as any)[0].text);assert.deepEqual(value.records,[{d:'2026-09-01',steps:812}]);
  const refreshed=JSON.parse(readFileSync(join(directory,'connection.json'),'utf8'));assert.notEqual(refreshed.tokens.access_token,'synthetic-expired-token');
  console.log('PASS actual stdio tool discovery, OAuth refresh and locally decrypted results');
  assert.equal((await device('DELETE','/v1/connections/'+pairingId)).status,200);
  const revoked=await local.callTool({name:'get_daily_summary',arguments:{start:'2026-09-01',end:'2026-09-01'}});assert.equal(revoked.isError,true);
  console.log('PASS phone revocation stops the distributed client');
} finally {
  await local?.close();child?.kill();
  if(id)assert.equal((await device('DELETE','/v1/account')).status,200);
  rmSync(directory,{recursive:true,force:true});console.log('PASS synthetic account, key and tokens removed');
}
