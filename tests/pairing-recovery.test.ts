import test from 'node:test';
import assert from 'node:assert/strict';
import {pollPairing} from '../apps/worker/src/pairing';
import {sha256} from '../apps/worker/src/security';
import {fixture,deferred} from './helpers/worker-fixture';
async function pairing() {
  const f=fixture(),id='test-pair',token='public-test-browser-token';
  f.db.prepare('INSERT INTO pairings(id,code,browser_hash,oauth_request,client_name,redirect_host,expires_at,user_id,status) VALUES(?,?,?,?,?,?,?,?,?)').run(id,'123456',await sha256(token),JSON.stringify({clientId:'test-client',scope:['health:read']}),'Test','test.invalid',Math.floor(Date.now()/1000)+600,f.user().id,'approved');
  f.db.prepare('INSERT INTO connections(id,user_id,client_id,client_name,created_at) VALUES(?,?,?,?,?)').run(id,f.user().id,'test-client','Test',1);
  const request=new Request('https://test.invalid/authorize/poll',{method:'POST',headers:{cookie:'__Host-healthmcp_pair='+token}});
  return {...f,poll:()=>pollPairing(request,f.env,JSON.stringify({id})),id};
}
for(const failure of ['provider','redirect-save']) test(`pairing retries after ${failure} failure`,async()=>{
  const f=await pairing();let calls=0;
  f.env.OAUTH_PROVIDER.completeAuthorization=(async()=>{calls++;if(calls===1 && failure==='provider')throw new Error('Injected provider failure');return {redirectTo:'https://test.invalid/callback?code='+calls};}) as any;
  if(failure==='redirect-save')f.failOnce("SET status='complete'");
  await assert.rejects(f.poll());assert.equal(f.db.prepare('SELECT status FROM pairings').get()!.status,'approved');
  const result=await (await f.poll()).json() as any;assert.match(result.redirect_to,/code=2$/);assert.equal(calls,2);
});
test('concurrent browser polls mint one authorization, and abandoned leases can be reclaimed',async()=>{
  const f=await pairing(),gate=deferred(),entered=deferred();let calls=0;
  f.env.OAUTH_PROVIDER.completeAuthorization=(async()=>{calls++;entered.resolve();await gate.promise;return {redirectTo:'https://test.invalid/callback'};}) as any;
  const first=f.poll();await entered.promise;assert.deepEqual(await (await f.poll()).json(),{status:'completing'});
  gate.resolve();await first;assert.equal(calls,1);
  f.db.prepare("UPDATE pairings SET status='completing',redirect_to=NULL,completion_started_at=0").run();await f.poll();assert.equal(calls,2);
});
test('persistent provider failure is bounded and never changes phone consent',async()=>{
  const f=await pairing();let calls=0;f.env.OAUTH_PROVIDER.completeAuthorization=(async()=>{calls++;throw new Error('offline');}) as any;
  for(let i=0;i<5;i++)await assert.rejects(f.poll());await assert.rejects(f.poll(),(e:any)=>e.status===410);
  assert.equal(calls,5);assert.equal(f.db.prepare('SELECT revoked_at FROM connections').get()!.revoked_at,null);
});
