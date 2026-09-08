import {objectPath, SERIES, validDay, validateEnvelope, validatePeriod} from '../../../packages/protocol/index';
import {b64url, bytes, hmac, unbase64, verifyHmac, parseJSON} from './security';
import {type AuthProps, type Env, type User, HttpError, json, now} from './types';
export const physicalKey = (user:User, path:string) => `${user.id}/g${user.cache_generation}/${path.slice(user.id.length+1)}.enc`;
export async function upload(request:Request,env:Env,user:User,body:string) {
  const url=new URL(request.url), series=url.searchParams.get('series')??'', period=url.searchParams.get('period')??'';
  if (!validatePeriod(series,period)) throw new HttpError(400,'Unknown series or invalid period');
  const path=objectPath(user.id,series,period);
  if (request.method==='DELETE') {
    await env.BLOBS.delete(physicalKey(user,path));
    await env.DB.prepare('DELETE FROM chunks WHERE user_id=? AND object_key=?').bind(user.id,path+'.enc').run();
    return json({deleted:true});
  }
  const envelope=parseJSON(body);
  if (!validateEnvelope(envelope)) throw new HttpError(400,'Invalid encrypted envelope');
  const encoded=JSON.stringify(envelope);
  if (SERIES[series]?.chunk==='record' && await env.BLOBS.head(physicalKey(user,path))) return json({stored:true,unchanged:true,path});
  await env.BLOBS.put(physicalKey(user,path),encoded,{httpMetadata:{contentType:'application/json',cacheControl:'private, no-store'}});
  const updated=await env.DB.prepare(`INSERT INTO chunks(user_id,series,period,object_key,bytes,updated_at)
    SELECT id,?,?,?,?,? FROM users WHERE id=? AND cache_generation=? AND state='active'
    ON CONFLICT(user_id,object_key) DO UPDATE SET bytes=excluded.bytes,updated_at=excluded.updated_at`).bind(series,period,path+'.enc',bytes(encoded).length,now(),user.id,user.cache_generation).run();
  if (updated.meta.changes!==1) {
    await env.BLOBS.delete(physicalKey(user,path)); throw new HttpError(409,'Cache changed; retry sync');
  }
  // A startup key check or profile must not suppress the fallback when HealthKit is locked.
  await env.DB.prepare('UPDATE users SET last_upload_at=?,pending_sync_at=CASE WHEN ? THEN NULL ELSE pending_sync_at END WHERE id=? AND cache_generation=?').bind(now(),series!=='check' && series!=='profile'?1:0,user.id,user.cache_generation).run();
  return json({stored:true,path,bytes:bytes(encoded).length});
}
export async function deleteSeries(env:Env,user:User,series:string) {
  if(!SERIES[series]) throw new HttpError(400,'Unknown series');
  for(;;) {
    const rows=await env.DB.prepare('SELECT object_key FROM chunks WHERE user_id=? AND series=? LIMIT 100').bind(user.id,series).all<{object_key:string}>();
    if(!rows.results.length) break;
    await env.BLOBS.delete(rows.results.map(row=>physicalKey(user,row.object_key.slice(0,-4))));
    await env.DB.batch(rows.results.map(row=>env.DB.prepare('DELETE FROM chunks WHERE user_id=? AND object_key=?').bind(user.id,row.object_key)));
  }
  await env.DB.prepare('DELETE FROM series WHERE user_id=? AND series=?').bind(user.id,series).run();
  return json({deleted:true,series});
}
export async function updateSeries(env:Env,user:User,body:string) {
  const value=parseJSON<{series:string;first_day:string;last_day:string;total_samples:number}>(body);
  if (!SERIES[value.series] || !Number.isSafeInteger(value.total_samples) || value.total_samples<0 || !validDay(value.first_day) || !validDay(value.last_day) || value.first_day>value.last_day) throw new HttpError(400,'Invalid series summary');
  if (value.total_samples===0) {
    await env.DB.prepare('DELETE FROM series WHERE user_id=? AND series=?').bind(user.id,value.series).run();
  } else {
    await env.DB.prepare(`INSERT INTO series(user_id,series,first_day,last_day,total_samples,last_synced_at) VALUES(?,?,?,?,?,?)
      ON CONFLICT(user_id,series) DO UPDATE SET first_day=excluded.first_day,last_day=excluded.last_day,total_samples=excluded.total_samples,last_synced_at=excluded.last_synced_at`).bind(user.id,value.series,value.first_day,value.last_day,value.total_samples,now()).run();
  }
  return json({updated:true});
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
  if (!Number.isInteger(data.e) || data.e<=now() || data.e>now()+601 || !data.p.startsWith(data.u+'/')) throw new HttpError(403,'Expired download link');
  const user=await env.DB.prepare(`SELECT users.* FROM users JOIN connections ON connections.user_id=users.id WHERE users.id=? AND connections.id=? AND connections.revoked_at IS NULL AND users.state='active'`).bind(data.u,data.c).first<User>();
  if (!user || user.cache_generation!==data.g) throw new HttpError(403,'Download access revoked');
  const object=await env.BLOBS.get(physicalKey(user,data.p));
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
  const monthly=SERIES[series].chunk==='month';
  const low=series==='profile'?'single':monthly?start.slice(0,7):start;
  const high=series==='profile'?'single':monthly?end.slice(0,7):end+'~';
  const rows=await env.DB.prepare('SELECT period,object_key,bytes FROM chunks WHERE user_id=? AND series=? AND period>=? AND period<=? AND object_key>? ORDER BY object_key LIMIT 201').bind(user.id,series,low,high,cursor??'').all<{period:string;object_key:string;bytes:number}>();
  const page=rows.results.slice(0,200);
  const chunks=await Promise.all(page.map(async row=>({period:row.period,path:row.object_key.slice(0,-4),bytes:row.bytes,...await signedBlobURL(env,user,props.connectionId,row.object_key.slice(0,-4))})));
  const freshness=await env.DB.prepare('SELECT last_synced_at FROM series WHERE user_id=? AND series=?').bind(user.id,series).first<{last_synced_at:number}>();
  return {series,chunks,next_cursor:rows.results.length>200?page.at(-1)!.object_key:null,expires_at:new Date((now()+600)*1000).toISOString(),last_synced_at:freshness?new Date(freshness.last_synced_at*1000).toISOString():null,range:{start,end,inclusive:true,timezone:'UTC'},decrypt:"Fetch URLs directly in your sandbox. AAD is the path field. Decrypt, gunzip, parse JSON, then filter exact timestamps locally. Never load ciphertext into model context."};
}
export async function resetCache(env:Env,user:User,deleteAccount=false) {
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET state='resetting',pending_sync_at=NULL WHERE id=?").bind(user.id),
    env.DB.prepare('UPDATE connections SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL').bind(now(),user.id)
  ]);
  let grantCursor:string|undefined;
  do {
    const grants=await env.OAUTH_PROVIDER.listUserGrants(user.id,{limit:100,cursor:grantCursor});
    for(const grant of grants.items) await env.OAUTH_PROVIDER.revokeGrant(grant.id,user.id);
    grantCursor=grants.cursor;
  } while(grantCursor);
  // The old physical generation cannot overwrite the new one, even if an upload was in flight.
  let cursor:string|undefined;
  do {
    const objects=await env.BLOBS.list({prefix:`${user.id}/`,limit:1000,cursor});
    if (objects.objects.length) await env.BLOBS.delete(objects.objects.map(o=>o.key));
    cursor=objects.truncated?objects.cursor:undefined;
  } while(cursor);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM chunks WHERE user_id=?').bind(user.id),
    env.DB.prepare('DELETE FROM series WHERE user_id=?').bind(user.id),
    deleteAccount?env.DB.prepare('DELETE FROM users WHERE id=?').bind(user.id):env.DB.prepare("UPDATE users SET cache_generation=cache_generation+1,state='active',last_synced_at=NULL WHERE id=?").bind(user.id)
  ]);
  // Connections are checked in D1 on every MCP request and download, so revocation is immediate.
  return json({deleted:deleteAccount,reset:!deleteAccount});
}
