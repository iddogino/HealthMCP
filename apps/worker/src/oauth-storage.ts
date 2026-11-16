import {OAuthError} from '@cloudflare/workers-oauth-provider';
import type {Env} from './types';

export const AGENT_IDLE_TTL=90*86400;
// The provider fixes a grant's expiry at code exchange and forbids changing it on refresh.
// Any write of an issued grant (exchange or refresh) means the agent is in use, so slide expiry to 90 idle days.
export function slideGrant(key:string,value:string,expiration:number|null,now:number):[string,number|null] {
  if(!key.startsWith('grant:')) return [value,expiration];
  let grant:{refreshTokenId?:string;expiresAt?:number};
  try {grant=JSON.parse(value);} catch {return [value,expiration];}
  if(!grant.refreshTokenId || typeof grant.expiresAt!=='number' || grant.expiresAt>=now+AGENT_IDLE_TTL) return [value,expiration];
  grant.expiresAt=now+AGENT_IDLE_TTL;
  return [JSON.stringify(grant),Math.max(expiration??0,grant.expiresAt)];
}
const managed=(key:string)=>['client:','grant:','token:'].some(prefix=>key.startsWith(prefix));
type Entry={value:string|null;expires_at:number|null;revision:number};
type ListOptions={prefix?:string;limit?:number;cursor?:string};
export const oauthStorageMode=(env:Env)=>env.OAUTH_STORAGE_MODE??'kv';
export const oauthUnavailable=()=>Response.json({error:'temporarily_unavailable',error_description:'Authorization storage is being upgraded. Please retry shortly.'},{status:503,headers:{'Cache-Control':'no-store','Retry-After':'60'}});

/** The provider uses string/JSON get, put, delete and prefix list. Keep its
 * stored format and cryptography unchanged while moving mutable state off KV.
 * Instances are request-local: read revisions fence concurrent refreshes and
 * revocation. D1 calls intentionally use the primary, without replica sessions.
 */
export class OAuthStateStorage {
  private revisions=new Map<string,number>();
  constructor(private db:D1Database,private legacy:KVNamespace,private mode:'d1'|'migrating',private clock=()=>Math.floor(Date.now()/1000)) {}
  namespace():KVNamespace { return this as unknown as KVNamespace; }

