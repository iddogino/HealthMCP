// The OAuth package imports the runtime even when using plain fetch handlers.
// Only its platform entrypoint shell is stubbed here; OAuth, crypto and storage
// behavior run unchanged. workerd E2E tests exercise the actual runtime too.
import {registerHooks} from 'node:module';
const source=`export class WorkerEntrypoint {
  constructor(ctx,env){this.ctx=ctx;this.env=env;}
}
export function getGlobalOutboundService(){return {fetch:globalThis.fetch.bind(globalThis)};}`;
registerHooks({resolve(specifier,context,nextResolve){
  if(specifier==='cloudflare:workers')return {url:'data:text/javascript,'+encodeURIComponent(source),shortCircuit:true};
  return nextResolve(specifier,context);
}});
