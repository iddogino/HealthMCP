import {collectGarbage,reconcileLegacyStorage} from './storage';
import {cleanupOAuthState} from './oauth-storage';
import {b64url,bytes,unbase64} from './security';
import {type Env,type User,now} from './types';
import {trackEvent} from './analytics';
const tokens=new Map<string,{token:string;expires:number}>();
async function jwt(env:Env,sandbox:boolean) {
  const keyId=sandbox?env.APNS_SANDBOX_KEY_ID:env.APNS_KEY_ID;
  const privateKey=sandbox?env.APNS_SANDBOX_PRIVATE_KEY:env.APNS_PRIVATE_KEY;
  const cached=keyId?tokens.get(keyId):undefined;
  if(cached && cached.expires>now()) return cached.token;
  if (!keyId || !env.APNS_TEAM_ID || !privateKey) throw new Error('Push credentials not configured');
  // Reuse tokens across Worker cold starts; APNs limits token refresh frequency.
  const stored=await env.OAUTH_KV.get<{token:string;expires:number}>('healthmcp:apns:'+keyId,'json');
  if(stored && stored.expires>now()) { tokens.set(keyId,stored); return stored.token; }
  const key=await crypto.subtle.importKey('pkcs8',unbase64(privateKey.replace(/-----[^-]+-----|\s/g,'')),{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
  const unsigned=b64url(bytes(JSON.stringify({alg:'ES256',kid:keyId})))+'.'+b64url(bytes(JSON.stringify({iss:env.APNS_TEAM_ID,iat:now()})));
  const token=unsigned+'.'+b64url(new Uint8Array(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,bytes(unsigned))));
  const entry={token,expires:now()+3000};
  await env.OAUTH_KV.put('healthmcp:apns:'+keyId,JSON.stringify(entry),{expirationTtl:3300});
  tokens.set(keyId,entry); return token;
}
export async function sendPush(env:Env,user:User,visible=false):Promise<string> {
  const status=await deliverPush(env,user,visible);
  trackEvent(env,'push',{user:user.id,tool:visible?'visible':'background',status});
  return status;
}
async function deliverPush(env:Env,user:User,visible:boolean):Promise<string> {
  if (!user.apns_token) return 'device_not_registered';
  if (!(user.apns_environment==='sandbox'?env.APNS_SANDBOX_PRIVATE_KEY:env.APNS_PRIVATE_KEY)) return 'push_not_configured';
  const endpoint=user.apns_environment==='sandbox'?'https://api.sandbox.push.apple.com':'https://api.push.apple.com';
  try {
    const response=await fetch(`${endpoint}/3/device/${user.apns_token}`,{method:'POST',signal:AbortSignal.timeout(10000),headers:{authorization:`bearer ${await jwt(env,user.apns_environment==='sandbox')}`,'apns-topic':env.APP_BUNDLE_ID,'apns-push-type':visible?'alert':'background','apns-priority':visible?'10':'5','apns-expiration':String(now()+900),'apns-collapse-id':visible?'healthmcp-sync-visible':'healthmcp-sync'},body:JSON.stringify({aps:visible?{alert:{title:'Fresh data for your assistant',body:'Your assistant wants fresh health data — tap to sync.'},sound:'default'}:{'content-available':1}})});
    if (response.ok) return 'accepted';
    const value=await response.json() as {reason?:string};
    if (response.status===410) await env.DB.prepare('UPDATE users SET apns_token=NULL WHERE id=?').bind(user.id).run();
    return `apns_${value.reason??response.status}`;
  } catch {return 'push_failed';}
}
export async function requestSync(env:Env,user:User) {
  const timestamp=now();
  const result=await env.DB.prepare('UPDATE users SET pending_sync_at=?,last_sync_request_at=? WHERE id=? AND (last_sync_request_at IS NULL OR last_sync_request_at<?)').bind(timestamp,timestamp,user.id,timestamp-900).run();
  const status=result.meta.changes===1?await sendPush(env,user):'already_requested';
  if (result.meta.changes===1) await env.DB.prepare('UPDATE users SET last_push_status=? WHERE id=?').bind(status,user.id).run();
  return {requested_at:new Date((result.meta.changes?timestamp:user.last_sync_request_at??timestamp)*1000).toISOString(),last_synced_at:user.last_synced_at?new Date(user.last_synced_at*1000).toISOString():null,push_status:status,advice:status==='accepted'||status==='already_requested'?'Best effort. Poll list_series in about 60 seconds. If stale, open Health MCP on your iPhone.':'Open Health MCP on your iPhone to sync. Push is currently unavailable.'};
}
export async function scheduled(env:Env) {
  const users=await env.DB.prepare(`SELECT * FROM users WHERE state='active' AND pending_sync_at<? AND (last_synced_at IS NULL OR last_synced_at<pending_sync_at) AND (last_visible_push_at IS NULL OR last_visible_push_at<?) LIMIT 50`).bind(now()-120,now()-900).all<User>();
  for(const user of users.results) {
    const claim=await env.DB.prepare('UPDATE users SET last_visible_push_at=?,pending_sync_at=NULL WHERE id=? AND pending_sync_at=?').bind(now(),user.id,user.pending_sync_at).run();
    if(claim.meta.changes) {
      const status=await sendPush(env,user,true);
      await env.DB.prepare('UPDATE users SET last_push_status=? WHERE id=?').bind(status,user.id).run();
    }
  }
  await env.DB.batch([
    env.DB.prepare('DELETE FROM connections WHERE revoked_at<?').bind(now()-30*86400),
    env.DB.prepare("DELETE FROM quota_usage WHERE scope!='global' AND objects=0 AND NOT EXISTS(SELECT 1 FROM users WHERE 'user:' || users.id=scope)"),
    env.DB.prepare('DELETE FROM account_deletions WHERE expires_at<?').bind(now()),
    env.DB.prepare('DELETE FROM nonces WHERE expires_at<?').bind(now()),
    env.DB.prepare('DELETE FROM pairings WHERE expires_at<?').bind(now()),
    env.DB.prepare('DELETE FROM rate_limits WHERE expires_at<?').bind(now()),
    env.DB.prepare('UPDATE users SET pending_sync_at=NULL WHERE last_synced_at>=pending_sync_at')
  ]);
  await reconcileLegacyStorage(env);
  await collectGarbage(env);
  await cleanupOAuthState(env);
}
