import {type Env, HttpError} from './types';
export function limit(env:Env,key:keyof Env,fallback:number):number {
  const value=env[key];
  if(value===undefined) return fallback;
  const parsed=Number(value);
  if(!Number.isSafeInteger(parsed) || parsed<=0) throw new Error(`Invalid limit: ${key}`);
  return parsed;
}
export function storageLimits(env:Env) {
  return {
    userBytes:limit(env,'MAX_USER_BYTES',2*1024**3),userObjects:limit(env,'MAX_USER_OBJECTS',500_000),
    globalBytes:limit(env,'MAX_GLOBAL_BYTES',100*1024**3),globalObjects:limit(env,'MAX_GLOBAL_OBJECTS',5_000_000)
  };
}
export async function admitDevice(env:Env,publicKey:string,id:string,timestamp:number) {
  const inserted=await env.DB.prepare(`INSERT OR IGNORE INTO users(id,device_pubkey,created_at)
    SELECT ?,?,? WHERE (SELECT COUNT(*) FROM users)<?`).bind(id,publicKey,timestamp,limit(env,'MAX_ACCOUNTS',1000)).run();
  const user=await env.DB.prepare('SELECT id,cache_generation FROM users WHERE device_pubkey=?').bind(publicKey).first();
  if(!user) throw new HttpError(503,'Registration is at capacity. Please contact support@healthmcp.cc.');
  return {user,created:inserted.meta.changes===1};
}
