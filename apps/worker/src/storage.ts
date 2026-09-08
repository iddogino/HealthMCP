import {objectPath, SERIES, validDay, validateEnvelope, validatePeriod} from '../../../packages/protocol/index';
import {b64url, bytes, hmac, unbase64, verifyHmac, parseJSON, rateLimit} from './security';
import {storageLimits,limit} from './limits';
import {type AuthProps, type Env, type User, HttpError, json, now} from './types';
export const physicalKey = (user:User, path:string) => `${user.id}/g${user.cache_generation}/${path.slice(user.id.length+1)}.enc`;
type StoredObject = {blob_key:string;state:string};
type Chunk = {object_key:string;blob_key:string;generation:number;period:string;bytes:number};
const unchangedCache = (env:Env,user:User) => env.DB.prepare("SELECT 1 FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active'").bind(user.id,user.cache_generation,user.privacy_revision);
async function assertCache(env:Env,user:User) { if(!await unchangedCache(env,user).first()) throw new HttpError(409,'Privacy settings changed; restart sync'); }

// Claim garbage before removing it. A pending upload can only publish while its
// reservation is still pending, so GC and publication cannot race each other.
async function discardObject(env:Env,key:string,immediate=false) {
  const claim=await env.DB.prepare(`UPDATE storage_objects SET state='gc' WHERE blob_key=?
    AND NOT EXISTS(SELECT 1 FROM chunks WHERE blob_key=?)`).bind(key,key).run();
  if(!claim.meta.changes) return;
  await env.BLOBS.delete(key);
  // An ambiguous R2 put may still finish. Retain its reservation for the sweeper.
  if(immediate) await env.DB.prepare("DELETE FROM storage_objects WHERE blob_key=? AND state='gc'").bind(key).run();
}
export async function reconcileLegacyStorage(env:Env) {
  const scan=await env.DB.prepare("SELECT cursor FROM storage_maintenance WHERE name='legacy-reconciliation' AND complete=0").first<{cursor:string|null}>();
  if(!scan) return;
  const page=await env.BLOBS.list({limit:100,cursor:scan.cursor??undefined});
  const statements=[];
  for(const object of page.objects) {
    const match=/^(u_[0-9a-f-]{36})\/g(\d+)\//.exec(object.key);
    if(!match) continue;
    statements.push(env.DB.prepare(`INSERT OR IGNORE INTO storage_objects(blob_key,user_id,generation,bytes,created_at,state)
      SELECT ?,?,?,?,?,CASE WHEN EXISTS(SELECT 1 FROM chunks WHERE blob_key=?) THEN 'committed' ELSE 'gc' END`).bind(object.key,match[1],Number(match[2]),object.size,Math.floor(object.uploaded.getTime()/1000),object.key));
  }
  statements.push(env.DB.prepare("UPDATE storage_maintenance SET cursor=?,complete=? WHERE name='legacy-reconciliation'").bind(page.truncated?page.cursor:null,page.truncated?0:1));
  await env.DB.batch(statements);
}
export async function collectGarbage(env:Env) {
  const rows=await env.DB.prepare(`SELECT blob_key FROM storage_objects WHERE
    (state IN ('pending','gc') AND created_at<?) OR
    (state='committed' AND NOT EXISTS(SELECT 1 FROM chunks WHERE chunks.blob_key=storage_objects.blob_key))
    ORDER BY created_at LIMIT 100`).bind(now()-3600).all<{blob_key:string}>();
  for(const row of rows.results) {
    try { await discardObject(env,row.blob_key,true); } catch { /* Keep quota reserved and retry next minute. */ }
  }
}
export async function upload(request:Request,env:Env,user:User,body:string) {
  const url=new URL(request.url), series=url.searchParams.get('series')??'', period=url.searchParams.get('period')??'';
  if (!validatePeriod(series,period)) throw new HttpError(400,'Unknown series or invalid period');
  await rateLimit(env,`writes:${user.id}`,limit(env,'MAX_USER_WRITES_PER_MINUTE',600),60);
  await rateLimit(env,'writes:global',limit(env,'MAX_GLOBAL_WRITES_PER_MINUTE',6000),60);
  await assertCache(env,user);
  const path=objectPath(user.id,series,period), logical=path+'.enc';
  const previous=await env.DB.prepare('SELECT * FROM chunks WHERE user_id=? AND object_key=? AND generation=?').bind(user.id,logical,user.cache_generation).first<Chunk>();
  if (request.method==='DELETE') {
    if(previous) {
      await env.DB.prepare(`DELETE FROM chunks WHERE user_id=? AND object_key=? AND blob_key=? AND EXISTS
        (SELECT 1 FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active')`).bind(user.id,logical,previous.blob_key,user.id,user.cache_generation,user.privacy_revision).run();
      await discardObject(env,previous.blob_key,true);
    }
    await assertCache(env,user);
    return json({deleted:true});
  }
  const envelope=parseJSON(body);
  if (!validateEnvelope(envelope)) throw new HttpError(400,'Invalid encrypted envelope');
  const first=url.searchParams.get('first_day'),last=url.searchParams.get('last_day');
  if((first!==null || last!==null) && (!first || !last || !validDay(first) || !validDay(last) || first>last)) throw new HttpError(400,'Invalid chunk coverage');
  const encoded=JSON.stringify(envelope), size=bytes(encoded).length, caps=storageLimits(env);
  const key=physicalKey(user,path)+'.'+crypto.randomUUID();
  // SQLite serializes the quota check and reservation; concurrent uploads count
  // their physical versions before any billable R2 write starts.
  const reserved=await env.DB.prepare(`INSERT INTO storage_objects(blob_key,user_id,generation,bytes,created_at,state)
    SELECT ?,id,?,?,?,'pending' FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active'
    AND COALESCE((SELECT bytes FROM quota_usage WHERE scope='user:' || users.id),0)+?<=?
    AND COALESCE((SELECT objects FROM quota_usage WHERE scope='user:' || users.id),0)+1<=?
    AND (SELECT bytes FROM quota_usage WHERE scope='global')+?<=?
    AND (SELECT objects FROM quota_usage WHERE scope='global')+1<=? RETURNING blob_key`).bind(key,user.cache_generation,size,now(),user.id,user.cache_generation,user.privacy_revision,size,caps.userBytes,caps.userObjects,size,caps.globalBytes,caps.globalObjects).first<{blob_key:string}>();
  if(!reserved) { await assertCache(env,user); throw new HttpError(507,'Encrypted storage limit reached. Contact support@healthmcp.cc or reduce shared data.'); }
  try {
    await env.BLOBS.put(key,encoded,{httpMetadata:{contentType:'application/json',cacheControl:'private, no-store'}});
    // The previous index is untouched until the new object is durable. CAS also
    // prevents a concurrent replacement or deletion from being silently undone.
    const published=await env.DB.batch([
      env.DB.prepare(`INSERT INTO chunks(user_id,series,period,object_key,bytes,updated_at,blob_key,generation,first_day,last_day)
        SELECT id,?,?,?,?,?,?,?,?,? FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active'
        AND EXISTS(SELECT 1 FROM storage_objects WHERE blob_key=? AND state='pending')
        AND COALESCE((SELECT blob_key FROM chunks WHERE user_id=? AND object_key=?),'')=?
        ON CONFLICT(user_id,object_key) DO UPDATE SET bytes=excluded.bytes,updated_at=excluded.updated_at,blob_key=excluded.blob_key,generation=excluded.generation,first_day=excluded.first_day,last_day=excluded.last_day`).bind(series,period,logical,size,now(),key,user.cache_generation,first,last,user.id,user.cache_generation,user.privacy_revision,key,user.id,logical,previous?.blob_key??''),
      env.DB.prepare("UPDATE storage_objects SET state='committed' WHERE blob_key=? AND EXISTS(SELECT 1 FROM chunks WHERE blob_key=?)").bind(key,key)
    ]);
    if(published[0].meta.changes<1) throw new HttpError(409,'Cache changed; retry sync');
  } catch(error) {
    // A D1 response can be lost after commit. Never remove an indexed object.
    try { await discardObject(env,key); } catch { /* Sweeper owns the durable reservation. */ }
    throw error;
  }
  if(previous) { try { await discardObject(env,previous.blob_key,true); } catch { /* Retry GC later. */ } }
  await env.DB.prepare('UPDATE users SET last_upload_at=?,pending_sync_at=CASE WHEN ? THEN NULL ELSE pending_sync_at END WHERE id=? AND cache_generation=? AND privacy_revision=?').bind(now(),series!=='check' && series!=='profile'?1:0,user.id,user.cache_generation,user.privacy_revision).run();
  return json({stored:true,path,bytes:size});
}
export async function deleteSeries(env:Env,user:User,series:string) {
  if(!SERIES[series]) throw new HttpError(400,'Unknown series');
  const gate=await env.DB.prepare("UPDATE users SET privacy_revision=privacy_revision+1 WHERE id=? AND cache_generation=? AND state='active'").bind(user.id,user.cache_generation).run();
  if(!gate.meta.changes) throw new HttpError(409,'Cache changed; retry cleanup');
  for(;;) {
    const rows=await env.DB.prepare('SELECT object_key,blob_key FROM chunks WHERE user_id=? AND series=? AND generation=? LIMIT 100').bind(user.id,series,user.cache_generation).all<Chunk>();
    if(!rows.results.length) break;
    await env.DB.batch(rows.results.map(row=>env.DB.prepare('DELETE FROM chunks WHERE user_id=? AND object_key=? AND blob_key=?').bind(user.id,row.object_key,row.blob_key)));
    for(const row of rows.results) await discardObject(env,row.blob_key,true);
  }
  await env.DB.prepare('DELETE FROM series WHERE user_id=? AND series=? AND EXISTS(SELECT 1 FROM users WHERE id=? AND cache_generation=?)').bind(user.id,series,user.id,user.cache_generation).run();
  return json({deleted:true,series});
}
export async function updateSeries(env:Env,user:User,body:string) {
  const value=parseJSON<{series:string;first_day:string;last_day:string;total_samples:number}>(body);
  if (!SERIES[value.series] || !Number.isSafeInteger(value.total_samples) || value.total_samples<0 || !validDay(value.first_day) || !validDay(value.last_day) || value.first_day>value.last_day) throw new HttpError(400,'Invalid series summary');
  await assertCache(env,user);
  if (value.total_samples===0) {
    await env.DB.prepare("DELETE FROM series WHERE user_id=? AND series=? AND EXISTS(SELECT 1 FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active')").bind(user.id,value.series,user.id,user.cache_generation,user.privacy_revision).run();
  } else {
    const result=await env.DB.prepare(`INSERT INTO series(user_id,series,first_day,last_day,total_samples,last_synced_at)
      SELECT id,?,?,?,?,? FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active'
      ON CONFLICT(user_id,series) DO UPDATE SET first_day=excluded.first_day,last_day=excluded.last_day,total_samples=excluded.total_samples,last_synced_at=excluded.last_synced_at`).bind(value.series,value.first_day,value.last_day,value.total_samples,now(),user.id,user.cache_generation,user.privacy_revision).run();
    if(!result.meta.changes) throw new HttpError(409,'Cache changed; retry sync');
  }
  return json({updated:true});
}
export async function updateCoverage(env:Env,user:User,body:string) {
  const {chunks}=parseJSON<{chunks:{series:string;period:string;first_day:string;last_day:string}[]}>(body);
  if(!Array.isArray(chunks) || !chunks.length || chunks.length>200 || chunks.some(c=>!validatePeriod(c.series,c.period)||!validDay(c.first_day)||!validDay(c.last_day)||c.first_day>c.last_day)) throw new HttpError(400,'Invalid chunk coverage batch');
  await assertCache(env,user);
  await env.DB.batch(chunks.map(c=>env.DB.prepare(`UPDATE chunks SET first_day=?,last_day=? WHERE user_id=? AND series=? AND period=? AND generation=?
    AND EXISTS(SELECT 1 FROM users WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active')`).bind(c.first_day,c.last_day,user.id,c.series,c.period,user.cache_generation,user.id,user.cache_generation,user.privacy_revision)));
  await assertCache(env,user);
  const missing=await env.DB.prepare(`SELECT json_extract(j.value,'$.series') AS series,json_extract(j.value,'$.period') AS period FROM json_each(?) j
    WHERE NOT EXISTS(SELECT 1 FROM chunks c WHERE c.user_id=? AND c.series=json_extract(j.value,'$.series') AND c.period=json_extract(j.value,'$.period') AND c.generation=?)`).bind(JSON.stringify(chunks),user.id,user.cache_generation).all<{series:string;period:string}>();
  return json({updated:true,missing:missing.results});
}
export async function signedBlobURL(env:Env,user:User,connectionId:string,path:string) {
  const expires=now()+600;
  const payload=b64url(bytes(JSON.stringify({u:user.id,p:path,g:user.cache_generation,c:connectionId,e:expires})));
  return {url:`${env.PUBLIC_ORIGIN}/v1/blob/${payload}.${await hmac(env,payload)}`,expires_at:new Date(expires*1000).toISOString()};
}
export async function blob(request:Request,env:Env) {
  const token=new URL(request.url).pathname.slice('/v1/blob/'.length);
  const [payload,signature,...extra]=token.split('.');
  if (!payload || !signature || extra.length || token.length>2500 || !await verifyHmac(env,payload,signature)) throw new HttpError(403,'Invalid download link');
  let data:{u:string;p:string;g:number;c:string;e:number};
  try {data=JSON.parse(new TextDecoder().decode(unbase64(payload)));} catch {throw new HttpError(403,'Invalid download link');}
  if (!Number.isInteger(data.e) || data.e<=now() || data.e>now()+601 || typeof data.p!=='string' || !data.p.startsWith(data.u+'/')) throw new HttpError(403,'Expired download link');
  const user=await env.DB.prepare(`SELECT users.* FROM users JOIN connections ON connections.user_id=users.id WHERE users.id=? AND connections.id=? AND connections.revoked_at IS NULL AND users.state='active'`).bind(data.u,data.c).first<User>();
  if (!user || user.cache_generation!==data.g) throw new HttpError(403,'Download access revoked');
  await rateLimit(env,`download:${user.id}`,1200,60);
  await rateLimit(env,'download:global',12000,60);
  const chunk=await env.DB.prepare('SELECT blob_key FROM chunks WHERE user_id=? AND object_key=? AND generation=?').bind(user.id,data.p+'.enc',data.g).first<{blob_key:string}>();
  const object=chunk?await env.BLOBS.get(chunk.blob_key):null;
  if (!object) throw new HttpError(404,'Chunk not found');
  return new Response(object.body,{headers:{'Content-Type':'application/json','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'}});
}
export async function listSeries(env:Env,user:User,props:AuthProps) {
  const rows=await env.DB.prepare('SELECT series,first_day,last_day,total_samples,last_synced_at FROM series WHERE user_id=? ORDER BY series').bind(user.id).all<{series:string;last_synced_at:number}>();
  const check=await env.DB.prepare('SELECT 1 FROM chunks WHERE user_id=? AND series=\'check\'').bind(user.id).first();
  const checkLink=check ? await signedBlobURL(env,user,props.connectionId,`${user.id}/check`) : null;
  return {series:rows.results.map(s=>({...s,id:s.series,unit:SERIES[s.series]?.unit,last_synced_at:new Date(s.last_synced_at*1000).toISOString()})),check_url:checkLink?.url??null,check_path:`${user.id}/check`,last_synced_at:user.last_synced_at?new Date(user.last_synced_at*1000).toISOString():null,cache_generation:user.cache_generation};
}
export async function manifest(env:Env,user:User,props:AuthProps,series:string,start:string,end:string,cursor?:string) {
  if (!SERIES[series] || !validDay(start) || !validDay(end) || start>end) throw new HttpError(400,'Use a known series and valid inclusive YYYY-MM-DD range');
  if (cursor && (cursor.length>300 || !cursor.startsWith(`${user.id}/${series}`))) throw new HttpError(400,'Invalid cursor');
  // Legacy chunks have unknown coverage. Include them conservatively until the
  // phone publishes its existing journal's boundaries; no health re-read needed.
  const rows=await env.DB.prepare(`SELECT period,object_key,bytes FROM chunks WHERE user_id=? AND series=? AND generation=?
    AND (first_day IS NULL OR (first_day<=? AND last_day>=?) OR series='profile') AND object_key>? ORDER BY object_key LIMIT 201`).bind(user.id,series,user.cache_generation,end,start,cursor??'').all<Chunk>();
  const page=rows.results.slice(0,200);
  const chunks=await Promise.all(page.map(async row=>({period:row.period,path:row.object_key.slice(0,-4),bytes:row.bytes,...await signedBlobURL(env,user,props.connectionId,row.object_key.slice(0,-4))})));
  const freshness=await env.DB.prepare('SELECT last_synced_at FROM series WHERE user_id=? AND series=?').bind(user.id,series).first<{last_synced_at:number}>();
  return {series,chunks,next_cursor:rows.results.length>200?page.at(-1)!.object_key:null,expires_at:new Date((now()+600)*1000).toISOString(),last_synced_at:freshness?new Date(freshness.last_synced_at*1000).toISOString():null,range:{start,end,inclusive:true,timezone:'UTC'},decrypt:"Fetch URLs directly in your sandbox. AAD is the path field. Decrypt, gunzip, parse JSON, then filter exact timestamps locally. Never load ciphertext into model context."};
}
export async function resetCache(env:Env,user:User,deleteAccount=false,operationID?:string) {
  if(user.state==='deleted') return json({deleted:true,reset:false});
  if(operationID && !/^[A-Za-z0-9-]{16,80}$/.test(operationID)) throw new HttpError(400,'Invalid cleanup operation');
  if(operationID && await env.DB.prepare('SELECT 1 FROM cache_operations WHERE user_id=? AND operation_id=?').bind(user.id,operationID).first()) return json({deleted:false,reset:true});
  if(!deleteAccount && user.state==='active') await rateLimit(env,`reset:${user.id}`,5,3600);
  const gate=await env.DB.prepare("UPDATE users SET state='resetting',pending_sync_at=NULL,privacy_revision=privacy_revision+1 WHERE id=? AND cache_generation=?").bind(user.id,user.cache_generation).run();
  if(!gate.meta.changes) {
    if(deleteAccount && await env.DB.prepare('SELECT 1 FROM account_deletions WHERE user_id=?').bind(user.id).first()) return json({deleted:true,reset:false});
    throw new HttpError(409,'Cache changed; retry cleanup');
  }
  await env.DB.prepare('UPDATE connections SET revoked_at=? WHERE user_id=? AND generation<=? AND revoked_at IS NULL').bind(now(),user.id,user.cache_generation).run();
  const connections=await env.DB.prepare('SELECT id FROM connections WHERE user_id=? AND generation<=?').bind(user.id,user.cache_generation).all<{id:string}>();
  const revoked=new Set(connections.results.map(c=>c.id));
  let grantCursor:string|undefined;
  do {
    const grants=await env.OAUTH_PROVIDER.listUserGrants(user.id,{limit:100,cursor:grantCursor});
    for(const grant of grants.items) if(revoked.has(grant.metadata?.connectionId)) await env.OAUTH_PROVIDER.revokeGrant(grant.id,user.id);
    grantCursor=grants.cursor;
  } while(grantCursor);
  // Fence and unpublish this generation before GC. Concurrent old requests can
  // neither republish it nor remove a later generation's files or index.
  await env.DB.prepare('DELETE FROM chunks WHERE user_id=? AND generation<=?').bind(user.id,user.cache_generation).run();
  for(;;) {
    const objects=await env.DB.prepare(`SELECT blob_key,state FROM storage_objects WHERE user_id=? AND generation<=? AND state!='gc' LIMIT 100`).bind(user.id,user.cache_generation).all<StoredObject>();
    if(!objects.results.length) break;
    for(const row of objects.results) await discardObject(env,row.blob_key,row.state==='committed');
  }
  const finish=[env.DB.prepare('DELETE FROM series WHERE user_id=? AND EXISTS(SELECT 1 FROM users WHERE id=? AND cache_generation=? AND state=\'resetting\')').bind(user.id,user.id,user.cache_generation)];
  if(deleteAccount) {
    finish.push(env.DB.prepare(`INSERT OR IGNORE INTO account_deletions(user_id,device_pubkey,deleted_at,expires_at)
      SELECT id,device_pubkey,?,? FROM users WHERE id=? AND cache_generation=? AND state='resetting'`).bind(now(),now()+30*86400,user.id,user.cache_generation));
    finish.push(env.DB.prepare("DELETE FROM users WHERE id=? AND cache_generation=? AND state='resetting'").bind(user.id,user.cache_generation));
    finish.push(env.DB.prepare("DELETE FROM quota_usage WHERE scope=? AND NOT EXISTS(SELECT 1 FROM users WHERE id=?) AND NOT EXISTS(SELECT 1 FROM storage_objects WHERE user_id=?)").bind('user:'+user.id,user.id,user.id));
  } else {
    if(operationID) finish.push(env.DB.prepare("INSERT OR IGNORE INTO cache_operations(user_id,operation_id,generation) SELECT id,?,cache_generation FROM users WHERE id=? AND cache_generation=? AND state='resetting'").bind(operationID,user.id,user.cache_generation));
    finish.push(env.DB.prepare('DELETE FROM cache_operations WHERE user_id=? AND generation<?').bind(user.id,user.cache_generation-10));
    finish.push(env.DB.prepare("UPDATE users SET cache_generation=cache_generation+1,state='active',last_synced_at=NULL WHERE id=? AND cache_generation=? AND state='resetting'").bind(user.id,user.cache_generation));
  }
  await env.DB.batch(finish);
  return json({deleted:deleteAccount,reset:!deleteAccount});
}
