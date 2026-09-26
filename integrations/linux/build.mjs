import { build } from 'esbuild';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url)), out=path.join(here,'bundle');
const result=await build({absWorkingDir:here,entryPoints:['cli.mjs','app-server.mjs','worker.mjs'],outdir:out,outExtension:{'.js':'.mjs'},bundle:true,platform:'node',target:'node22',format:'esm',minify:true,legalComments:'linked',write:false,metafile:true,banner:{js:"import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);"}});
let notices=await readFile(path.join(here,'../../LICENSE'),'utf8');
const packageRoots=new Set();
for(const input of Object.keys(result.metafile.inputs)) {
 const absolute=path.resolve(here,input), marker=absolute.lastIndexOf('/node_modules/');
 if(marker<0)continue;
 const parts=absolute.slice(marker+14).split('/'), count=parts[0].startsWith('@')?2:1;
 packageRoots.add(absolute.slice(0,marker+14)+parts.slice(0,count).join('/'));
}
for(const root of [...packageRoots].sort())for(const file of await readdir(root))if(/^licen[sc]e(?:\..*)?$/i.test(file))notices+=`\n\n--- ${path.basename(root)} ---\n\n`+await readFile(path.join(root,file),'utf8');
result.outputFiles.push({path:path.join(out,'LICENSES.txt'),contents:Buffer.from(notices)});
await mkdir(out,{recursive:true});
for(const file of result.outputFiles) {
 if(process.argv.includes('--check')) { if(!(await readFile(file.path)).equals(Buffer.from(file.contents)))throw new Error('Linux bundle is stale: npm run bundle --prefix integrations/linux'); }
 else await writeFile(file.path,file.contents);
}
