import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=path.dirname(fileURLToPath(import.meta.url)), output=path.resolve(root,'../../src/Resources/FontWorkbench');
const result=await build({entryPoints:[path.join(root,'workbench.ts')],bundle:true,write:false,format:'iife',platform:'browser',target:'safari17',minify:true,legalComments:'inline'});
await mkdir(output,{recursive:true});
const files=new Map([['workbench.js',Buffer.from(result.outputFiles[0].contents)]]);
for(const name of ['index.html','workbench.css']) files.set(name,await readFile(path.join(root,name)));
let notices='MyMan Font Workbench. Engine adapted from Font Clone, d2098420570ead28ee741b043cf3e7bb7ae7ceb4.\n\n';
for(const [name,file] of [['opentype.js','LICENSE'],['imagetracerjs','LICENSE'],['string.prototype.codepointat','LICENSE-MIT.txt'],['tiny-inflate','LICENSE']]) notices+=`\n${name}\n${await readFile(path.join(root,'node_modules',name,file),'utf8')}\n`;
files.set('LICENSES.txt',Buffer.from(notices));
for(const [name,bytes] of files) {
  const target=path.join(output,name);
  if(process.argv.includes('--check')) { if(!bytes.equals(await readFile(target))) throw new Error(`Rebuild FontWorkbench/${name}`); }
  else await writeFile(target,bytes);
}
