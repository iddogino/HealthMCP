import {DatabaseSync, type SQLInputValue} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import type {Env,User} from '../../apps/worker/src/types';
export function deferred() { let resolve!:()=>void; const promise=new Promise<void>(r=>{resolve=r;});return {promise,resolve}; }
export function fixture() {
  const db=new DatabaseSync(':memory:');
  for(const name of readdirSync('apps/worker/migrations').filter(n=>n.endsWith('.sql')).sort()) db.exec(readFileSync('apps/worker/migrations/'+name,'utf8'));
  let fail:(sql:string)=>boolean=()=>false, lostCommit=false;
  function statement(sql:string) {
    let args:SQLInputValue[]=[];
    const execute=()=>{ if(fail(sql)) throw new Error('Injected D1 failure');const result=db.prepare(sql).run(...args);return {success:true,meta:{changes:Number(result.changes)}}; };
    const result={bind(...values:SQLInputValue[]) {args=values;return result;},execute,
      async run(){return execute();},
      async first(){if(fail(sql)) throw new Error('Injected D1 failure');return db.prepare(sql).get(...args)??null;},
      async all(){return {results:db.prepare(sql).all(...args),success:true};}};
    return result;
  }
  const DB={prepare:statement,async batch(statements:ReturnType<typeof statement>[]) {
    db.exec('BEGIN');
    let results;
    try {results=statements.map(s=>s.execute());db.exec('COMMIT');}catch(e){db.exec('ROLLBACK');throw e;}
    if(lostCommit){lostCommit=false;throw new Error('Injected lost D1 commit response');}return results;
  }};
  const objects=new Map<string,string>();
  let beforePut:((key:string)=>Promise<void>)|undefined,failDelete=false;
  const BLOBS={
    async head(key:string){return objects.has(key)?{key,size:Buffer.byteLength(objects.get(key)!)}:null;},
    async put(key:string,value:string){await beforePut?.(key);objects.set(key,value);return {key};},
    async get(key:string){return objects.has(key)?{body:objects.get(key)}:null;},
    async delete(keys:string|string[]){if(failDelete)throw new Error('Injected R2 deletion failure');for(const key of [keys].flat())objects.delete(key);},
    async list({prefix=''}:{prefix?:string}){return {objects:[...objects.keys()].filter(k=>k.startsWith(prefix)).map(key=>({key,size:Buffer.byteLength(objects.get(key)!),uploaded:new Date(0)})),truncated:false};}
  };
  db.prepare('INSERT INTO users(id,device_pubkey,created_at) VALUES(?,?,?)').run('u_00000000-0000-4000-8000-000000000099','synthetic-public-key',Math.floor(Date.now()/1000));
  const user=()=>db.prepare('SELECT * FROM users LIMIT 1').get() as unknown as User;
  const env={DB,BLOBS,PUBLIC_ORIGIN:'https://test.invalid',BLOB_SIGNING_SECRET:'public-synthetic-fixture-secret-0123456789',OAUTH_PROVIDER:{listUserGrants:async()=>({items:[]}),revokeGrant:async()=>{}}} as unknown as Env;
  return {db,env,user,objects,failOnce(pattern:string){fail=sql=>{if(!sql.includes(pattern))return false;fail=()=>false;return true;};},failAlways(pattern:string){fail=sql=>sql.includes(pattern);},clearFaults(){fail=()=>false;failDelete=false;},loseNextCommit(){lostCommit=true;},setBeforePut(fn:typeof beforePut){beforePut=fn;},failDeletes(){failDelete=true;}};
}
export const envelope=(byte=1)=>JSON.stringify({v:1,alg:'A256GCM',kdf:'sha256',iv:Buffer.alloc(12,byte).toString('base64'),ct:Buffer.alloc(32,byte).toString('base64')});
export const record='2026-09-01/00000000-0000-4000-8000-000000000001';
export const request=(series='workouts',period=record,coverage?:[string,string],method='PUT')=>new Request('https://test.invalid/v1/upload?'+new URLSearchParams({series,period,...coverage?{first_day:coverage[0],last_day:coverage[1]}:{}}),{method});
