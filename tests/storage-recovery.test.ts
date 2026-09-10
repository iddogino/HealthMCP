import test from 'node:test';
import assert from 'node:assert/strict';
import {upload,manifest,resetCache,deleteSeries,updateCoverage,collectGarbage,reconcileLegacyStorage,blob,signedBlobURL} from '../apps/worker/src/storage';
import {authenticateDevice,sha256,bytes} from '../apps/worker/src/security';
import {admitDevice} from '../apps/worker/src/limits';
import {fixture,envelope,request,record,deferred} from './helpers/worker-fixture';
const props=(id:string)=>({userId:id,connectionId:'test-connection',scope:['health:read']});
function count(f:ReturnType<typeof fixture>,table:string){return Number(f.db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get()!.n);}
function stored(f:ReturnType<typeof fixture>){const key=f.db.prepare('SELECT blob_key FROM chunks LIMIT 1').get()?.blob_key;return key?f.objects.get(String(key)):undefined;}
test('record retry repairs an R2-success/D1-failure without acknowledging an invisible object',async()=>{
  const f=fixture();f.failOnce('INSERT INTO chunks');
  await assert.rejects(upload(request(),f.env,f.user(),envelope()),/Injected D1/);
  assert.equal(count(f,'chunks'),0);
  const result=await upload(request(),f.env,f.user(),envelope());
  assert.equal(result.status,200);assert.equal(count(f,'chunks'),1);assert.equal(stored(f),envelope());
});
test('workout replacements publish late details and preserve old data if publication fails',async()=>{
  const f=fixture();await upload(request(),f.env,f.user(),envelope(1));
  f.failOnce('INSERT INTO chunks');await assert.rejects(upload(request(),f.env,f.user(),envelope(2)));
  assert.equal(stored(f),envelope(1));
  await upload(request(),f.env,f.user(),envelope(2));assert.equal(stored(f),envelope(2));assert.equal(count(f,'chunks'),1);
});
test('lost D1 commit response never deletes the successfully indexed object',async()=>{
  const f=fixture();f.loseNextCommit();await assert.rejects(upload(request(),f.env,f.user(),envelope()),/lost D1/);
  assert.equal(count(f,'chunks'),1);assert.equal(stored(f),envelope());
  await upload(request(),f.env,f.user(),envelope(2));assert.equal(stored(f),envelope(2));
});
test('atomic account and global quotas include concurrent in-flight R2 writes',async()=>{
  const f=fixture(),gate=deferred(),entered=deferred();f.env.MAX_USER_OBJECTS='1';
  f.setBeforePut(async()=>{entered.resolve();await gate.promise;});
  const first=upload(request(),f.env,f.user(),envelope());await entered.promise;
  await assert.rejects(upload(request('sleep','2026-09-01'),f.env,f.user(),envelope()),(e:any)=>e.status===507);
  gate.resolve();await first;assert.equal(f.objects.size,1);
  f.env.MAX_USER_OBJECTS='100';f.env.MAX_GLOBAL_BYTES=String(Buffer.byteLength(envelope()));
  await assert.rejects(upload(request('sleep','2026-09-01'),f.env,f.user(),envelope()),(e:any)=>e.status===507);
  assert.equal(f.objects.size,1);
});
test('failed cleanup holds quota until garbage collection succeeds',async()=>{
  const f=fixture();await upload(request(),f.env,f.user(),envelope());f.failDeletes();
  await upload(request(),f.env,f.user(),envelope(2));
  assert.equal(f.db.prepare("SELECT objects FROM quota_usage WHERE scope='global'").get()!.objects,2);
  f.clearFaults();f.db.prepare('UPDATE storage_objects SET created_at=0').run();await collectGarbage(f.env);
  assert.equal(f.objects.size,1);assert.equal(f.db.prepare("SELECT objects FROM quota_usage WHERE scope='global'").get()!.objects,1);
});
test('privacy removal fences an already-running upload and its later retry',async()=>{
  const f=fixture(),gate=deferred(),entered=deferred(),old=f.user();
  f.setBeforePut(async()=>{entered.resolve();await gate.promise;});
  const pending=upload(request(),f.env,old,envelope());await entered.promise;
  await deleteSeries(f.env,old,'workouts');gate.resolve();
  await assert.rejects(pending,(e:any)=>e.status===409);assert.equal(count(f,'chunks'),0);
  await assert.rejects(upload(request(),f.env,old,envelope()),(e:any)=>e.status===409);
});
test('reset fences pending uploads, collects late writes and preserves later generations',async()=>{
  const f=fixture(),gate=deferred(),entered=deferred(),old=f.user();
  f.setBeforePut(async()=>{entered.resolve();await gate.promise;});
  const pending=upload(request(),f.env,old,envelope());await entered.promise;
  await resetCache(f.env,old);gate.resolve();await assert.rejects(pending,(e:any)=>e.status===409);
  f.setBeforePut(undefined);await upload(request(),f.env,f.user(),envelope(2));
  await assert.rejects(resetCache(f.env,old),(e:any)=>e.status===409);
  f.db.prepare('UPDATE storage_objects SET created_at=0').run();await collectGarbage(f.env);
  assert.equal(count(f,'chunks'),1);assert.equal(stored(f),envelope(2));assert.equal(f.objects.size,1);
});
test('a repeated rotation operation does not erase the subsequent backfill',async()=>{
  const f=fixture(),id=crypto.randomUUID();await resetCache(f.env,f.user(),false,id);
  await upload(request(),f.env,f.user(),envelope());await resetCache(f.env,f.user(),false,id);
  assert.equal(count(f,'chunks'),1);assert.equal(f.user().cache_generation,2);
});
test('date queries include crossing-midnight sleep and long workouts, and exclude non-overlap',async()=>{
  const f=fixture(),p=props(f.user().id);
  await upload(request('sleep','2026-09-02',['2026-09-01','2026-09-02']),f.env,f.user(),envelope());
  await upload(request('workouts',record,['2026-09-01','2026-09-04']),f.env,f.user(),envelope());
  assert.equal((await manifest(f.env,f.user(),p,'sleep','2026-09-01','2026-09-01')).chunks.length,1);
  assert.equal((await manifest(f.env,f.user(),p,'workouts','2026-09-03','2026-09-03')).chunks.length,1);
  assert.equal((await manifest(f.env,f.user(),p,'sleep','2026-08-01','2026-08-31')).chunks.length,0);
});
test('legacy unknown coverage stays discoverable until migrated without reupload',async()=>{
  const f=fixture(),p=props(f.user().id);await upload(request('sleep','2026-09-02'),f.env,f.user(),envelope());
  assert.equal((await manifest(f.env,f.user(),p,'sleep','2026-09-01','2026-09-01')).chunks.length,1);
  await updateCoverage(f.env,f.user(),JSON.stringify({chunks:[{series:'sleep',period:'2026-09-02',first_day:'2026-09-01',last_day:'2026-09-02'}]}));
  assert.equal((await manifest(f.env,f.user(),p,'sleep','2026-08-01','2026-08-31')).chunks.length,0);assert.equal(f.objects.size,1);
});
test('signed downloads follow only a published version and are revoked by deletion',async()=>{
  const f=fixture(),u=f.user();f.db.prepare('INSERT INTO connections(id,user_id,client_id,client_name,created_at) VALUES(?,?,?,?,?)').run('test-connection',u.id,'test','Test',1);
  await upload(request(),f.env,u,envelope());const {url}=await signedBlobURL(f.env,u,'test-connection',u.id+'/workouts/'+record);
  assert.equal(await (await blob(new Request(url),f.env)).text(),envelope());
  await deleteSeries(f.env,u,'workouts');await assert.rejects(blob(new Request(url),f.env),(e:any)=>e.status===404);
});
test('authenticated account deletion can be retried after its response is lost',async()=>{
  const f=fixture(),keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
  const pub=Buffer.from(await crypto.subtle.exportKey('raw',keys.publicKey)).toString('base64');
  f.db.prepare('UPDATE users SET device_pubkey=?').run(pub);const u=f.user();await resetCache(f.env,u,true);
  const sign=async(path:string)=>{const timestamp=String(Math.floor(Date.now()/1000)),nonce=crypto.randomUUID();const canonical=['DELETE',path,timestamp,nonce,await sha256('')].join('\n');const signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},keys.privateKey,bytes(canonical))).toString('base64');return new Request('https://test.invalid'+path,{method:'DELETE',headers:{'x-user-id':u.id,'x-timestamp':timestamp,'x-nonce':nonce,'x-signature':signature}});};
  const authenticated=await authenticateDevice(await sign('/v1/account'),f.env,'');assert.equal(authenticated.state,'deleted');
  assert.equal((await resetCache(f.env,authenticated,true)).status,200);
  await assert.rejects(authenticateDevice(await sign('/v1/status'),f.env,''),(e:any)=>e.status===401);
  assert.equal(count(f,'users'),0);assert.equal(count(f,'chunks'),0);
});
test('account admission has a global cap and existing registrations remain idempotent',async()=>{
  const f=fixture();f.env.MAX_ACCOUNTS='1';
  await assert.rejects(admitDevice(f.env,'new-public-key','u_new',1),(e:any)=>e.status===503);
  const result=await admitDevice(f.env,f.user().device_pubkey,'u_unused',1);assert.equal(result.created,false);assert.equal(count(f,'users'),1);
});

