import {type Env,HttpError} from './types';

export const requestLimiters={
  device:['DEVICE_USER_LIMITER','DEVICE_GLOBAL_LIMITER'],
  upload:['UPLOAD_USER_LIMITER','UPLOAD_GLOBAL_LIMITER'],
  mcp:['MCP_USER_LIMITER','MCP_GLOBAL_LIMITER'],
  download:['DOWNLOAD_USER_LIMITER','DOWNLOAD_GLOBAL_LIMITER']
} as const;
export type RequestLimitKind=keyof typeof requestLimiters;
export type RequestLimiterBinding=typeof requestLimiters[RequestLimitKind][number];
export type NativeRateLimitBindings=Record<RequestLimiterBinding,RateLimit>;

// Keys use an authenticated identity, never an unverified header. "global" is
// shared by users of this request class within each Cloudflare location; these
// permissive native counters are abuse throttles, not storage accounting.
export async function limitRequests(env:NativeRateLimitBindings,kind:RequestLimitKind,userId:string) {
  if(!userId) throw new Error('An authenticated user is required for throttling');
  const [perUser,global]=requestLimiters[kind];
  for(const [binding,key] of [[perUser,`${kind}:user:${userId}`],[global,`${kind}:global`]] as const) {
    let result:RateLimitOutcome;
    try { result=await env[binding].limit({key}); }
    catch { throw new HttpError(503,'Request throttling is temporarily unavailable. Try again shortly.',5); }
    // The native API does not expose the remaining window. A full window is a
    // conservative retry delay. A denied user must not consume the shared budget.
    if(!result.success) throw new HttpError(429,'Too many requests; try again later',60);
  }
}

// Infrequent security/admission controls retain their 5-minute, hourly or daily
// windows. Native bindings support only 10 or 60 seconds.
export async function durableRateLimit(env:Env,key:string,limit:number,seconds:number) {
  const now=Math.floor(Date.now()/1000),window=Math.floor(now/seconds);
  const row=await env.DB.prepare('INSERT INTO rate_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count').bind(`${key}:${window}`,(window+1)*seconds).first<{count:number}>();
  if(!row || row.count>limit) throw new HttpError(429,'Too many requests; try again later',(window+1)*seconds-now);
}
