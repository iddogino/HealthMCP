import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import {StdioServerTransport} from '@modelcontextprotocol/sdk/server/stdio.js';
import {UnauthorizedError,type OAuthClientProvider} from '@modelcontextprotocol/sdk/client/auth.js';
import type {OAuthClientInformationMixed,OAuthTokens} from '@modelcontextprotocol/sdk/shared/auth.js';
import {createServer} from 'node:http';
import {readFileSync,writeFileSync,mkdirSync,chmodSync,renameSync,existsSync,lstatSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {randomBytes} from 'node:crypto';
import {execFile} from 'node:child_process';
import {TrustedHealthClient,localServer} from './bridge';
// @ts-expect-error Dependency-free helper also shipped separately.
import {normalizeKey} from '../protocol/decrypt.mjs';
const directory=process.env.HEALTHMCP_CONFIG_DIR??join(homedir(),'.config','healthmcp');
const origin=new URL(process.env.HEALTHMCP_ORIGIN??'https://mcp.healthmcp.cc').origin;
if(origin!=='https://mcp.healthmcp.cc' && !/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin)) throw new Error('Unsupported health service origin');
const mode=process.argv[2]??'serve';
function ensureDirectory() { mkdirSync(directory,{recursive:true,mode:0o700});if(lstatSync(directory).isSymbolicLink())throw new Error('Configuration directory must not be a symlink');chmodSync(directory,0o700); }
function load(name:string) { const path=join(directory,name);if(!existsSync(path))return undefined;const stat=lstatSync(path);if(!stat.isFile() || stat.isSymbolicLink() || stat.mode&0o077)throw new Error('Configuration files must be private (chmod 600)');return readFileSync(path,'utf8'); }
function save(name:string,value:string) { ensureDirectory();const temp=join(directory,name+'.'+Buffer.from(randomBytes(8)).toString('hex')+'.tmp');writeFileSync(temp,value,{mode:0o600,flag:'wx'});renameSync(temp,join(directory,name)); }
interface Saved {origin:string;client?:OAuthClientInformationMixed;tokens?:OAuthTokens;verifier?:string;state?:string}
class Provider implements OAuthClientProvider {
  private saved:Saved;
  readonly redirectUrl='http://127.0.0.1:18944/callback';
  readonly clientMetadata={client_name:'Health MCP Private Client',redirect_uris:[this.redirectUrl],grant_types:['authorization_code','refresh_token'],response_types:['code'],token_endpoint_auth_method:'none',scope:'health:read offline_access'};
  constructor(private interactive:boolean) { const stored=load('connection.json');this.saved=stored?JSON.parse(stored):{origin};if(this.saved.origin!==origin)throw new Error('Connection belongs to a different health service'); }
  private persist(){save('connection.json',JSON.stringify(this.saved));}
  clientInformation(){return this.saved.client;}
  saveClientInformation(client:OAuthClientInformationMixed){this.saved.client=client;this.persist();}
  tokens(){return this.saved.tokens;}
  saveTokens(tokens:OAuthTokens){this.saved.tokens=tokens;this.persist();}
  state(){const state=Buffer.from(randomBytes(32)).toString('hex');this.saved.state=state;this.persist();return state;}
  validState(value:string|null){return Boolean(value && value===this.saved.state);}
  saveCodeVerifier(verifier:string){this.saved.verifier=verifier;this.persist();}
  codeVerifier(){if(!this.saved.verifier)throw new Error('Missing authorization verifier');return this.saved.verifier;}
  redirectToAuthorization(url:URL){
    if(!this.interactive)throw new Error('Run healthmcp-client.mjs connect in your terminal to pair first.');
    if(url.origin!==origin||url.pathname!=='/authorize')throw new Error('Untrusted authorization URL');
    process.stderr.write('Approve this connection in the iPhone app, then return here.\n'+url.href+'\n');
    if(process.platform==='darwin' && process.env.HEALTHMCP_NO_BROWSER!=='1')execFile('/usr/bin/open',[url.href],{env:{PATH:'/usr/bin:/bin'}},()=>{});
  }
  invalidateCredentials(scope:'all'|'client'|'tokens'|'verifier'){
    if(scope==='all'||scope==='client')delete this.saved.client;
    if(scope==='all'||scope==='tokens')delete this.saved.tokens;
    if(scope==='all'||scope==='verifier')delete this.saved.verifier;
    this.persist();
  }
}
async function connect(interactive:boolean) {
  const provider=new Provider(interactive),client=new Client({name:'Health MCP Private Client',version:'1.0.0'});
  let complete!:(code:string)=>void,fail!:(error:Error)=>void;
  const callback=new Promise<string>((resolve,reject)=>{complete=resolve;fail=reject;});
  // Avoid an unobserved rejection while the initial OAuth request is in progress.
  void callback.catch(()=>{});
  const listener=interactive?createServer((req,res)=>{
    const url=new URL(req.url??'/',provider.redirectUrl);
    if(req.method!=='GET'||url.pathname!=='/callback'||!provider.validState(url.searchParams.get('state'))){res.writeHead(400);res.end('Invalid pairing callback');return;}
    const code=url.searchParams.get('code');
    if(!code){res.writeHead(400);res.end('Pairing failed. Restart in your terminal.');fail(new Error('Pairing failed'));return;}
    res.writeHead(200,{'Content-Type':'text/plain','Cache-Control':'no-store'});res.end('Connected. You can return to your terminal.');complete(code);
  }):undefined;
  if(listener)await new Promise<void>((resolve,reject)=>{listener.once('error',reject);listener.listen(18944,'127.0.0.1',resolve);});
  const deadline=interactive?setTimeout(()=>fail(new Error('Pairing expired. Run connect again.')),10*60_000):undefined;
  let transport=new StreamableHTTPClientTransport(new URL(origin+'/mcp'),{authProvider:provider});
  try {
    try {await client.connect(transport);}catch(error){
      if(!(error instanceof UnauthorizedError)||!interactive)throw error;
      await transport.finishAuth(await callback);await transport.close();
      transport=new StreamableHTTPClientTransport(new URL(origin+'/mcp'),{authProvider:provider});await client.connect(transport);
    }
    return client;
  } finally {if(deadline)clearTimeout(deadline);listener?.close();}
}
async function main() {
  if(mode==='key') {
    if(process.stdin.isTTY)throw new Error('Pipe the key from your password manager into this command. It will not be printed.');
    let key='';for await(const part of process.stdin){key+=part.toString();if(key.length>512)throw new Error('Invalid key');}
    save('key',normalizeKey(key));process.stderr.write('Private key saved locally with owner-only permissions.\n');return;
  }
  if(!['connect','serve','check'].includes(mode))throw new Error('Usage: node healthmcp-client.mjs [connect|key|check|serve]');
  const client=await connect(mode==='connect');
  if(mode==='connect'){process.stderr.write('Pairing saved locally. Configure the key, then run check.\n');await client.close();return;}
  const key=process.env.HEALTHMCP_KEY??load('key');
  if(!key){await client.close();throw new Error('Configure HEALTHMCP_KEY privately or save it with the key command.');}
  const health=new TrustedHealthClient(client,key,origin);
  if(mode==='check'){await health.catalog();process.stderr.write('Connection and local decryption verified.\n');await client.close();return;}
  const server=localServer(health);server.server.onclose=()=>{void client.close();};
  await server.connect(new StdioServerTransport());
}
void main().catch(()=>{process.stderr.write('Health MCP could not start. Check your local configuration, run connect to pair, and run check to verify the key. No key or server-provided error was printed.\n');process.exitCode=1;});