test('legacy reconciliation collects orphaned fixed-path objects without deleting indexed versions',async()=>{
  const f=fixture();await upload(request(),f.env,f.user(),envelope());
  const orphan=f.user().id+'/g1/workouts/2026-08-01/00000000-0000-4000-8000-000000000002.enc';f.objects.set(orphan,envelope(2));
  await reconcileLegacyStorage(f.env);assert.equal(count(f,'storage_objects'),2);await collectGarbage(f.env);
  assert.equal(f.objects.has(orphan),false);assert.equal(stored(f),envelope());assert.equal(f.objects.size,1);
});
test('coverage migration reports missing legacy indexes for phone repair',async()=>{
  const f=fixture();const result=await updateCoverage(f.env,f.user(),JSON.stringify({chunks:[{series:'workouts',period:record,first_day:'2026-09-01',last_day:'2026-09-01'}]}));
  assert.deepEqual((await result.json() as any).missing,[{series:'workouts',period:record}]);
});
test('dashboard counters track replacement and deletion without counting physical retries',async()=>{
  const f=fixture();await upload(request(),f.env,f.user(),envelope());await upload(request(),f.env,f.user(),envelope(2));
  assert.deepEqual({...f.db.prepare('SELECT bytes,objects FROM cache_usage').get()},{bytes:Buffer.byteLength(envelope(2)),objects:1});
  await deleteSeries(f.env,f.user(),'workouts');assert.deepEqual({...f.db.prepare('SELECT bytes,objects FROM cache_usage').get()},{bytes:0,objects:0});
});

