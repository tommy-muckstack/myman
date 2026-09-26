import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const destination=path.resolve(process.argv[2]||path.join(root,'.build/linux'));
await mkdir(destination,{recursive:true});
const temp=await mkdtemp(path.join(tmpdir(),'myman-linux-package-'));
try {
 const stage=path.join(temp,'myman-linux-x64');await mkdir(stage);
 for(const relative of ['scripts/install-linux.sh','integrations/linux/install.mjs','integrations/linux/bundle','src/Resources/BrainCompanion/server.mjs','src/Resources/BrainCompanion/cli.mjs','src/Resources/BrainCompanion/LICENSES.txt','src/Resources/Fonts/Outfit-SemiBold.ttf','src/Resources/Fonts/Outfit-OFL.txt','README.md','docs/linux-agents.md','LICENSE']) {
  await mkdir(path.dirname(path.join(stage,relative)),{recursive:true});
  await cp(path.join(root,relative),path.join(stage,relative),{recursive:true});
 }
 const file=path.join(destination,'myman-linux-x64.tar.gz');
 execFileSync('tar',['-czf',file,'-C',temp,'myman-linux-x64']);
 const checksum=createHash('sha256').update(await readFile(file)).digest('hex');
 await writeFile(file+'.sha256',`${checksum}  ${path.basename(file)}\n`);
 console.log(file);
 console.log(file+'.sha256');
} finally { await rm(temp,{recursive:true,force:true}); }
