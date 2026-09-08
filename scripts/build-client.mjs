import {build} from 'esbuild';
import {readFileSync,writeFileSync,mkdirSync,copyFileSync,existsSync,readdirSync} from 'node:fs';
import {dirname,resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const directory='artifacts/trusted-client';mkdirSync(directory,{recursive:true});
const result=await build({entryPoints:['packages/client/cli.ts'],bundle:true,metafile:true,define:{HEALTHMCP_EMBEDDED:'true'},platform:'node',target:'node22',format:'esm',outfile:directory+'/healthmcp-client.mjs',banner:{js:"import {createRequire} from 'node:module'; const require=createRequire(import.meta.url);"},logLevel:'warning'});
const packages=new Map();
for(const input of Object.keys(result.metafile.inputs).filter(path=>path.includes('node_modules/'))) {
  let path=dirname(resolve(input));
  while(path!==dirname(path)) {
    const manifest=join(path,'package.json');
    if(existsSync(manifest)) {
      const pkg=JSON.parse(readFileSync(manifest,'utf8'));
      if(pkg.name && pkg.version) {packages.set(pkg.name+'@'+pkg.version,{...pkg,path});break;}
    }
    path=dirname(path);
  }
}
const notices=[];
for(const [name,pkg] of [...packages].sort(([a],[b])=>a.localeCompare(b))) {
  const files=readdirSync(pkg.path).filter(name=>/^(licen[sc]e|notice|copying)([._-]|$)/i.test(name)).sort();
  if(!files.length)throw new Error('Missing redistribution notice for '+name);
  notices.push(name+'\n'+files.map(file=>readFileSync(join(pkg.path,file),'utf8')).join('\n'));
}
writeFileSync(directory+'/THIRD-PARTY-NOTICES.txt',notices.join('\n\n'+'='.repeat(72)+'\n\n')+'\n');
for(const [source,name] of [['packages/client/README.md','README.md'],['packages/protocol/decrypt.mjs','decrypt.mjs'],['packages/protocol/decrypt.py','decrypt.py']])copyFileSync(source,directory+'/'+name);
const names=['healthmcp-client.mjs','decrypt.mjs','decrypt.py','README.md','THIRD-PARTY-NOTICES.txt'];
writeFileSync(directory+'/SHA256SUMS',names.map(name=>createHash('sha256').update(readFileSync(directory+'/'+name)).digest('hex')+'  '+name).join('\n')+'\n');
mkdirSync('apps/ios/HealthMCP/Resources',{recursive:true});
execFileSync('python3',['-c',`import zipfile,pathlib
source=pathlib.Path('${directory}')
with zipfile.ZipFile('apps/ios/HealthMCP/Resources/HealthMCP-Private-Client.zip','w',zipfile.ZIP_DEFLATED) as archive:
 for name in ['README.md','SHA256SUMS','THIRD-PARTY-NOTICES.txt','decrypt.mjs','decrypt.py','healthmcp-client.mjs']:
  path=source/name
  info=zipfile.ZipInfo(path.name,(2026,9,8,0,0,0)); info.compress_type=zipfile.ZIP_DEFLATED; info.external_attr=0o100644<<16
  archive.writestr(info,path.read_bytes())`]);
console.log('Built trusted client, standalone helpers and signed-app export.');
