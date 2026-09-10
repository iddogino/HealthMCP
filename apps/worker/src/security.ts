import {canonicalRequest, MAX_ENVELOPE_BYTES} from '../../../packages/protocol/index';
import {type Env, type User, HttpError, now} from './types';
export const bytes = (s: string) => new TextEncoder().encode(s);
export const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/, '');
export const unbase64 = (s: string) => Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')), c => c.charCodeAt(0));
export async function sha256(data: string | Uint8Array) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', typeof data === 'string' ? bytes(data) : data))).map(b=>b.toString(16).padStart(2,'0')).join('');
}
export async function readBody(request: Request, limit = MAX_ENVELOPE_BYTES): Promise<string> {
  if (Number(request.headers.get('content-length')) > limit) throw new HttpError(413,'Request too large');
  if (!request.body) return '';
  const reader = request.body.getReader(); const chunks: Uint8Array[] = []; let length = 0;
  for (;;) {
    const {done,value} = await reader.read(); if (done) break;
    length += value.length;
    if (length > limit) { await reader.cancel(); throw new HttpError(413,'Request too large'); }
    chunks.push(value);
  }
  const data = new Uint8Array(length); let offset=0;
  for (const chunk of chunks) { data.set(chunk,offset); offset += chunk.length; }
  return new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(data);
}
export function parseJSON<T = Record<string,unknown>>(body: string): T {
  try { return JSON.parse(body); } catch { throw new HttpError(400,'Invalid JSON'); }
}
export async function rateLimit(env: Env, key: string, limit: number, seconds: number) {
  const window = Math.floor(now()/seconds);
  const row = await env.DB.prepare('INSERT INTO rate_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count').bind(`${key}:${window}`,(window+1)*seconds).first<{count:number}>();
  if (!row || row.count > limit) throw new HttpError(429,'Too many requests; try again later',(window+1)*seconds-now());
}
export function rateLimitStatement(env:Env,key:string,seconds:number) {
  const window=Math.floor(now()/seconds);
  return env.DB.prepare('INSERT INTO rate_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count').bind(`${key}:${window}`,(window+1)*seconds);
}
export function checkRateLimit(result:D1Result,limit:number,seconds:number) {
  const count=(result.results?.[0] as {count?:number}|undefined)?.count;
  if(typeof count!=='number' || count>limit) throw new HttpError(429,'Too many requests; try again later',(Math.floor(now()/seconds)+1)*seconds-now());
}
export async function verifySignature(request: Request, body: string, publicKey: string) {
  const timestamp=request.headers.get('x-timestamp')??'', nonce=request.headers.get('x-nonce')??'', signature=request.headers.get('x-signature')??'';
  if (!/^\d{10}$/.test(timestamp) || Math.abs(now()-Number(timestamp))>300 || !/^[A-Za-z0-9_-]{22,80}$/.test(nonce)) throw new HttpError(401,'Invalid or expired device signature');
  try {
    const raw=unbase64(publicKey);
    if (raw.length!==65 || raw[0]!==4) throw new Error('Invalid public key');
    const key=await crypto.subtle.importKey('raw',raw,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
    const url=new URL(request.url);
    const message=canonicalRequest(request.method,url.pathname+url.search,timestamp,nonce,await sha256(body));
    if (!await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,unbase64(signature),bytes(message))) throw new Error('Signature mismatch');
  } catch { throw new HttpError(401,'Invalid device signature'); }
  return nonce;
}
export async function authenticateDevice(request: Request, env: Env, body: string): Promise<User> {
  const userId=request.headers.get('x-user-id')??'';
  let user=await env.DB.prepare('SELECT * FROM users WHERE id=?').bind(userId).first<User>();
  const url=new URL(request.url);
  if(!user && request.method==='DELETE' && url.pathname==='/v1/account') {
    const receipt=await env.DB.prepare('SELECT device_pubkey FROM account_deletions WHERE user_id=? AND expires_at>?').bind(userId,now()).first<{device_pubkey:string}>();
    if(receipt) user={id:userId,device_pubkey:receipt.device_pubkey,state:'deleted'} as User;
  }
  if (!user) throw new HttpError(401,'Unknown device');
  const nonce=await verifySignature(request,body,user.device_pubkey);
  // One database round trip, with the same atomic counters and replay claim.
  // Both budgets count signed attempts, including attempts rejected by a limit.
  const [deviceLimit,globalLimit,claim]=await env.DB.batch([
    rateLimitStatement(env,`device:${user.id}`,60),
    rateLimitStatement(env,'device:global',60),
    env.DB.prepare('INSERT OR IGNORE INTO nonces(user_id,nonce,expires_at) VALUES(?,?,?)').bind(user.id,nonce,now()+600)
  ]);
  checkRateLimit(deviceLimit,1200,60);checkRateLimit(globalLimit,12000,60);
  if (claim.meta.changes!==1) throw new HttpError(409,'Request already used');
  if (user.state!=='active' && !['/v1/cache/reset','/v1/account'].includes(new URL(request.url).pathname)) throw new HttpError(409,'Cache reset in progress');
  const generation=url.searchParams.get('cache_generation'),revision=url.searchParams.get('privacy_revision');
  if((generation!==null && generation!==String(user.cache_generation)) || (revision!==null && revision!==String(user.privacy_revision))) throw new HttpError(409,'Privacy settings changed; restart sync');
  return user;
}
export async function hmac(env: Env, payload: string) {
  if (!env.BLOB_SIGNING_SECRET || env.BLOB_SIGNING_SECRET.length<32) throw new Error('Signing secret unavailable');
  const key=await crypto.subtle.importKey('raw',bytes(env.BLOB_SIGNING_SECRET),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return b64url(new Uint8Array(await crypto.subtle.sign('HMAC',key,bytes(payload))));
}
export async function verifyHmac(env:Env,payload:string,signature:string) {
  const key=await crypto.subtle.importKey('raw',bytes(env.BLOB_SIGNING_SECRET),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  try { return await crypto.subtle.verify('HMAC',key,unbase64(signature),bytes(payload)); } catch { return false; }
}
