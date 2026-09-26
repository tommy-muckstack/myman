import { chmod, copyFile, lstat, mkdir, open, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

if(process.platform!=='linux')throw new Error('Linux only.');
const source=path.resolve(process.argv[2]);
const prefix=path.resolve(process.env.MYMAN_INSTALL_PREFIX||path.join(homedir(),'.local'));
const config=path.resolve(process.env.XDG_CONFIG_HOME||path.join(homedir(),'.config'),'myman');
const state=path.resolve(process.env.XDG_STATE_HOME||path.join(homedir(),'.local/state'),'myman');
const brain=path.resolve(process.env.MYMAN_BRAIN_ROOT||path.join(homedir(),'MyManBrain'));
async function safeDirectory(dir,privateDir=false) {
  // Check ancestors before mkdir so linked paths cannot redirect installation.
  let ancestor=dir;
  while(true) {try { if(await realpath(ancestor)!==ancestor)throw new Error(`Linked install path: ${ancestor}`);break; }catch(error){if(error.code!=='ENOENT')throw error;ancestor=path.dirname(ancestor);} }
  await mkdir(dir,{recursive:true,mode:0o700});
  const info=await lstat(dir);
  if(!info.isDirectory()||info.isSymbolicLink()||info.uid!==process.getuid())throw new Error(`Unsafe install directory: ${dir}`);
  if(privateDir&&(info.mode&0o077))throw new Error(`Set mode 700 on ${dir}, then rerun.`);
}
async function copy(from,to) {
  await safeDirectory(path.dirname(to));
  const tmp=path.join(path.dirname(to),`.myman-install-${randomUUID()}`);
  await copyFile(from,tmp);await chmod(tmp,0o600);await rename(tmp,to);
}
const install=path.join(prefix,'share/myman');
for(const dir of [install,path.join(prefix,'bin'),brain,path.join(brain,'tools')])await safeDirectory(dir);
for(const dir of [config,state])await safeDirectory(dir,true);
const configFile=path.join(config,'agents.json');
try {
 const handle=await open(configFile,'wx',0o600);
 try {await handle.writeFile(JSON.stringify({version:1,grants:{enabled:false,capture:false,markup:false,recording:false,library:false}},null,2)+'\n');}finally{await handle.close();}
} catch(error){if(error.code!=='EEXIST')throw error;const info=await lstat(configFile);if(!info.isFile()||info.isSymbolicLink()||info.nlink!==1||info.uid!==process.getuid()||(info.mode&0o077))throw new Error(`Unsafe config: ${configFile}`);}
for(const name of ['cli.mjs','app-server.mjs','app-server.mjs.LEGAL.txt','worker.mjs','LICENSES.txt']) {
 await copy(path.join(source,'integrations/linux/bundle',name),path.join(install,name));
 await copy(path.join(source,'integrations/linux/bundle',name),path.join(brain,'tools',name));
}
await copy(path.join(source,'src/Resources/BrainCompanion/server.mjs'),path.join(brain,'tools/server.mjs'));
await copy(path.join(source,'src/Resources/BrainCompanion/LICENSES.txt'),path.join(brain,'tools/BRAIN-LICENSES.txt'));
await copy(path.join(source,'src/Resources/BrainCompanion/cli.mjs'),path.join(install,'brain-cli.mjs'));
await copy(path.join(source,'src/Resources/BrainCompanion/server.mjs'),path.join(install,'server.mjs'));
await copy(path.join(source,'src/Resources/BrainCompanion/LICENSES.txt'),path.join(install,'BRAIN-LICENSES.txt'));
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
const launcher=path.join(prefix,'bin/myman'),temp=launcher+`.${randomUUID()}.tmp`;
await writeFile(temp,`#!/bin/sh\nexec node ${quote(path.join(install,'cli.mjs'))} "$@"\n`,{mode:0o755});await rename(temp,launcher);
for(const dir of ['notes','screenshots','meetings','dictations','recordings','themes','task-items'])await safeDirectory(path.join(brain,dir));
try{const info=await lstat(path.join(brain,'.git'));if(!info.isDirectory()||info.isSymbolicLink())throw new Error('Brain .git must be an ordinary directory.');}
catch(error){if(error.code!=='ENOENT')throw error;try{execFileSync('git',['-C',brain,'init','--quiet'],{stdio:'pipe'});}catch{process.stderr.write('Git is unavailable. Install git before creating notes or screenshots.\n');}}
console.log(`Installed: ${launcher}\nBrain: ${brain}\nOwner grants: ${configFile}\nMCP: node ${path.join(install,'app-server.mjs')}\nRead-only MCP: node ${path.join(install,'server.mjs')}\nAdd ${path.join(prefix,'bin')} to PATH if needed.\nRun: myman doctor --json`);