test('replacement acknowledgement does not wait for old-object GC, whose bytes remain reserved',async()=>{
  const f=fixture(),gate=deferred(),entered=deferred(),background:Promise<unknown>[]=[];
  await upload(request(),f.env,f.user(),envelope());
  f.setBeforeDelete(async()=>{entered.resolve();await gate.promise;});
  const response=await upload(request(),f.env,f.user(),envelope(2),{waitUntil:p=>background.push(p)});
  await entered.promise;
  assert.equal(response.status,200);assert.equal(stored(f),envelope(2));
  assert.equal(f.objects.size,2);assert.equal(f.db.prepare("SELECT objects FROM quota_usage WHERE scope='global'").get()!.objects,2);
  gate.resolve();await Promise.all(background);
  assert.equal(f.objects.size,1);assert.equal(stored(f),envelope(2));
  assert.equal(f.db.prepare("SELECT objects FROM quota_usage WHERE scope='global'").get()!.objects,1);
});
test('a failed background cleanup remains durable for the scheduled sweeper',async()=>{
  const f=fixture(),background:Promise<unknown>[]=[];
  await upload(request(),f.env,f.user(),envelope());f.failDeletes();
  await upload(request(),f.env,f.user(),envelope(2),{waitUntil:p=>background.push(p)});await Promise.all(background);
  assert.equal(f.objects.size,2);assert.equal(stored(f),envelope(2));
  f.clearFaults();f.db.prepare('UPDATE storage_objects SET created_at=0').run();await collectGarbage(f.env);
  assert.equal(f.objects.size,1);assert.equal(stored(f),envelope(2));
});
test('batched admission enforces both write limits before any object storage write',async()=>{
  for(const setting of ['MAX_USER_WRITES_PER_MINUTE','MAX_GLOBAL_WRITES_PER_MINUTE'] as const) {
    const f=fixture();f.env[setting]='1';
    await upload(request(),f.env,f.user(),envelope());
    await assert.rejects(upload(request('sleep','2026-09-01'),f.env,f.user(),envelope()),(error:any)=>error.status===429);
    assert.equal(f.objects.size,1);assert.equal(count(f,'chunks'),1);
  }
});
