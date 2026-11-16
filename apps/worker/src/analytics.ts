import {AsyncLocalStorage} from 'node:async_hooks';
import type {Env} from './types';

// Product analytics in the `healthmcp_events` Analytics Engine dataset (90-day retention).
// Records only pseudonymous user ids, route/tool/series/agent names, statuses and counts:
// never health values, chunk paths, keys, tokens, IPs or locations.
//   index1  <group>:<user id>; groups keep bursty sync traffic from sampling away rare MCP/tool events
//   blob1 event  blob2 tool | MCP method  blob3 series  blob4 agent connection name  blob5 agent family
//   blob6 status  blob7 user agent  blob8 route  blob9 MCP clientInfo name/version | iOS app build
//   double1 value (range days | bytes | seconds)  double2 count  double3 latency ms  double4 HTTP status
//   double5 data age in hours at query time (-1 unknown)  blob10 user id
export interface EventFields {user?:string;tool?:string;series?:string;client?:string;status?:string;version?:string;value?:number;count?:number;age?:number}
const context=new AsyncLocalStorage<EventFields>();

export const withEventContext=<T>(fn:()=>Promise<T>)=>context.run({},fn);
export function annotate(fields:EventFields) {
  const ctx=context.getStore();
  if(ctx) Object.assign(ctx,fields);
}

export function agentFamily(userAgent:string|null) {
  const ua=(userAgent??'').toLowerCase();
  if(ua.includes('claude-code')) return 'claude-code';
  if(ua.includes('claude')) return 'claude';
  if(ua.includes('codex')) return 'codex';
  if(ua.includes('openai') || ua.includes('chatgpt')) return 'chatgpt';
  if(ua.includes('cursor')) return 'cursor';
  if(ua.includes('hermes')) return 'hermes';
  if(ua.includes('cfnetwork')) return 'ios-app';
  if(ua.includes('healthmcp')) return 'healthmcp-helper';
  if(ua.includes('python')) return 'python';
  if(ua==='node' || ua.includes('undici') || ua.includes('node.js')) return 'node';
  if(ua.includes('curl')) return 'curl';
  if(ua.includes('mozilla')) return 'browser';
  return ua?'other':'none';
}
export function appBuild(userAgent:string|null) {
  const match=/^([^/\s]+)\/(\S+) CFNetwork\/\S+ Darwin\/(\S+)/.exec(userAgent??'');
  return match?`${match[1]}/${match[2]} darwin/${match[3]}`.slice(0,90):undefined;
}

const ROUTES:Record<string,string>={
  'POST /v1/register':'register','PUT /v1/upload':'upload','DELETE /v1/upload':'chunk_delete','PUT /v1/series':'series_update',
  'DELETE /v1/series':'series_delete','PUT /v1/chunk-coverage':'coverage_update','POST /v1/sync/complete':'sync_complete',
  'GET /v1/status':'status','POST /v1/apns':'apns','POST /v1/pair/preview':'pair_preview','POST /v1/pair/approve':'pair_approve',
  'GET /v1/connections':'connections_list','POST /v1/cache/reset':'cache_reset','DELETE /v1/account':'account_delete',
  'GET /authorize':'authorize','POST /authorize/poll':'authorize_poll','POST /register':'oauth_client_register','POST /token':'token',
  'POST /mcp':'mcp_request','GET /mcp':'mcp_stream','DELETE /mcp':'mcp_session_end','GET /health':'health'
};
export function routeName(method:string,path:string) {
  if(path.startsWith('/v1/blob/')) return 'blob_download';
  if(path.startsWith('/v1/connections/') && method==='DELETE') return 'connection_revoke';
  if(path.startsWith('/.well-known/')) return 'discovery';
  return ROUTES[`${method} ${path}`]??'other';
}

const GROUPS:Record<string,string>={register:'sync',upload:'sync',chunk_delete:'sync',series_update:'sync',series_delete:'sync',coverage_update:'sync',
  sync_complete:'sync',status:'sync',apns:'sync',connections_list:'sync',cache_reset:'sync',account_delete:'sync',
  mcp_request:'mcp',mcp_stream:'mcp',mcp_session_end:'mcp',tool_call:'tool',blob_download:'download',push:'push',agent_active_hour:'cron',user_day:'cron'};
export const eventGroup=(event:string)=>GROUPS[event]??'oauth';
function write(env:Env,event:string,fields:EventFields,request?:Request,extra:{route?:string;latency?:number;httpStatus?:number}={}) {
  try {
    const ua=request?.headers.get('user-agent')??null;
    env.EVENTS?.writeDataPoint({
      indexes:[`${eventGroup(event)}:${(fields.user??'').slice(0,90)}`],
      blobs:[event,fields.tool??'',fields.series??'',(fields.client??'').slice(0,120),agentFamily(ua),fields.status??'',(ua??'').slice(0,120),extra.route??'',fields.version??appBuild(ua)??'',(fields.user??'').slice(0,96)],
      doubles:[fields.value??0,fields.count??0,extra.latency??0,extra.httpStatus??0,fields.age??-1]
    });
  } catch {}
}

export function trackEvent(env:Env,event:string,fields:EventFields,request?:Request) {write(env,event,fields,request);}

export function trackRequest(env:Env,request:Request,status:number,latency:number) {
  const route=routeName(request.method,new URL(request.url).pathname);
  if(route==='health') return;
  const ctx=context.getStore()??{};
  write(env,route,{...ctx,status:ctx.status??(status<400?'ok':String(status))},request,{route,latency,httpStatus:status});
}

// Server-side activity history, so retention and active-agent metrics don't depend on an external poller
// and survive revocation/deletion purges in D1. Runs from the existing every-minute cron.
export async function snapshotActivity(env:Env,scheduledTime:number) {
  if(!env.EVENTS) return;
  const at=new Date(scheduledTime);
  if(at.getUTCMinutes()!==0) return;
  try {
    const now=Math.floor(scheduledTime/1000);
    // Access tokens live one hour, so a live token at the top of each hour marks an agent in use during it.
    const live=await env.DB.prepare(`SELECT DISTINCT json_extract(t.value,'$.userId') AS user, c.client_name AS client
      FROM oauth_state t JOIN oauth_state g ON g.key='grant:' || json_extract(t.value,'$.userId') || ':' || json_extract(t.value,'$.grantId')
      JOIN connections c ON c.id=json_extract(g.value,'$.metadata.connectionId') AND c.revoked_at IS NULL
      WHERE t.key>='token:' AND t.key<'token;' AND t.value IS NOT NULL AND t.expires_at>? LIMIT 200`).bind(now).all<{user:string;client:string}>();
    for(const row of live.results) write(env,'agent_active_hour',{user:row.user,client:row.client});
    if(at.getUTCHours()!==0) return;
    const users=await env.DB.prepare(`SELECT u.id,u.state,u.created_at,u.last_upload_at,u.last_synced_at,
      (SELECT COUNT(*) FROM series s WHERE s.user_id=u.id) AS series,
      (SELECT COUNT(*) FROM connections c WHERE c.user_id=u.id AND c.revoked_at IS NULL) AS agents
      FROM users u LIMIT 240`).all<{id:string;state:string;created_at:number;last_upload_at:number|null;last_synced_at:number|null;series:number;agents:number}>();
    for(const u of users.results) write(env,'user_day',{user:u.id,status:u.state,tool:u.last_synced_at?'full_sync':u.series?'uploaded':'registered',
      value:u.series,count:u.agents,age:u.last_upload_at?(now-u.last_upload_at)/3600:-1});
  } catch {}
}
