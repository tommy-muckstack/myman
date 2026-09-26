import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { procIdentity, processIdentity } from '../process-identity.mjs';
import { capGrants, checkPolicyOwner, defaultGrants, parseGrants } from '../policy.mjs';
const exec=promisify(execFile),here=path.dirname(fileURLToPath(import.meta.url)),repo=path.resolve(here,'../../..');

test('root ceiling can only reduce user grants; malformed policy fails closed',()=>{
 const enabled={...defaultGrants,enabled:true,capture:true};
 assert.deepEqual(capGrants(enabled,null),enabled);
 assert.deepEqual(capGrants(enabled,{...defaultGrants,enabled:true,library:true}),{...defaultGrants,enabled:true});
 for(const value of ['null','[]','{"version":1,"grants":[]}','{"version":1,"grants":{"capture":"true"}}','{"version":1,"grants":{"typo":true}}'])assert.throws(()=>parseGrants(value),{code:'INVALID_CONFIG'});
 const rootFile={uid:0,mode:0o100644,nlink:1,isSymbolicLink:()=>false,isFile:()=>true,isDirectory:()=>false};
 checkPolicyOwner(rootFile);
 for(const altered of [{uid:1000},{mode:0o100666},{nlink:2},{isSymbolicLink:()=>true}])assert.throws(()=>checkPolicyOwner({...rootFile,...altered}),{code:'INVALID_SYSTEM_POLICY'});
});
test('/proc identity preserves field 22 through spaces and parentheses and rejects zombies',()=>{
 const boot='11111111-2222-3333-4444-555555555555';
 const stat=`12 (worker (nested) name)) S ${Array(18).fill('0').join(' ')} 987654321012345678 0 0`;
 assert.deepEqual(procIdentity(stat,boot),{boot_id:boot,start_ticks:'987654321012345678'});
 assert.equal(procIdentity(stat.replace(')) S ', ')) Z '),boot),null);
 assert.throws(()=>procIdentity('garbage',boot),{code:'PROCESS_IDENTITY_UNAVAILABLE'});
});
test('a reused PID, changed boot ID or legacy PID-only receipt cannot remain running',async t=>{
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-identity-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const jobs=path.join(base,'myman/jobs');await mkdir(jobs,{recursive:true,mode:0o700});
 const identity=await processIdentity(process.pid);assert.ok(identity,'Current process identity must be readable');
 const env={...process.env,XDG_STATE_HOME:base};delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
 for(const entry of ['cli.mjs','bundle/cli.mjs']) {
  for(const [kind,expected] of [['live','running'],['reused','interrupted'],['boot','interrupted'],['legacy','interrupted']]) {
   const id=randomUUID(),token={...identity};
   if(kind==='reused') {if(token.start_ticks)token.start_ticks='0';else token.start_time='old process';}
   if(kind==='boot') {if(token.boot_id)token.boot_id='00000000-0000-0000-0000-000000000000';else token.start_time='previous boot';}
   const receipt={id,state:'running',created_at:new Date().toISOString(),pid:process.pid,...(kind==='legacy'?{}:{process_identity:token}),action:'note.create',launch_id:randomUUID()};
   await writeFile(path.join(jobs,id+'.json'),JSON.stringify(receipt),{mode:0o600});
   let output;try{output=await exec(process.execPath,[path.resolve(here,'..',entry),'job',id,'--json'],{env});}catch(e){output=e;}
   const result=JSON.parse(output.stdout);assert.equal(result.job.state,expected,JSON.stringify(result));
   if(expected==='interrupted')assert.equal(result.job.error.code,'JOB_INTERRUPTED');
  }
 }
});
test('non-Linux/non-Mac dispatch fails explicitly without starting a Mac MCP server',async()=>{
 for(const platform of ['win32','freebsd']) {
  const script=`Object.defineProperty(process,'platform',{value:${JSON.stringify(platform)}});await import(${JSON.stringify(pathToFileURL(path.join(repo,'integrations/app-server.mjs')).href)});`;
  let result;try{result=await exec(process.execPath,['--input-type=module','-e',script]);}catch(e){result=e;}
  assert.equal(result.code,6);assert.equal(result.stdout,'');assert.equal(JSON.parse(result.stderr).error.code,'unsupported_on_platform');
 }
});
test('packaged archive has a verifiable adjacent SHA-256 checksum',async t=>{
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-checksum-'));t.after(()=>rm(base,{recursive:true,force:true}));
 await exec(process.execPath,[path.resolve(here,'../package.mjs'),base]);
 const file=path.join(base,'myman-linux-x64.tar.gz'),digest=createHash('sha256').update(await readFile(file)).digest('hex');
 assert.equal(await readFile(file+'.sha256','utf8'),`${digest}  myman-linux-x64.tar.gz\n`);
});
