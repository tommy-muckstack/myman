// Opt-in integration test against the isolated debug app, never a real library.
import assert from 'node:assert/strict';
import { readFile, writeFile, copyFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const root=process.argv[2];
assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const ready=JSON.parse(await readFile(root+'/ready.json'));
assert.equal(ready.socket,root+'/IPC/control.sock');
const agents=JSON.parse(await readFile(root+'/test-credentials.json'));
const cli=fileURLToPath(new URL('../../src/Resources/BrainCompanion/cli.mjs',import.meta.url));
const appServer=fileURLToPath(new URL('../../src/Resources/BrainCompanion/app-server.mjs',import.meta.url));
let machine;
const environment=actor=>({...process.env,MYMAN_AGENT_SOCKET:ready.socket,MYMAN_AGENT_TOKEN:agents[actor].token,...(machine?{MYMAN_MACHINE_ID:machine}:{})});
let commands=0;
async function call(actor,args,expectedError){
  let stdout;
  try { ({stdout}=await promisify(execFile)(process.execPath,[cli,...args,'--json'],{env:environment(actor),maxBuffer:20*1024*1024})); }
  catch(error) { if(!error.stdout)throw error;stdout=error.stdout; }
  const result=JSON.parse(stdout);commands++;
  if(expectedError)assert.equal(result.error?.code,expectedError,JSON.stringify(result));
  else assert.notEqual(result.ok,false,JSON.stringify(result));
  return result;
}
machine=(await call(0,['machine','current'])).id;
assert.equal((await call(0,['workflow','check'])).ready_for_brief_work,true);
await call(2,['workflow','check'],'WORKFLOW_SETUP_REQUIRED');
const templates=await call(0,['workflow','templates']);assert.equal(templates.templates.length,2);
const before=await call(0,['capture','import','--path',ready.fixture]);
const after=await call(0,['annotate','--id',before.id,'--ops',JSON.stringify([{op:'text',at:[80,260],text:'Order confirmed · one order',color:'#2255AA'}]),'--save']);
await call(0,['wait','--id',after.id,'--stage','ocr','--timeout','30']);
const comparison=await call(0,['capture','compare','--before-id',before.id,'--after-id',after.id]);
const proof=await call(0,['capture','import','--path',comparison.attachment.path]);
await call(0,['wait','--id',proof.id,'--stage','ocr','--timeout','30']);
await call(0,['brief','create','--title','Invalid frame','--recipe','bug-fix','--outcome','Check frame bounds','--criteria','["Frame exists"]','--source-ids','["recording-brief-fixture"]','--frame-times','[999]'],'INVALID_ARGUMENTS');
const brief=await call(0,['brief','create','--title','Checkout review','--recipe','bug-fix','--outcome','Create one order and show confirmation','--criteria','["Confirmation is visible","Only one order is created"]','--source-ids','["recording-brief-fixture"]','--frame-times','[1,3]']);
const id=brief.id;
await call(0,['brief','handoff','--id',id,'--expected-revision','1','--worker',agents[0].id,'--reviewer',agents[1].id]);
await call(1,['brief','submit','--id',id,'--expected-revision','2','--output-ids',JSON.stringify([proof.id]),'--summary','Forbidden worker'],'NOT_OWNER');
await call(2,['brief','read','--id',id],'AGENT_SCOPE_DENIED');
const clients=[];
try {
  for(let actor=0;actor<2;actor++){
    const client=new Client({name:'brief-fixture-'+actor,version:'1'});
    await client.connect(new StdioClientTransport({command:process.execPath,args:[appServer],env:environment(actor),stderr:'pipe'}));clients.push(client);
  }
  const context=await clients[0].callTool({name:'myman_app_brief_read',arguments:{id,include_context:true}});
  assert.notEqual(context.isError,true,JSON.stringify(context));
  assert.equal(context.structuredContent.transcript_timing,'unavailable');
  assert.equal(context.structuredContent.visual_context.frames.length,2);
  assert.ok(context.structuredContent.transcript.includes('checkout'));
  const submitted=await clients[0].callTool({name:'myman_app_brief_submit',arguments:{id,expected_revision:2,output_ids:[proof.id],summary:'Synthetic confirmation comparison ready for review.'}});
  assert.equal(submitted.structuredContent.stage,'awaiting_review');
  const checks=[0,1].map(criterion=>({criterion,passed:true,evidenceIDs:[proof.id],note:'Synthetic fixture check; not a real checkout claim.'}));
  const selfReview=await clients[0].callTool({name:'myman_app_brief_review',arguments:{id,expected_revision:3,checks}});
  assert.equal(selfReview.structuredContent.error.code,'NOT_OWNER');
  const reviewed=await clients[1].callTool({name:'myman_app_brief_review',arguments:{id,expected_revision:3,checks}});
  assert.equal(reviewed.structuredContent.stage,'reviewed');
  await call(0,['brief','refresh','--id',id,'--expected-revision','2'],'EDIT_CONFLICT');
  await call(0,['brief','export','--id',id,'--expected-revision','4','--public-title','Checkout, clarified','--public-summary','Two agents turned a recorded brief into a visual review. This is a synthetic demonstration.','--output-ids',JSON.stringify([proof.id])],'INVALID_ARGUMENTS');
  const page=await call(0,['brief','export','--id',id,'--expected-revision','4','--public-title','Checkout, clarified','--public-summary','Two agents turned a recorded brief into a visual review. This is a synthetic demonstration.','--output-ids',JSON.stringify([proof.id]),'--confirm']);
  assert.equal(page.published,false);
  const html=await readFile(page.attachment.path,'utf8');
  for(const privateValue of [root,agents[0].token,agents[1].token,'The checkout button should confirm the order once'])assert.ok(!html.includes(privateValue));
  await copyFile(page.attachment.path,root+'/result.html');
  await call(0,['brief','open','--id',id]);
  await writeFile(root+'/brief-report.json',JSON.stringify({passed:true,commands,mcp_clients:2,frames:2,brief_id:id,proof_id:proof.id,host_dispatch:'not_tested',host_attachment_delivery:'not_tested'},null,2));
  console.log(JSON.stringify({passed:true,commands,mcp_clients:2,frames:2}));
} finally { await Promise.all(clients.map(client=>client.close())); }
