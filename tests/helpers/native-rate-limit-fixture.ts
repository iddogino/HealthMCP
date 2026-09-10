import {readFileSync} from 'node:fs';
import type {NativeRateLimitBindings,RequestLimiterBinding} from '../../apps/worker/src/rate-limits';

export type LimiterConfig={name:RequestLimiterBinding;namespace_id:string;simple:{limit:number;period:number}};
export function configuredLimiters(path='apps/worker/wrangler.local.json'):LimiterConfig[] {
  return JSON.parse(readFileSync(path,'utf8')).ratelimits;
}
// Deterministic binding substitute for admission/error tests. This does not
// simulate Cloudflare's permissive, distributed counter propagation.
export function nativeRateLimitFixture() {
  let seconds=0;
  const calls:{binding:RequestLimiterBinding;key:string}[]=[],counts=new Map<string,number>(),caps=new Map<RequestLimiterBinding,number>(),failures=new Set<RequestLimiterBinding>();
  const bindings=Object.fromEntries(configuredLimiters().map(config=>[config.name,{async limit({key}:{key:string}) {
    calls.push({binding:config.name,key});
    if(failures.has(config.name)) throw new Error('Synthetic limiter outage');
    const counter=`${config.name}:${Math.floor(seconds/config.simple.period)}:${key}`;
    const count=(counts.get(counter)??0)+1;counts.set(counter,count);
    return {success:count<=(caps.get(config.name)??config.simple.limit)};
  }}])) as NativeRateLimitBindings;
  return {bindings,calls,setLimit:(binding:RequestLimiterBinding,limit:number)=>caps.set(binding,limit),fail:(binding:RequestLimiterBinding)=>failures.add(binding),advance:(value:number)=>{seconds+=value;}};
}
