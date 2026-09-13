// Synthetic, opt-in native verification. Never targets the installed library.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { request } from './actions.mjs';
const root=process.argv[2];
assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const ready=JSON.parse(await readFile(root+'/ready.json','utf8'));
assert.equal(ready.root,root);assert.equal(ready.socket,root+'/IPC/control.sock');
const identities=JSON.parse(await readFile(root+'/test-credentials.json','utf8'));
const machine=(await request({method:'actions'},{socketPath:ready.socket})).result.machine.id;
const cli=fileURLToPath(new URL('../../src/Resources/BrainCompanion/cli.mjs',import.meta.url));
const appServer=fileURLToPath(new URL('../../src/Resources/BrainCompanion/app-server.mjs',import.meta.url));
const environment=i=>({...process.env,MYMAN_AGENT_SOCKET:ready.socket,MYMAN_AGENT_TOKEN:identities[i].token,MYMAN_MACHINE_ID:machine});
async function command(i,args,extra={}) {
  let stdout;
  try { ({stdout}=await promisify(execFile)(process.execPath,[cli,...args,'--json'],{env:{...environment(i),...extra},maxBuffer:16*1024*1024,timeout:120000})); }
  catch(error) { if(!error.stdout)throw error;stdout=error.stdout; }
  const reply=JSON.parse(stdout);
  if(reply.job?.state==='failed')return {ok:false,error:reply.job.error};
  if(reply.job?.state==='succeeded')return {ok:true,...reply.job.result,job_id:reply.job.id};
  return reply;
}
const act=(i,name,args={})=>command(i,['invoke',name,JSON.stringify(args)]);
function success(value){assert.notEqual(value.ok,false,JSON.stringify(value));return value;}
function denied(value,code){assert.equal(value.ok,false);assert.equal(value.error.code,code);}
const clients=[];
try {
  denied(await command(0,['machine','current'],{MYMAN_MACHINE_ID:'wrong-machine'}),'WRONG_MACHINE');
  denied(await command(0,['machine','current'],{MYMAN_AGENT_TOKEN:''}),'IDENTITY_REQUIRED');
  denied(await act(2,'note.create',{body:'Denied synthetic note'}),'AGENT_SCOPE_DENIED');
  const [a,b]=await Promise.all([act(0,'note.create',{title:'Capture Agent synthetic',body:'Original'}),act(1,'note.create',{title:'Design synthetic',body:'Reference'})]);success(a);success(b);
  denied(await command(1,['job',a.job_id]),'NOT_OWNER');
  const bundle=success(await act(0,'bundle.create',{title:'Synthetic demo bundle',item_ids:[a.id,b.id],members:[identities[1].id]}));
  for(let i=0;i<2;i++) {
    const client=new Client({name:'synthetic-'+i,version:'1'});
    await client.connect(new StdioClientTransport({command:process.execPath,args:[appServer],env:environment(i),stderr:'pipe'}));clients.push(client);
  }
  const revisions=await Promise.all(clients.map((c,i)=>c.callTool({name:'myman_app_bundle_update',arguments:{id:bundle.id,expected_revision:1,title:'Review '+i}})));
  assert.equal(revisions.filter(x=>!x.isError).length,1);
  assert.equal(revisions.find(x=>x.isError).structuredContent.error.code,'EDIT_CONFLICT');
  const handoff=success(await act(0,'handoff.create',{bundle_id:bundle.id,recipient:identities[1].id,instruction:'Review these synthetic references'}));
  success(await act(1,'handoff.update',{id:handoff.id,expected_revision:1,state:'accepted'}));
  success(await act(1,'handoff.update',{id:handoff.id,expected_revision:2,state:'completed',output_ids:[b.id]}));
  const events=success(await act(0,'collaboration.events'));
  assert.ok(events.events.some(x=>x.type==='handoff.completed'));
  const note=success(await act(0,'item.read',{id:a.id}));
  denied(await act(1,'note.update',{id:a.id,body:'Stale',expected_updated_at:'2000-01-01T00:00:00.000Z'}),'EDIT_CONFLICT');
  const lease=success(await act(0,'lease.acquire',{resource:'item:'+a.id,seconds:60}));
  denied(await act(1,'note.append',{id:a.id,body:'Conflicting append',expected_updated_at:note.updated_at}),'RESOURCE_OWNED');
  success(await act(0,'note.append',{id:a.id,body:'Owned append',expected_updated_at:note.updated_at,lease_id:lease.id}));
  success(await act(0,'lease.release',{resource:'item:'+a.id,lease_id:lease.id}));
  const current=success(await act(0,'item.read',{id:a.id}));
  denied(await act(0,'note.append',{id:a.id,body:'Old lease',expected_updated_at:current.updated_at,lease_id:lease.id}),'LEASE_EXPIRED');
  const task=success(await act(0,'task.create',{title:'Synthetic task'}));
  const version=success(await act(0,'resource.version',{kind:'task',id:task.id}));
  success(await act(1,'task.update',{id:task.id,title:'Reviewed task',expected_version:version.version}));
  denied(await act(0,'task.update',{id:task.id,title:'Stale task',expected_version:version.version}),'EDIT_CONFLICT');
  const windows=await command(0,['windows','list']);
  const list=windows.result??windows;
  const window=Object.values(list).find(x=>x?.title==='My Man · isolated verification');
  assert.ok(window,'Fixture window must be visible');
  const recording=success(await act(0,'recording.start',{window_id:window.id,max_duration:8,microphone:false,system_audio:false}));
  denied(await act(1,'recording.stop',{session_id:recording.session_id}),'NOT_OWNER');
  success(await act(0,'session.transfer',{session_id:recording.session_id,recipient:identities[1].id}));
  denied(await act(0,'recording.pause',{session_id:recording.session_id}),'NOT_OWNER');
  const stopped=success(await act(1,'recording.stop',{session_id:recording.session_id}));
  const finished=success(await act(1,'app.wait',{session_id:recording.session_id,timeout:90}));
  assert.equal(finished.state,'finalized');assert.ok(finished.attachment.path);
  // Clean up only this test's explicitly created objects through normal APIs.
  const disposable=success(await act(0,'bundle.create',{title:'Disposable synthetic bundle',item_ids:[a.id],members:[identities[1].id]}));
  denied(await act(1,'bundle.delete',{id:disposable.id,expected_revision:1,confirm:true}),'NOT_OWNER');
  denied(await act(0,'bundle.delete',{id:disposable.id,expected_revision:1,confirm:false}),'CONFIRMATION_REQUIRED');
  success(await act(0,'bundle.delete',{id:disposable.id,expected_revision:1,confirm:true}));
  const taskVersion=success(await act(0,'resource.version',{kind:'task',id:task.id}));
  success(await act(0,'task.delete',{id:task.id,expected_version:taskVersion.version,confirm:true}));
  for(const id of [a.id,b.id,stopped.id??finished.id].filter(Boolean)) {
    const item=success(await act(0,'item.read',{id}));
    success(await act(0,'item.delete',{id,expected_revision:item.revision,confirm:true}));
  }
  const bundles=await command(1,['bundle','list']);assert.equal((bundles.result??[]).length,0);
  await writeFile(root+'/multi-agent-report.json',JSON.stringify({passed:true,mcp_clients:2,cli:true,checks:['identity','machine','scope','job ownership','concurrent bundle edits','handoffs','events','note conflict','leases','task conflict','recording ownership','session transfer','deletion'],host_verified:false},null,2));
  console.log(JSON.stringify({passed:true,report:root+'/multi-agent-report.json'}));
} finally { await Promise.allSettled(clients.map(c=>c.close())); }
