import type {Env} from './types';

// Request-local, opt-in aggregate timings. Never capture SQL, bindings, object
// names, credentials or payloads. Durations include the binding round trip.
export function measureBindings(env:Env) {
  const totals={d1:0,r2:0,d1_calls:0,r2_calls:0};
  const originals=new WeakMap<object,D1PreparedStatement>();
  async function timed<T>(kind:'d1'|'r2',operation:()=>Promise<T>):Promise<T> {
    const start=performance.now(); totals[`${kind}_calls`]++;
    try { return await operation(); } finally { totals[kind]+=performance.now()-start; }
  }
  function statement(value:D1PreparedStatement):D1PreparedStatement {
    const wrapped=new Proxy(value,{get(target,key){
      if(key==='bind') return (...args:unknown[])=>statement(target.bind(...args));
      const member=Reflect.get(target,key,target);
      if(['first','all','run','raw'].includes(String(key))) return (...args:unknown[])=>timed('d1',()=>member.apply(target,args));
      return typeof member==='function'?member.bind(target):member;
    }});
    originals.set(wrapped,value);return wrapped;
  }
  const DB=new Proxy(env.DB,{get(target,key){
    if(key==='prepare') return (sql:string)=>statement(target.prepare(sql));
    if(key==='batch') return (items:D1PreparedStatement[])=>timed('d1',()=>target.batch(items.map(s=>originals.get(s)??s)));
    const member=Reflect.get(target,key,target);return typeof member==='function'?member.bind(target):member;
  }});
  const BLOBS=new Proxy(env.BLOBS,{get(target,key){
    const member=Reflect.get(target,key,target);
    if(['put','get','head','delete','list'].includes(String(key))) return (...args:unknown[])=>timed('r2',()=>member.apply(target,args));
    return typeof member==='function'?member.bind(target):member;
  }});
  return {env:{...env,DB,BLOBS},header:()=>Object.entries(totals).map(([key,value])=>`${key};dur=${value.toFixed(2)}`).join(', ')};
}
