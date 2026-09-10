// One-time operator migration. Uses Wrangler's existing auth; never prints
// OAuth keys/values. Run only with the deployed OAuth issuance gate enabled.
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync,writeFileSync,mkdtempSync,rmSync,mkdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
const run=promisify(execFile),args=process.argv.slice(2);
const flag=name=>args.includes(name);
const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
const local=flag('--local'),cleanup=flag('--cleanup-legacy');
const configPath=resolve(option('--config',local?'apps/worker/wrangler.local.json':'apps/worker/wrangler.jsonc'));
const config=JSON.parse(readFileSync(configPath,'utf8'));
const origin=config.vars.PUBLIC_ORIGIN,namespace=config.kv_namespaces.find(x=>x.binding==='OAUTH_KV').id;
const directory=resolve(option('--evidence','artifacts/release-fixes-2026-09-10'));
const persistence=option('--persist-to',undefined);
const scope=[local?'--local':'--remote','--config',configPath,...persistence?['--persist-to',resolve(persistence)]:[]];
if(!local&&origin!=='https://mcp.healthmcp.cc')throw new Error('Unexpected production origin');
const temporary=mkdtempSync(join(tmpdir(),'healthmcp-oauth-'));
process.umask(0o077);mkdirSync(directory,{recursive:true});
async function wrangler(command) {
  try {return (await run('npx',['wrangler',...command,...scope],{env:{...process.env,CI:'true',WRANGLER_SEND_METRICS:'false'},maxBuffer:32*1024*1024,timeout:60000})).stdout;}
  catch {throw new Error('Wrangler migration operation failed; no OAuth contents were printed. Rerun while issuance remains gated.');}
}
async function health(expected) {
  const response=await fetch(origin+'/health',{signal:AbortSignal.timeout(15000)}),body=await response.json();
  if(!response.ok||body.oauth_storage!==expected)throw new Error('Unexpected OAuth storage mode; migration stopped.');
}
const literal=value=>value===null?'NULL':"'"+String(value).replaceAll("'","''")+"'";
async function sql(statements) {
  const file=join(temporary,'transfer.sql');writeFileSync(file,statements,{mode:0o600});
  // Remote --file uses the bulk import API: it emits progress and import
  // statistics, not the SELECT result shape returned by local execution.
  await wrangler(['d1','execute','healthmcp-db','--file',file,'--yes','--json']);
}
async function verify(condition,expected) {
  // Check exact values inside SQLite rather than exporting authorization
  // contents or relying on Wrangler's different local/remote output formats.
  await sql(`CREATE TABLE IF NOT EXISTS oauth_transfer_check(ok INTEGER NOT NULL CHECK(ok=1));
INSERT INTO oauth_transfer_check SELECT CASE WHEN COUNT(*)=${expected} THEN 1 ELSE 0 END FROM oauth_state WHERE ${condition};
DROP TABLE oauth_transfer_check;`);
}
try {
  await health(cleanup?'d1':'migrating');
  if(!cleanup) {
    console.log('OAuth issuance is gated; waiting for old requests and KV writes to settle.');
    // Local workerd has no distributed KV cache. Production needs a quiet
    // interval before snapshotting the final mutable grant versions.
    const delay=local?1000:120000;
    for(let elapsed=0;elapsed<delay;elapsed+=10000){await new Promise(r=>setTimeout(r,Math.min(10000,delay-elapsed)));await health('migrating');}
  }
  const keys=[];
  for(const prefix of ['client:','grant:','token:']) keys.push(...JSON.parse(await wrangler(['kv','key','list','--namespace-id',namespace,'--prefix',prefix])));
  if(keys.length>30000)throw new Error('Unexpected OAuth record count; inspect capacity before proceeding.');
  console.log(`Snapshot contains ${keys.length} OAuth records.`);
  if(cleanup) {
    // Every still-live source record must already be represented or revoked.
    // Expired source records no longer confer any authorization.
    let verified=0;
    for(let offset=0;offset<keys.length;offset+=50) {
      const live=keys.slice(offset,offset+50).filter(k=>!k.expiration||k.expiration>Math.floor(Date.now()/1000));
      if(!live.length)continue;
      await verify(`key IN (${live.map(k=>literal(k.name)).join(',')})`,live.length);verified+=live.length;
    }
    const file=join(temporary,'retired-keys.json');writeFileSync(file,JSON.stringify(keys.map(k=>k.name)),{mode:0o600});
    if(keys.length)await wrangler(['kv','bulk','delete',file,'--namespace-id',namespace,'--force']);
    const evidence={completed_at:new Date().toISOString(),local,removed_legacy_records:keys.length,verified_live_records:verified};
    writeFileSync(join(directory,local?'oauth-local-cleanup.json':'oauth-production-cleanup.json'),JSON.stringify(evidence,null,2)+'\n');
    console.log(JSON.stringify(evidence));
  } else {
    const records=[];
    for(let offset=0;offset<keys.length;offset+=4) {
      const batch=await Promise.all(keys.slice(offset,offset+4).map(async key=>{
        if(key.expiration&&key.expiration<=Math.floor(Date.now()/1000))return null;
        const value=await wrangler(['kv','key','get',key.name,'--namespace-id',namespace,'--text']);
        if(!value.trim()||value.trim()==='Value not found')return null;
        JSON.parse(value);return {key:key.name,value:value.trimEnd(),expires_at:key.expiration??null};
      }));records.push(...batch.filter(Boolean));
    }
    await health('migrating');let verified=0;
    for(let offset=0;offset<records.length;offset+=50) {
      const batch=records.slice(offset,offset+50);
      await sql(batch.map(r=>`INSERT OR IGNORE INTO oauth_state(key,value,expires_at) VALUES(${literal(r.key)},${literal(r.value)},${r.expires_at??'NULL'});`).join('\n'));
      const conditions=batch.map(r=>`(key=${literal(r.key)} AND (value IS NULL OR (value=${literal(r.value)} AND expires_at IS ${r.expires_at??'NULL'})))`).join(' OR ');
      await verify(conditions,batch.length);verified+=batch.length;
      console.log(`Verified ${verified} transferred or revoked records.`);
    }
    const evidence={completed_at:new Date().toISOString(),local,source_records:keys.length,imported_or_revoked_records:verified,source_sha256:createHash('sha256').update(JSON.stringify(records)).digest('hex')};
    writeFileSync(join(directory,local?'oauth-local-migration.json':'oauth-production-migration.json'),JSON.stringify(evidence,null,2)+'\n');
    console.log(JSON.stringify(evidence));
    console.log('Transfer verified. Activate OAUTH_STORAGE_MODE=d1, verify existing/new tokens, then run --cleanup-legacy.');
  }
} finally {rmSync(temporary,{recursive:true,force:true});}
