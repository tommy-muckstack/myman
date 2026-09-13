import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { mkdtemp, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { catalog } from '../actions.mjs';
import { plan } from '../app-cli.mjs';

test('CLI routes compare, word targeting, video timeline, wait and quality through the shared catalog', async () => {
  for (const [argv,name] of [
    [['capture','compare','--before-id','shot-a','--after-id','shot-b','--ignore-rects','[[0,0,10,10]]'],'screenshot.compare'],
    [['capture','targets','--id','shot-a','--granularity','word'],'screenshot.targets'],
    [['record','export','--id','recording-a','--edits','[{"type":"caption","start":0,"end":1,"text":"Hello"}]'],'recording.export'],
    [['wait','--id','shot-a','--stage','ocr','--timeout','1'],'app.wait'],
    [['font','quality','--id','note-a','--text','Hello'],'font.quality'],
  ]) { const value=await plan(argv); assert.equal(value.name,name); assert.equal(value.type,'action'); }
});

for (const entry of ['../app-server.mjs','../../../src/Resources/BrainCompanion/app-server.mjs']) {
test(`app MCP discovers strict action tools, preserves permission errors and request IDs: ${entry}`, {timeout:15000}, async t => {
  const root=await mkdtemp(path.join(tmpdir(),'man-app-mcp-')); await chmod(root,0o700);
  t.after(()=>rm(root,{recursive:true,force:true}));
  const socket=path.join(root,'control.sock'), calls=[];
  const server=net.createServer(client=>client.once('data',data=>{
    const message=JSON.parse(data);calls.push(message);
    const reply=message.method==='actions'?{ok:true,result:{...catalog,app_version:'test',permissions:{library:false}}}
      :{ok:true,launch_id:'test',job:{id:message.id,state:'failed',error:{code:'AGENT_DISABLED',message:'Enable library in MyMan Settings'}}};
    client.end(JSON.stringify(reply)+'\n');
  }));
  await new Promise(resolve=>server.listen(socket,resolve));await chmod(socket,0o600);
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const client=new Client({name:'test-agent',version:'1'});
  await client.connect(new StdioClientTransport({command:process.execPath,args:[fileURLToPath(new URL(entry,import.meta.url))],env:{...process.env,MYMAN_AGENT_SOCKET:socket},stderr:'pipe'}));
  t.after(()=>client.close());
  const {tools}=await client.listTools();
  assert.equal(tools.length,catalog.actions.length+3);
  assert.ok(tools.some(x=>x.name==='myman_app_screenshot_compare'));
  assert.equal(tools.find(x=>x.name==='myman_app_item_delete').annotations.destructiveHint,true);
  assert.equal(tools.find(x=>x.name==='myman_app_note_create').annotations.readOnlyHint,false);
  assert.ok(!tools.some(x=>/shell|exec|permission_grant/.test(x.name)));
  const live=await client.callTool({name:'myman_app_capabilities',arguments:{}});
  assert.equal(live.structuredContent.live,true);
  const id='12345678-1234-4234-9234-123456789012';
  const denied=await client.callTool({name:'myman_app_note_create',arguments:{body:'Synthetic text',_request_id:id}});
  assert.equal(denied.isError,true);assert.equal(denied.structuredContent.error.code,'AGENT_DISABLED');
  const invocation=calls.find(x=>x.method==='invoke');assert.equal(invocation.id,id);assert.deepEqual(invocation.arguments,{body:'Synthetic text'});
  const before=calls.length;
  const invalid=await client.callTool({name:'myman_app_note_create',arguments:{body:'Synthetic',unrecognized:true}});
  assert.equal(invalid.isError,true);assert.equal(calls.length,before,'Invalid arguments never reach the app');
  await client.close();
});
}
