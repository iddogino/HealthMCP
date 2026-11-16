import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture,envelope,request} from './helpers/worker-fixture';
import {handleMcp} from '../apps/worker/src/mcp';
import {upload,updateSeries,signedBlobURL,blob} from '../apps/worker/src/storage';
import {withEventContext,trackRequest,routeName,agentFamily,appBuild,snapshotActivity} from '../apps/worker/src/analytics';

type Point={indexes:string[];blobs:string[];doubles:number[]};
function setup() {
  const f=fixture(),user=f.user(),points:Point[]=[];
  const props={userId:user.id,connectionId:'conn-1',scope:['health:read']};
  (f.env as any).EVENTS={writeDataPoint:(p:Point)=>points.push(p)};
  f.db.prepare('INSERT INTO connections(id,user_id,client_id,client_name,created_at) VALUES(?,?,?,?,?)').run(props.connectionId,user.id,'client-1','Claude',1);
  return {f,user,points,props};
}
const rpc=(body:unknown)=>new Request('https://test.invalid/mcp',{method:'POST',headers:{'content-type':'application/json',accept:'application/json, text/event-stream','user-agent':'Claude-User'},body:JSON.stringify(body)});
const call=(name:string,args:unknown)=>rpc({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}});
const mcp=async(s:ReturnType<typeof setup>,req:Request)=>withEventContext(async()=>{const r=await handleMcp(req.clone(),s.f.env,s.props);trackRequest(s.f.env,req,r.status,5);return r;});

test('MCP tool calls record tool, series, range, result count, data age and agent, without health content',async()=>{
  const s=setup();
  await upload(request(),s.f.env,s.user,envelope());
  await updateSeries(s.f.env,s.user,JSON.stringify({series:'workouts',first_day:'2026-09-01',last_day:'2026-09-01',total_samples:1}));
  assert.equal((await mcp(s,call('get_workouts',{start:'2026-09-01',end:'2026-09-07'}))).status,200);
  const tool=s.points.find(p=>p.blobs[0]==='tool_call')!;
  assert.deepEqual(tool.blobs.slice(0,6),['tool_call','get_workouts','workouts','Claude','claude','ok']);
  assert.equal(tool.indexes[0],s.user.id);
  assert.equal(tool.doubles[0],7);
  assert.equal(tool.doubles[1],1);
  assert.ok(tool.doubles[4]>=0 && tool.doubles[4]<1,'data age in hours since last upload');
  const req=s.points.find(p=>p.blobs[0]==='mcp_request')!;
  assert.equal(req.blobs[1],'tools/call');
  assert.equal(req.blobs[3],'Claude');
  assert.ok(!JSON.stringify(s.points).includes('2026-09-01/'),'chunk paths must not be recorded');
});

test('initialize records the MCP client name and version',async()=>{
  const s=setup();
  await mcp(s,rpc({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'claude-ai',version:'0.1.0'}}}));
  const p=s.points.find(p=>p.blobs[0]==='mcp_request')!;
  assert.equal(p.blobs[1],'initialize');
  assert.equal(p.blobs[8],'claude-ai/0.1.0');
});

test('tool errors are recorded with status',async()=>{
  const s=setup();
  await mcp(s,call('get_samples',{series:'not_a_series',start:'2026-09-01',end:'2026-09-02'}));
  const p=s.points.find(p=>p.blobs[0]==='tool_call')!;
  assert.equal(p.blobs[1],'get_samples');
  assert.equal(p.blobs[5],'error_400');
});

test('downloads record series, agent and bytes, not paths',async()=>{
  const s=setup();
  await upload(request(),s.f.env,s.user,envelope());
  const stored=s.f.db.prepare('SELECT object_key FROM chunks').get()!.object_key as string;
  const {url}=await signedBlobURL(s.f.env,s.user,s.props.connectionId,stored.slice(0,-4));
  await withEventContext(async()=>{const r=await blob(new Request(url),s.f.env);trackRequest(s.f.env,new Request(url),r.status,1);});
  const p=s.points.find(p=>p.blobs[0]==='blob_download')!;
  assert.equal(p.blobs[2],'workouts');
  assert.equal(p.blobs[3],'Claude');
  assert.ok(p.doubles[0]>0);
  assert.ok(!p.blobs.some(b=>b.includes('/v1/blob/')));
});

test('hourly snapshot records live agents; daily snapshot records per-user state',async()=>{
  const s=setup(),now=Math.floor(Date.now()/1000);
  s.f.db.prepare('INSERT INTO oauth_state(key,value,expires_at) VALUES(?,?,?)').run(`grant:${s.user.id}:g1`,JSON.stringify({metadata:{connectionId:'conn-1'}}),now+86400);
  s.f.db.prepare('INSERT INTO oauth_state(key,value,expires_at) VALUES(?,?,?)').run(`token:${s.user.id}:g1:t1`,JSON.stringify({userId:s.user.id,grantId:'g1'}),now+1800);
  await snapshotActivity(s.f.env,Date.UTC(2026,10,16,13,1));
  assert.equal(s.points.length,0,'only runs on the hour');
  await snapshotActivity(s.f.env,Date.UTC(2026,10,16,13,0));
  assert.deepEqual(s.points.map(p=>[p.blobs[0],p.blobs[3],p.indexes[0]]),[['agent_active_hour','Claude',s.user.id]]);
  s.points.length=0;
  await snapshotActivity(s.f.env,Date.UTC(2026,10,17,0,0));
  const day=s.points.find(p=>p.blobs[0]==='user_day')!;
  assert.equal(day.indexes[0],s.user.id);
  assert.equal(day.doubles[1],1,'active agent connections');
});

test('helpers classify agents and app builds; a missing binding never breaks requests',async()=>{
  const f=fixture();
  await withEventContext(async()=>trackRequest(f.env,new Request('https://test.invalid/v1/status'),200,1));
  await snapshotActivity(f.env,Date.UTC(2026,10,16,0,0));
  assert.equal(routeName('DELETE','/v1/connections/abc'),'connection_revoke');
  assert.equal(agentFamily('codex-mcp-client/0.167.0'),'codex');
  assert.equal(agentFamily('claude-code/2.1.321 (sdk-ts)'),'claude-code');
  assert.equal(appBuild('HealthMCP/17 CFNetwork/3896.200.61 Darwin/27.2.0'),'HealthMCP/17 darwin/27.2.0');
  assert.equal(appBuild('node'),undefined);
});
