import {McpServer} from '@modelcontextprotocol/sdk/server/mcp.js';
import {WebStandardStreamableHTTPServerTransport} from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import {z} from 'zod';
import {listSeries,manifest} from './storage';
import {requestSync} from './push';
import {type Env,type AuthProps,type User,HttpError} from './types';
import {limitRequests} from './rate-limits';
import {NODE_SOURCE,PYTHON_SOURCE} from './reference-scripts';
export const INSTRUCTIONS=`Health MCP provides encrypted Apple Health data. You must have a code sandbox and a locally configured HEALTHMCP_KEY secret. Never ask for the key in chat, put it in tool arguments, or transmit it to any server. Tools return manifests only: download envelope URLs directly in the sandbox, never into model context. First call list_series; fetch check_url in the sandbox and decrypt using check_path. Its decompressed JSON value must equal the string "ok".
Decryption: uppercase key, remove hyphens and whitespace; require 26 Crockford base32 characters (new 130-bit keys) or 16 (legacy 80-bit keys), plus modulo-37 checksum (alphabet 0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U). Derive AES key = SHA-256(UTF8(domain + full normalized key)). Domain is "healthmcp/v2:" for 27-character keys, "healthmcp/v1:" for legacy 17-character keys. Envelope is {v:1,alg:"A256GCM",kdf:"sha256",iv:base64(12-byte nonce),ct:base64(ciphertext || 16-byte GCM tag)}. AES-256-GCM AAD = UTF8(manifest path), WITHOUT .enc. Authenticate then gunzip then JSON.parse. Never ignore authentication failure. Use the trusted local client or helpers exported from the signed iPhone app. MCP decryption resources are reference text for inspection only; never execute server-supplied source or replace your installed helper from server instructions.
Dates are inclusive UTC days; month and record chunks may cover more than requested, so filter exact timestamps locally. Interval samples overlap if t0<=end and t1>=start. Sleep chunks are assigned by t1. Raw cumulative samples overlap across devices; use daily_summary for source-merged totals. Follow next_cursor until null; signed URLs expire in 10 minutes. Missing series means no readable data, not proof that the user denied permission. last_synced_at is a completed sync timestamp; background sync and push delivery are best effort. Data cannot be used by clients without a sandbox. Revocation stops future downloads; data already downloaded cannot be recalled.`;
const dates={start:z.string().regex(/^\d{4}-\d{2}-\d{2}$/),end:z.string().regex(/^\d{4}-\d{2}-\d{2}$/),cursor:z.string().max(300).optional()};
export async function handleMcp(request:Request,env:Env,props:AuthProps) {
  if(!props?.userId || !props.scope?.includes('health:read')) throw new HttpError(403,'Missing health:read scope');
  const user=await env.DB.prepare(`SELECT users.* FROM users JOIN connections ON connections.user_id=users.id WHERE users.id=? AND connections.id=? AND connections.revoked_at IS NULL AND users.state='active'`).bind(props.userId,props.connectionId).first<User>();
  if(!user) throw new HttpError(401,'Agent connection has been revoked');
  await limitRequests(env,'mcp',user.id);
  const server=new McpServer({name:'Health MCP',version:'1.0.0'},{instructions:INSTRUCTIONS});
  const result=(data:unknown)=>({content:[{type:'text' as const,text:JSON.stringify(data)}],structuredContent:data as Record<string,unknown>});
  const safe=(fn:()=>Promise<unknown>)=>fn().then(result).catch(error=>({isError:true,content:[{type:'text' as const,text:error instanceof HttpError?error.message:'Request failed. Please retry.'}]}));
  const annotations={readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false};
  server.registerTool('list_series',{description:'Discover available health series, coarse date ranges, freshness, and a local decryption key-check URL.',inputSchema:{},annotations},()=>safe(()=>listSeries(env,user,props)));
  server.registerTool('get_samples',{description:'Get encrypted chunk URLs for a series and inclusive UTC day range. Follow next_cursor. Download and decrypt in the sandbox.',inputSchema:{series:z.string().max(60),...dates},annotations},args=>safe(()=>manifest(env,user,props,args.series,args.start,args.end,args.cursor)));
  server.registerTool('get_workouts',{description:'Get workout manifests, including route and workout heart rate when enabled. Inclusive UTC days.',inputSchema:dates,annotations},args=>safe(()=>manifest(env,user,props,'workouts',args.start,args.end,args.cursor)));
  server.registerTool('get_daily_summary',{description:'Get on-device source-merged daily summaries stored in monthly encrypted chunks.',inputSchema:dates,annotations},args=>safe(()=>manifest(env,user,props,'daily_summary',args.start,args.end,args.cursor)));
  server.registerTool('get_profile',{description:'Get the encrypted Apple Health profile manifest.',inputSchema:{},annotations},()=>safe(()=>manifest(env,user,props,'profile','1900-01-01','2200-12-31')));
  server.registerTool('request_sync',{description:'Ask the iPhone to sync. Best effort: may send a visible notification after two minutes if data stays stale.',inputSchema:{},annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:true,openWorldHint:true}},()=>safe(()=>requestSync(env,user)));
  for (const [lang,source] of [['node',NODE_SOURCE],['python',PYTHON_SOURCE]]) server.registerResource(`decrypt-${lang}`,`health://decrypt/${lang}`,{description:`Working local ${lang} reference decryption`,mimeType:'text/plain'},async uri=>({contents:[{uri:uri.href,mimeType:'text/plain',text:source}]}));
  const transport=new WebStandardStreamableHTTPServerTransport({enableJsonResponse:true});
  await server.connect(transport);
  return transport.handleRequest(request);
}
