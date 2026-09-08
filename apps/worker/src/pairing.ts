import type {AuthRequest} from '@cloudflare/workers-oauth-provider';
import {b64url, parseJSON, rateLimit, sha256} from './security';
import {type Env, type User, HttpError, json, now} from './types';
interface Pairing {id:string;code:string;browser_hash:string;oauth_request:string;client_name:string;redirect_host:string;expires_at:number;user_id:string|null;status:string;redirect_to:string|null;completion_attempts:number}
const escape=(s:string)=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const cookieName='__Host-healthmcp_pair';
function cookie(request:Request) {return request.headers.get('cookie')?.split(';').map(s=>s.trim()).find(s=>s.startsWith(cookieName+'='))?.slice(cookieName.length+1);}
export async function authorize(request:Request,env:Env) {
  await rateLimit(env,'authorize:global',600,3600);
  await rateLimit(env,'authorize:'+(request.headers.get('cf-connecting-ip')??'local'),30,3600);
  let auth:AuthRequest;
  try {auth=await env.OAUTH_PROVIDER.parseAuthRequest(request);} catch {throw new HttpError(400,'Invalid OAuth request. Return to your agent and start again.');}
  if (!auth.codeChallenge || auth.codeChallengeMethod!=='S256' || auth.responseType!=='code') throw new HttpError(400,'S256 PKCE is required');
  if (auth.scope.some(s=>!['health:read','offline_access'].includes(s))) throw new HttpError(400,'Unsupported scope');
  const client=await env.OAUTH_PROVIDER.lookupClient(auth.clientId);
  if (!client) throw new HttpError(400,'Unknown client');
  const browserToken=cookie(request)??b64url(crypto.getRandomValues(new Uint8Array(32)));
  const id=crypto.randomUUID(), expires=now()+600;
  const code=(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).toString().padStart(6,'0');
  const name=(client.clientName??'Unnamed agent').slice(0,120), host=new URL(auth.redirectUri).host;
  try {await env.DB.prepare('INSERT INTO pairings(id,code,browser_hash,oauth_request,client_name,redirect_host,expires_at) VALUES(?,?,?,?,?,?,?)').bind(id,code,await sha256(browserToken),JSON.stringify(auth),name,host,expires).run();}
  catch {throw new HttpError(503,'Please restart pairing');}
  const nonce=b64url(crypto.getRandomValues(new Uint8Array(16)));
  const html=`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect ${escape(name)} · Health MCP</title><style nonce="${nonce}">*{box-sizing:border-box}body{margin:0;background:#080f20;color:#f2f6ff;font:17px/1.6 system-ui,sans-serif;min-height:100vh;display:grid;place-items:center;padding:24px}main{max-width:530px;width:100%}.brand{color:#75edda;letter-spacing:.16em;font-size:13px;font-weight:700}h1{font-size:42px;line-height:1.1;letter-spacing:-.04em;margin:28px 0 20px}.muted{color:#a9b8d2}.panel{border:1px solid #29364f;background:#111c31;border-radius:24px;padding:28px;margin:28px 0}.code{font:600 clamp(36px,9vw,58px)/1.5 ui-monospace,monospace;letter-spacing:.12em;color:#75edda}a{color:#75edda}button,.button{display:inline-block;border:0;border-radius:12px;background:#75edda;color:#081422;font-weight:700;text-decoration:none;padding:13px 20px;font-size:16px}small{display:block;color:#9baac4;margin-top:22px}.status{min-height:30px}strong{overflow-wrap:anywhere}</style></head><body><main><div class="brand">HEALTH MCP / PAIRING</div><h1>Your health.<br>Your permission.</h1><p><strong>${escape(name)}</strong> wants access to your encrypted health cache.</p><p class="muted">Open Health MCP on your iPhone, choose Connect an agent, and enter this code.</p><div class="panel"><div class="code" id="pairing-code">${code.slice(0,3)} ${code.slice(3)}</div><div class="status" id="status" role="status">Waiting for approval on your iPhone…</div></div><a class="button" href="healthmcp://pair?code=${code}">Open Health MCP</a><small>Only approve an agent you recognize. Callback: <strong>${escape(host)}</strong><br>This code expires in 10 minutes. Your decryption key is never requested here.</small><p><a href="https://healthmcp.cc/privacy">How your data stays private</a></p></main><script nonce="${nonce}">const pairingId=${JSON.stringify(id)};let done=false;async function poll(){if(done)return;try{const r=await fetch('/authorize/poll',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:pairingId})});const d=await r.json();if(d.redirect_to){done=true;document.getElementById('status').textContent='Approved. Returning to your agent…';location.assign(d.redirect_to);return}if(!r.ok){if(r.status>=500||r.status===429){document.getElementById('status').textContent='Still connecting. Retrying…'}else{done=true;document.getElementById('status').textContent=d.error||'Pairing expired. Start again in your agent.';return}}}catch{}setTimeout(poll,2000)}poll();</script></body></html>`;
  return new Response(html,{headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Set-Cookie':`${cookieName}=${browserToken}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=1200`,'Content-Security-Policy':`default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,'Referrer-Policy':'no-referrer'}});
}
export async function pollPairing(request:Request,env:Env,body:string) {
  const origin=request.headers.get('origin');
  if (origin && origin!==new URL(request.url).origin) throw new HttpError(403,'Invalid origin');
  const {id}=parseJSON<{id:string}>(body), token=cookie(request);
  if (!token || typeof id!=='string') throw new HttpError(403,'Pairing session missing');
  const pairing=await env.DB.prepare('SELECT * FROM pairings WHERE id=? AND browser_hash=?').bind(id,await sha256(token)).first<Pairing>();
  if (!pairing || pairing.expires_at<now()) throw new HttpError(410,'Pairing expired. Start again in your agent.');
  if (pairing.redirect_to) return json({redirect_to:pairing.redirect_to});
  if (!['approved','completing'].includes(pairing.status) || !pairing.user_id) return json({status:pairing.status});
  if(pairing.completion_attempts>=5) throw new HttpError(410,'Connection could not finish. Start again in your agent.');
  const lease=crypto.randomUUID();
  const claim=await env.DB.prepare(`UPDATE pairings SET status='completing',completion_lease=?,completion_started_at=?,completion_attempts=completion_attempts+1
    WHERE id=? AND (status='approved' OR (status='completing' AND COALESCE(completion_started_at,0)<?))`).bind(lease,now(),id,now()-60).run();
  if (claim.meta.changes!==1) return json({status:'completing'});
  try {
    const auth=JSON.parse(pairing.oauth_request) as AuthRequest;
    const connection=await env.DB.prepare("SELECT connections.id FROM connections JOIN users ON users.id=connections.user_id WHERE connections.id=? AND revoked_at IS NULL AND users.state='active' AND connections.generation=users.cache_generation").bind(pairing.id).first();
    if (!connection) throw new HttpError(403,'Pairing revoked');
    const result=await env.OAUTH_PROVIDER.completeAuthorization({request:auth,userId:pairing.user_id,metadata:{clientName:pairing.client_name,connectionId:pairing.id},scope:['health:read',...(auth.scope.includes('offline_access')?['offline_access']:[])],props:{userId:pairing.user_id,connectionId:pairing.id,scope:['health:read']},revokeExistingGrants:false});
    const saved=await env.DB.prepare("UPDATE pairings SET status='complete',redirect_to=?,completion_lease=NULL WHERE id=? AND status='completing' AND completion_lease=?").bind(result.redirectTo,id,lease).run();
    if(saved.meta.changes!==1) return json({status:'completing'});
    return json({redirect_to:result.redirectTo});
  } catch(error) {
    // A lost D1 response after a successful commit leaves 'complete' untouched.
    // If even rollback fails, the next browser poll can reclaim the timed lease.
    try { await env.DB.prepare("UPDATE pairings SET status='approved',completion_lease=NULL WHERE id=? AND status='completing' AND completion_lease=?").bind(id,lease).run(); } catch {}
    throw error;
  }
}
export async function pairDevice(env:Env,user:User,body:string,approve:boolean) {
  await rateLimit(env,`pair:${user.id}`,10,300);
  const {code,pairing_id}=parseJSON<{code:string;pairing_id?:string}>(body);
  if (typeof code!=='string' || !/^\d{6}$/.test(code)) throw new HttpError(400,'Enter the six-digit pairing code');
  const pairing=await env.DB.prepare("SELECT * FROM pairings WHERE code=? AND expires_at>? AND status='pending'").bind(code,now()).first<Pairing>();
  if (!pairing) throw new HttpError(404,'Pairing code not found or expired');
  if (!approve) return json({pairing_id:pairing.id,client_name:pairing.client_name,redirect_host:pairing.redirect_host,expires_at:pairing.expires_at,scope:'Read encrypted health data'});
  if (pairing_id!==pairing.id) throw new HttpError(409,'Review this agent before approving');
  const auth=JSON.parse(pairing.oauth_request) as AuthRequest;
  const approved=await env.DB.batch([
    env.DB.prepare(`INSERT INTO connections(id,user_id,client_id,client_name,created_at,generation) SELECT id,?,?,client_name,?,? FROM pairings WHERE id=? AND status='pending' AND expires_at>? AND EXISTS(SELECT 1 FROM users WHERE id=? AND state='active' AND cache_generation=?) AND (SELECT COUNT(*) FROM connections WHERE user_id=? AND revoked_at IS NULL)<20 AND (SELECT COUNT(*) FROM connections WHERE user_id=?)<200`).bind(user.id,auth.clientId,now(),user.cache_generation,pairing.id,now(),user.id,user.cache_generation,user.id,user.id),
    env.DB.prepare("UPDATE pairings SET status='approved',user_id=? WHERE id=? AND status='pending' AND expires_at>? AND EXISTS(SELECT 1 FROM connections WHERE id=? AND user_id=?)").bind(user.id,pairing.id,now(),pairing.id,user.id)
  ]);
  if(!approved[0].meta.changes || !approved[1].meta.changes) throw new HttpError(409,'Pairing changed or the 20-agent limit was reached. Revoke an unused agent and retry.');
  return json({approved:true,client_name:pairing.client_name});
}