  async get(key:string,options?:string|{type?:string}) {
    if(!managed(key)||this.mode==='migrating') return this.legacy.get(key,options as KVNamespaceGetOptions<'text'>);
    const row=await this.db.prepare('SELECT value,expires_at,revision FROM oauth_state WHERE key=?').bind(key).first<Entry>();
    if(row) this.revisions.set(key,row.revision);
    if(!row?.value || (row.expires_at!==null&&row.expires_at<=this.clock())) return null;
    const type=typeof options==='string'?options:options?.type??'text';
    if(type==='json') return JSON.parse(row.value);
    if(type==='text') return row.value;
    if(type==='arrayBuffer') return new TextEncoder().encode(row.value).buffer;
    if(type==='stream') return new Response(row.value).body;
    throw new TypeError('Unsupported OAuth storage read');
  }
  async put(key:string,value:string,options?:KVNamespacePutOptions) {
    if(!managed(key)) return this.legacy.put(key,value,options);
    if(this.mode==='migrating') throw new OAuthError('temporarily_unavailable',{description:'Authorization storage is being upgraded. Please retry shortly.',statusCode:503,headers:{'Retry-After':'60'}});
    if(typeof value!=='string'||options?.metadata!==undefined) throw new TypeError('Unsupported OAuth storage write');
    let expiration=options?.expiration??(options?.expirationTtl!==undefined?this.clock()+options.expirationTtl:null);
    [value,expiration]=slideGrant(key,value,expiration,this.clock());
    const revision=this.revisions.get(key);
    const grantKey=key.startsWith('token:')?'grant:'+key.split(':').slice(1,3).join(':'):null;
    const result=revision===undefined
      ?await this.db.prepare('INSERT INTO oauth_state(key,value,expires_at) SELECT ?,?,? WHERE ? IS NULL OR EXISTS(SELECT 1 FROM oauth_state WHERE key=? AND value IS NOT NULL AND (expires_at IS NULL OR expires_at>?)) ON CONFLICT(key) DO NOTHING').bind(key,value,expiration,grantKey,grantKey,this.clock()).run()
      :await this.db.prepare('UPDATE oauth_state SET value=?,expires_at=?,revision=revision+1 WHERE key=? AND revision=? AND value IS NOT NULL').bind(value,expiration,key,revision).run();
    if(result.meta.changes!==1) throw new OAuthError('temporarily_unavailable',{description:'Authorization changed during this request. Please retry.',statusCode:503,headers:{'Retry-After':'1'}});
    this.revisions.set(key,(revision??0)+1);
  }
  async delete(key:string) {
    if(!managed(key)) return this.legacy.delete(key);
    // A tombstone also fences imports while the deployment is migrating.
    const retire=this.db.prepare('INSERT INTO oauth_state(key,value) VALUES(?,NULL) ON CONFLICT(key) DO UPDATE SET value=NULL,expires_at=NULL,revision=revision+1').bind(key);
    if(key.startsWith('grant:')) {
      const prefix='token:'+key.slice('grant:'.length)+':';
      // Token issuance requires a live grant, and retiring that grant also
      // retires tokens minted after the provider's earlier paginated listing.
      await this.db.batch([retire,this.db.prepare('UPDATE oauth_state SET value=NULL,expires_at=NULL,revision=revision+1 WHERE key>=? AND key<?').bind(prefix,prefix.slice(0,-1)+';')]);
    } else await retire.run();
    // Remove any pre-migration copy too. If this fails, the tombstone is a
    // durable cleanup task; it still prevents reads/imports from reviving it.
    await this.legacy.delete(key);
  }
  async list(options:ListOptions={}) {
    const prefix=options.prefix??'';
    if(!managed(prefix)||this.mode==='migrating') return this.legacy.list(options);
    const limit=options.limit??1000;
    if(!Number.isInteger(limit)||limit<1||limit>1000) throw new TypeError('Invalid OAuth storage page size');
    let after='';
    if(options.cursor) {
      const cursor=JSON.parse(decodeURIComponent(options.cursor));
      if(cursor.prefix!==prefix||typeof cursor.after!=='string'||!cursor.after.startsWith(prefix)) throw new TypeError('Invalid OAuth storage cursor');
      after=cursor.after;
    }
    const upper=prefix.slice(0,-1)+String.fromCharCode(prefix.charCodeAt(prefix.length-1)+1);
    const rows=await this.db.prepare('SELECT key,expires_at FROM oauth_state WHERE key>=? AND key<? AND key>? AND value IS NOT NULL AND (expires_at IS NULL OR expires_at>?) ORDER BY key LIMIT ?').bind(prefix,upper,after,this.clock(),limit+1).all<{key:string;expires_at:number|null}>();
    const page=rows.results.slice(0,limit),complete=rows.results.length<=limit;
    return {keys:page.map(row=>({name:row.key,...row.expires_at===null?{}:{expiration:row.expires_at}})),list_complete:complete,cursor:complete?'':encodeURIComponent(JSON.stringify({prefix,after:page.at(-1)!.key}))};
  }
}

export function withOAuthStorage(env:Env):Env {
  const mode=oauthStorageMode(env);
  if(mode==='kv') return env;
  const effective={...env,OAUTH_KV:new OAuthStateStorage(env.DB,env.OAUTH_KV,mode).namespace()};
  // Helpers must capture this request's storage/revisions, never an earlier
  // request's namespace or the pre-migration binding.
  delete (effective as Partial<Env>).OAUTH_PROVIDER;
  return effective;
}

export async function cleanupOAuthState(env:Env) {
  if(oauthStorageMode(env)!=='d1') return;
  const retired=await env.DB.prepare('SELECT key,revision FROM oauth_state WHERE value IS NULL LIMIT 100').all<{key:string;revision:number}>();
  for(const row of retired.results) {
    try {
      await env.OAUTH_KV.delete(row.key);
      await env.DB.prepare('DELETE FROM oauth_state WHERE key=? AND revision=? AND value IS NULL').bind(row.key,row.revision).run();
    } catch { /* The tombstone remains queued for the next sweep. */ }
  }
  await env.DB.prepare('DELETE FROM oauth_state WHERE expires_at<=?').bind(Math.floor(Date.now()/1000)).run();
}
