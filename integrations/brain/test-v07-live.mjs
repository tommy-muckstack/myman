// Opt-in against the isolated debug preview only. Never touches the user's library.
import assert from 'node:assert/strict';
import { readFile, writeFile, copyFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { invoke, discover } from './actions.mjs';
const root=process.argv[2];assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const ready=JSON.parse(await readFile(root+'/ready.json'));assert.equal(ready.root,root);assert.equal(ready.socket,root+'/IPC/control.sock');
process.env.MYMAN_AGENT_SOCKET=ready.socket;
const results=[],owned=[];
async function run(action,args={}){
 process.stderr.write(action+'\n');
 const commands={'app.wait':['wait'],'screenshot.compare':['capture','compare'],'font.quality':['font','quality'],'recording.export':['record','export']};
 if(commands[action]){
  const argv=[...commands[action],'--json'];for(const [key,value] of Object.entries(args))argv.push('--'+key.replaceAll('_','-'),typeof value==='object'?JSON.stringify(value):String(value));
  const {stdout}=await promisify(execFile)(process.execPath,[fileURLToPath(new URL('../../src/Resources/BrainCompanion/cli.mjs',import.meta.url)),...argv],{env:{...process.env,MYMAN_AGENT_SOCKET:ready.socket},timeout:180000,maxBuffer:16*1024*1024});
  const result=JSON.parse(stdout);assert.equal(result.ok,true,stdout);results.push({action,job_id:result.job_id,transport:'packaged_cli'});return result;
 }
 const reply=await invoke(action,args);assert.equal(reply.job?.state,'succeeded',JSON.stringify(reply));results.push({action,job_id:reply.job.id});return reply.job.result;
}
const live=await discover();assert.equal(live.live,true);assert.ok(live.actions.some(a=>a.name==='screenshot.compare'));
const original=await run('screenshot.import',{path:ready.fixture});owned.push(original.id);
await run('app.wait',{id:original.id,stage:'ocr',timeout:30});await run('app.wait',{id:original.id,stage:'indexed',timeout:30});
const words=await run('screenshot.targets',{id:original.id,granularity:'word',query:'verification'});assert.equal(words.total,1);assert.equal(words.regions[0].granularity,'word');
const edited=await run('screenshot.edit',{id:original.id,annotations:[{type:'circle',target_region:words.regions[0].id}]});owned.push(edited.id);
await run('app.wait',{id:edited.id,stage:'ocr',timeout:30});await run('app.wait',{id:edited.id,stage:'indexed',timeout:30});
const comparison=await run('screenshot.compare',{before_id:original.id,after_id:edited.id});assert.ok(comparison.changed_pixels>0);await copyFile(comparison.attachment.path,root+'/comparison.png');
const ignored=await run('screenshot.compare',{before_id:original.id,after_id:edited.id,ignore_rects:[[0,0,original.width,original.height]]});assert.equal(ignored.changed_pixels,0);assert.equal(ignored.compared_pixels,0);
await run('app.wait',{id:original.id,stage:'export',timeout:30});
const job=await run('app.wait',{job_id:results.find(x=>x.action==='screenshot.import').job_id,timeout:1});assert.equal(job.ready,true);
const impossible=await invoke('app.wait',{id:original.id,stage:'notes',timeout:0});assert.equal(impossible.job.error.code,'UNSUPPORTED_STAGE');
const pending=await invoke('note.create',{body:'Synthetic MCP workflow note'},{wait:false});const completion=await run('app.wait',{job_id:pending.job.id,timeout:15});owned.push(completion.job.result.id);
const client=new Client({name:'live-local-agent',version:'1'});
await client.connect(new StdioClientTransport({command:process.execPath,args:[fileURLToPath(new URL('../../src/Resources/BrainCompanion/app-server.mjs',import.meta.url))],env:{...process.env,MYMAN_AGENT_SOCKET:ready.socket},stderr:'pipe'}));
try {
 const discovery=await client.callTool({name:'myman_app_capabilities',arguments:{}});assert.equal(discovery.structuredContent.live,true);
 const response=await client.callTool({name:'myman_app_note_create',arguments:{body:'Created through local MCP'}});assert.ok(!response.isError,JSON.stringify(response));owned.push(response.structuredContent.id);
 const diff=await client.callTool({name:'myman_app_screenshot_compare',arguments:{before_id:original.id,after_id:edited.id}});assert.ok(!diff.isError,JSON.stringify(diff));assert.ok(diff.structuredContent.changed_pixels>0);
} finally {await client.close();}
const font=await run('font.create',{id:original.id,name:'Workflow specimen'});owned.push(font.id);
const quality=await run('font.quality',{id:font.id,text:'Hello Qxz 123'});assert.ok(quality.quality.characters.length>0);assert.ok(quality.quality.capture_next.length>0);assert.ok(quality.attachment.preview_path);await copyFile(quality.attachment.preview_path,root+'/font-quality.png');
let video='not_run';const status=await run('app.status');
if(status.permissions.screen_recording){
 const windows=await run('windows.list');const window=windows.find(w=>(w.title??'').includes('isolated verification'));assert.ok(window,JSON.stringify(windows));
 const start=await run('recording.start',{window_id:window.id,max_duration:5,microphone:false,system_audio:false});
 const finished=await run('app.wait',{session_id:start.session_id,timeout:30});assert.equal(finished.ready,true);owned.push(finished.id);
 const end=Math.min(4,finished.attachment.duration);
 const scale=finished.attachment.width/original.width, word=words.regions[0].rect;
 const zoom=[Math.max(0,(word[0]-80)*scale),Math.max(0,(word[1]-120)*scale+finished.attachment.height-original.height*scale),(word[2]+160)*scale,(word[3]+240)*scale];
 const exported=await run('recording.export',{id:finished.id,start:0,end,edits:[{type:'title',start:0,end:1,text:'MyMan walkthrough'},{type:'step',start:1,end:2,number:1,text:'Inspect the sample'},{type:'caption',start:2,end:3,text:'Captured locally'},{type:'zoom',start:3,end,rect:zoom},{type:'redact',start:0,end,rect:[0,0,50,50]}]});owned.push(exported.id);
 const frames=await run('recording.frames',{id:exported.id,count:8,width:400});await copyFile(frames.contact_sheet.path,root+'/video-frames.png');await copyFile(exported.path,root+'/finished.mp4');assert.ok((await stat(exported.path)).size>1000);video='passed';
}
await writeFile(root+'/v07-report.json',JSON.stringify({passed:true,video,mcp:'passed',actions:results.map(x=>x.action),hugo:'not_available'},null,2));
for(const id of owned)await run('item.delete',{id,confirm:true});
console.log(JSON.stringify({passed:true,video,mcp:'passed',report:root+'/v07-report.json'}));
