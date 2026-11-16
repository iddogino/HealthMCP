// Validates a real account end-to-end via the trusted stdio client. Prints only shapes/counts, never values.
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StdioClientTransport} from '@modelcontextprotocol/sdk/client/stdio.js';
const clientPath=process.argv[2];
const day=d=>new Date(Date.now()-d*86400000).toISOString().slice(0,10);
const transport=new StdioClientTransport({command:process.execPath,args:[clientPath,'serve'],env:{...process.env},stderr:'pipe'});
const client=new Client({name:'healthmcp-account-validation',version:'1.0.0'});
await client.connect(transport);
const shape=r=>{const t=r.structuredContent??JSON.parse(r.content?.[0]?.text??'{}');return t;};
const results=[];
const run=async(name,args={})=>{
  const t0=Date.now();
  try {
    const r=await client.callTool({name,arguments:args});
    const d=shape(r);
    const recs=Array.isArray(d.records)?d.records:Array.isArray(d.series)?d.series:null;
    results.push({tool:name,args:Object.keys(args).length?args:undefined,ok:!r.isError,ms:Date.now()-t0,items:recs?.length,fields:recs?.[0]?Object.keys(recs[0]).slice(0,12):Object.keys(d).slice(0,10),next_cursor:d.next_cursor?'yes':'no',last_synced_at:d.last_synced_at,error:r.isError?String(r.content?.[0]?.text).slice(0,160):undefined});
    return d;
  } catch(e){results.push({tool:name,ok:false,error:String(e.message).slice(0,160)});}
};
console.log('tools:',(await client.listTools()).tools.map(t=>t.name).join(', '));
const cat=await run('list_series');
await run('get_daily_summary',{start:day(7),end:day(0)});
await run('get_samples',{series:'heart_rate',start:day(1),end:day(0)});
await run('get_samples',{series:'steps',start:day(3),end:day(0)});
await run('get_samples',{series:'sleep',start:day(7),end:day(0)});
await run('get_workouts',{start:day(30),end:day(0)});
await run('get_profile');
await run('get_samples',{series:'not_a_series',start:day(1),end:day(0)});
if(process.env.VALIDATE_SYNC==='1') await run('request_sync');
for(const r of results) console.log(JSON.stringify(r));
console.log('series_available:',cat?.series?.length,'| catalog last_synced_at:',cat?.last_synced_at);
await client.close();
