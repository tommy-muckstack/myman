import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
const exec=promisify(execFile),here=path.dirname(fileURLToPath(import.meta.url));
const sudo=(...args)=>exec('sudo',['-n',...args]);
// Opt-in on the disposable Ubuntu CI runner only. Never overwrite a host policy.
test('root-owned policy caps both source/bundled CLI and MCP and rejects unsafe policies', {skip:process.platform!=='linux'||process.env.MYMAN_TEST_SYSTEM_POLICY!=='1'},async t=>{
 await assert.rejects(lstat('/etc/myman'),{code:'ENOENT'},'Policy test requires a fresh disposable host');
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-system-policy-'));
 const env={...process.env,MYMAN_BRAIN_ROOT:path.join(base,'Brain'),XDG_CONFIG_HOME:path.join(base,'config'),XDG_STATE_HOME:path.join(base,'state')};delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
 await mkdir(env.MYMAN_BRAIN_ROOT,{mode:0o700});await mkdir(path.join(env.XDG_CONFIG_HOME,'myman'),{recursive:true,mode:0o700});
 const userFile=path.join(env.XDG_CONFIG_HOME,'myman/agents.json'),policySource=path.join(base,'policy.json');
 const user={version:1,grants:{enabled:true,capture:true,markup:true,recording:true,library:true}};
 await writeFile(userFile,JSON.stringify(user),{mode:0o600});
 await sudo('install','-d','-o','root','-g','root','-m','0755','/etc/myman');
 t.after(async()=>{await sudo('rm','-f','/etc/myman/agents.json');await sudo('rmdir','/etc/myman');await rm(base,{recursive:true,force:true});});
 async function policy(value) {
  await writeFile(policySource,typeof value==='string'?value:JSON.stringify(value));
  await sudo('rm','-f','/etc/myman/agents.json');
  await sudo('install','-o','root','-g','root','-m','0644',policySource,'/etc/myman/agents.json');
 }
 async function cli(entry,args,environment=env) {
  let result;try{result=await exec(process.execPath,[path.resolve(here,'..',entry),...args,'--json'],{env:environment});}catch(e){result=e;}
  assert.equal(result.stderr,'');return JSON.parse(result.stdout);
 }
 for(const entry of ['cli.mjs','bundle/cli.mjs']) {
  await policy({version:1,grants:{enabled:true,library:true}});
  const allowed=await cli(entry,['note','create','--body','System ceiling allows this note']);assert.equal(allowed.ok,true);
  assert.equal((await cli(entry,['screenshot'])).error.code,'AGENT_DISABLED');
  const caps=await cli(entry,['actions']);assert.equal(caps.permissions.capture,false);assert.equal(caps.permissions.library,true);
  // Environment variables cannot redirect the fixed system ceiling.
  assert.equal((await cli(entry,['screenshot'],{...env,MYMAN_SYSTEM_POLICY:policySource})).error.code,'AGENT_DISABLED');
  await policy({version:1,grants:{enabled:false,library:true}});
  assert.equal((await cli(entry,['note','create','--body','blocked'])).error.code,'AGENT_DISABLED');
  await policy('{broken');assert.equal((await cli(entry,['note','create','--body','blocked'])).error.code,'INVALID_SYSTEM_POLICY');
  await policy(user);await sudo('chmod','0666','/etc/myman/agents.json');
  assert.equal((await cli(entry,['note','create','--body','blocked'])).error.code,'INVALID_SYSTEM_POLICY');
  await policy(user);await sudo('chown',String(process.getuid()),'/etc/myman/agents.json');
  assert.equal((await cli(entry,['note','create','--body','blocked'])).error.code,'INVALID_SYSTEM_POLICY');
  await policy(user);await sudo('chmod','0777','/etc/myman');
  try {assert.equal((await cli(entry,['note','create','--body','blocked'])).error.code,'INVALID_SYSTEM_POLICY');}finally{await sudo('chmod','0755','/etc/myman');}
  await sudo('rm','-f','/etc/myman/agents.json');await sudo('ln','-s',path.join(base,'missing'),'/etc/myman/agents.json');
  assert.equal((await cli(entry,['note','create','--body','blocked'])).error.code,'INVALID_SYSTEM_POLICY');
 }
 for(const server of ['app-server.mjs','bundle/app-server.mjs']) {
  await policy({version:1,grants:{enabled:true}});
  const client=new Client({name:'system-policy-test',version:'1.0.0'});
  const transport=new StdioClientTransport({command:process.execPath,args:[path.resolve(here,'..',server)],env,stderr:'pipe'});
  await client.connect(transport);
  try {const result=await client.callTool({name:'myman_app_note_create',arguments:{body:'blocked by system ceiling'}});assert.equal(result.isError,true);assert.equal(result.structuredContent.error.code,'AGENT_DISABLED');}finally{await client.close();}
 }
});
