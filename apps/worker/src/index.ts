import {OAuthProvider} from '@cloudflare/workers-oauth-provider';
import {authenticateDevice,parseJSON,readBody,verifySignature} from './security';
import {durableRateLimit} from './rate-limits';
import {authorize,pairDevice,pollPairing} from './pairing';
import {blob,resetCache,updateSeries,upload,deleteSeries,updateCoverage} from './storage';
import {admitDevice} from './limits';
import {scheduled} from './push';
import {handleMcp} from './mcp';
import {measureBindings} from './timing';
import {type Env,type User,type AuthProps,HttpError,json,now} from './types';

async function api(request:Request,env:Env,ctx:ExecutionContext):Promise<Response> {
  const url=new URL(request.url),path=url.pathname;
  if(path==='/health' && request.method==='GET') {
    await env.DB.prepare('SELECT 1').first();
    return json({service:'healthmcp',version:'1.0.0',status:'ok',push_configured:Boolean(env.APNS_PRIVATE_KEY)});
  }
  if(path==='/.well-known/apple-app-site-association') return json({applinks:{details:[{appIDs:[`${env.APP_TEAM_ID}.${env.APP_BUNDLE_ID}`],components:[{'/':'/pair'}]}]}});
  if(path==='/authorize' && request.method==='GET') return authorize(request,env);
  if(path==='/authorize/poll' && request.method==='POST') return pollPairing(request,env,await readBody(request,4096));
  if(path.startsWith('/v1/blob/') && request.method==='GET') return blob(request,env);
  if((path==='/' || path==='/pair') && request.method==='GET') return Response.redirect('https://healthmcp.cc/connect',302);
  if(!path.startsWith('/v1/')) throw new HttpError(404,'Not found');
  const body=await readBody(request,path==='/v1/upload'?undefined:64*1024);
  if(path==='/v1/register' && request.method==='POST') {
    await durableRateLimit(env,'register:'+(request.headers.get('cf-connecting-ip')??'local'),20,3600);
    const data=parseJSON<{device_pubkey:string}>(body);
    if(typeof data.device_pubkey!=='string' || data.device_pubkey.length>100) throw new HttpError(400,'P-256 public key required');
    await verifySignature(request,body,data.device_pubkey);
    await durableRateLimit(env,'register:global',200,86400);
    const {user}=await admitDevice(env,data.device_pubkey,'u_'+crypto.randomUUID(),now());
    return json(user,201);
  }
  const user=await authenticateDevice(request,env,body);
  if(path==='/v1/upload' && ['PUT','DELETE'].includes(request.method)) return upload(request,env,user,body,ctx);
  if(path==='/v1/chunk-coverage' && request.method==='PUT') return updateCoverage(env,user,body);
  if(path==='/v1/series' && request.method==='PUT') return updateSeries(env,user,body);
  if(path==='/v1/series' && request.method==='DELETE') return deleteSeries(env,user,url.searchParams.get('series')??'');
  if(path==='/v1/sync/complete' && request.method==='POST') {
    const completed=await env.DB.prepare("UPDATE users SET last_synced_at=?,pending_sync_at=NULL WHERE id=? AND cache_generation=? AND privacy_revision=? AND state='active'").bind(now(),user.id,user.cache_generation,user.privacy_revision).run();
    if(!completed.meta.changes) throw new HttpError(409,'Cache changed; retry sync');
    return json({last_synced_at:now()});
  }
  if(path==='/v1/status' && request.method==='GET') {
    const catalog=await env.DB.prepare('SELECT series,first_day,last_day,total_samples,last_synced_at FROM series WHERE user_id=? ORDER BY series').bind(user.id).all();
    const usage=await env.DB.prepare('SELECT objects AS chunks,bytes FROM cache_usage WHERE user_id=?').bind(user.id).first();
    return json({user_id:user.id,last_synced_at:user.last_synced_at,pending_sync_at:user.pending_sync_at,cache_generation:user.cache_generation,privacy_revision:user.privacy_revision,series:catalog.results,usage,push_status:user.last_push_status,push_registered:Boolean(user.apns_token)});
  }
  if(path==='/v1/apns' && request.method==='POST') {
    const value=parseJSON<{token:string;environment:string}>(body);
    if(!/^[0-9a-f]{64,200}$/i.test(value.token??'') || !['sandbox','production'].includes(value.environment)) throw new HttpError(400,'Invalid APNs registration');
    await env.DB.prepare('UPDATE users SET apns_token=?,apns_environment=? WHERE id=?').bind(value.token,value.environment,user.id).run();
    return json({registered:true});
  }
  if(['/v1/pair/preview','/v1/pair/approve'].includes(path) && request.method==='POST') return pairDevice(env,user,body,path.endsWith('approve'));
  if(path==='/v1/connections' && request.method==='GET') return json({connections:(await env.DB.prepare('SELECT id,client_name,created_at FROM connections WHERE user_id=? AND revoked_at IS NULL ORDER BY created_at DESC').bind(user.id).all()).results});
  if(path.startsWith('/v1/connections/') && request.method==='DELETE') {
    await env.DB.prepare('UPDATE connections SET revoked_at=? WHERE user_id=? AND id=?').bind(now(),user.id,path.slice('/v1/connections/'.length)).run();
    return json({revoked:true});
  }
  if(path==='/v1/cache/reset' && request.method==='POST') return resetCache(env,user,false,parseJSON<{operation_id?:string}>(body||'{}').operation_id);
  if(path==='/v1/account' && request.method==='DELETE') return resetCache(env,user,true);
  throw new HttpError(404,'Not found');
}
const provider=(env:Env)=>new OAuthProvider<Env>({
  apiRoute:'/mcp',apiHandler:{fetch:(request,env,ctx)=>handleMcp(request,env,ctx.props as AuthProps)},defaultHandler:{fetch:api},
  authorizeEndpoint:'/authorize',tokenEndpoint:'/token',clientRegistrationEndpoint:'/register',
  scopesSupported:['health:read','offline_access'],allowImplicitFlow:false,allowPlainPKCE:false,
  accessTokenTTL:3600,refreshTokenTTL:60*60*24*90,clientIdMetadataDocumentEnabled:true,
  resourceMetadata:{resource:`${env.PUBLIC_ORIGIN}/mcp`,...(env.PUBLIC_ORIGIN.startsWith('https://')?{authorization_servers:[env.PUBLIC_ORIGIN]}:{}),scopes_supported:['health:read'],resource_name:'Health MCP'}
});
export default {
  async fetch(request:Request,env:Env,ctx:ExecutionContext) {
    const start=performance.now();
    const timing=request.headers.get('x-sync-metrics')==='1' && new URL(request.url).pathname.startsWith('/v1/')?measureBindings(env):undefined;
    if(timing) env=timing.env;
    let response:Response;
    try {
      const url=new URL(request.url);
      if(url.host!==new URL(env.PUBLIC_ORIGIN).host) {
        if(env.PUBLIC_ORIGIN.startsWith('http://localhost')) console.info('local_host_check',url.host,new URL(env.PUBLIC_ORIGIN).host);
        throw new HttpError(400,'Invalid host');
      }
      if(request.method==='OPTIONS') response=new Response(null,{status:204});
      else {
        if(url.pathname==='/register' && request.method==='POST') {
          await durableRateLimit(env,'dcr:'+(request.headers.get('cf-connecting-ip')??'local'),30,3600);
          await durableRateLimit(env,'dcr:global',200,86400);
          const slots=await env.DB.prepare("INSERT INTO admission_counters(name,count) VALUES('oauth_clients',1) ON CONFLICT(name) DO UPDATE SET count=count+1 WHERE count<10000 RETURNING count").first();
          if(!slots) throw new HttpError(503,'Client registration is at capacity. Contact support@healthmcp.cc.');
        }
        response=await provider(env).fetch(request,env,ctx);
      }
    } catch(error) {
      response=json({error:error instanceof HttpError?error.message:'The request could not be completed'},error instanceof HttpError?error.status:500);
      if(error instanceof HttpError && error.retryAfter) response.headers.set('Retry-After',String(error.retryAfter));
      if(!(error instanceof HttpError)) console.error('request_failed',env.PUBLIC_ORIGIN.startsWith('http://localhost')?String(error):error instanceof Error?error.name:'unknown');
    }
    const headers=new Headers(response.headers);
    if(timing) headers.set('Server-Timing',`worker;dur=${(performance.now()-start).toFixed(2)}, ${timing.header()}`);
    headers.set('X-Content-Type-Options','nosniff');headers.set('Referrer-Policy','no-referrer');headers.set('Strict-Transport-Security','max-age=31536000; includeSubDomains');
    if(!new URL(request.url).pathname.startsWith('/authorize')) {
      headers.set('Access-Control-Allow-Origin','*');headers.set('Access-Control-Allow-Methods','GET,POST,PUT,DELETE,OPTIONS');
      headers.set('Access-Control-Allow-Headers','Authorization,Content-Type,MCP-Protocol-Version,Mcp-Session-Id');
      headers.set('Access-Control-Expose-Headers','WWW-Authenticate,Mcp-Session-Id');
    }
    return new Response(response.body,{status:response.status,headers});
  },
  async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext) {ctx.waitUntil(scheduled(env));}
};
