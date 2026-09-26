import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, readFile, writeFile, chmod, rm, readdir, symlink, realpath, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { randomUUID, createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { catalog } from '../../brain/actions.mjs';
import { captureRect, parseMonitors } from '../images.mjs';
import { command } from '../system.mjs';

const exec=promisify(execFile), here=path.dirname(fileURLToPath(import.meta.url)), repo=path.resolve(here,'../../..');
const entries=['../cli.mjs','../bundle/cli.mjs'].map(p=>path.resolve(here,p));
async function fixture(t) {
  const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-linux-test-'));
  t.after(()=>rm(base,{recursive:true,force:true}));
  const root=path.join(base,'Brain'),config=path.join(base,'config'),state=path.join(base,'state');
  await mkdir(root,{mode:0o700});await mkdir(path.join(config,'myman'),{recursive:true,mode:0o700});
  const env={...process.env,MYMAN_BRAIN_ROOT:root,XDG_CONFIG_HOME:config,XDG_STATE_HOME:state};
  delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
  const grants=async values=>writeFile(path.join(config,'myman/agents.json'),JSON.stringify({version:1,grants:{enabled:false,capture:false,markup:false,recording:false,library:false,...values}}),{mode:0o600});
  await grants({});
  return {base,root,env,grants};
}
async function cli(entry,args,env) {
  let result;try{result=await exec(process.execPath,[entry,...args,'--json'],{env,timeout:90_000,maxBuffer:16*1024*1024});result.code=0;}catch(error){result=error;}
  assert.equal(result.stderr,'','JSON commands must not leak diagnostics into stderr');
  const lines=result.stdout.trim().split('\n');assert.equal(lines.length,1,'one JSON object on stdout');
  return {code:result.code,data:JSON.parse(lines[0])};
}
async function ok(entry,args,env) {const r=await cli(entry,args,env);assert.equal(r.code,0,JSON.stringify(r.data));assert.notEqual(r.data.ok,false,JSON.stringify(r.data));return r.data;}
async function seededImage(f) {
  const im=await command('magick')||await command('convert');assert.ok(im,'ImageMagick required for annotation contract');
  const id=`shot-${randomUUID()}`,relative='screenshots/2026-09-26-fixture.md',file=path.join(f.root,'assets/source.png');
  await mkdir(path.dirname(file),{recursive:true});await mkdir(path.join(f.root,'screenshots'),{recursive:true});
  await exec(im,['-size','320x200','gradient:#224466-#ffffff',file]);
  await writeFile(path.join(f.root,relative),'---\nid: '+id.slice(5)+'\ncaptured: 2026-09-26T10:00:00Z\n---\n# Synthetic screenshot\nOriginal text\n');
  await writeFile(path.join(f.root,'catalog.json'),JSON.stringify({version:1,generated_at:'2026-09-26T10:00:00Z',exports:[{item_id:id,path:relative,kind:'screenshots',title:'Synthetic screenshot',timestamp:'2026-09-26T10:00:00Z',image_path:file,themes:[],pinned:false}]}));
  return {id,file,im};
}
for(const entry of entries) {
 const label=path.relative(repo,entry);
 test(`${label}: grants, unsupported commands, strict JSON, doctor and discovery`,async t=>{
  const f=await fixture(t);
  const caps=await ok(entry,['actions'],f.env);
  assert.equal(caps.platform,'linux');assert.equal(caps.live,true);assert.equal(caps.actions.length,catalog.actions.length);
  assert.deepEqual(caps.permissions,{enabled:false,capture:false,markup:false,recording:false,library:false});
  assert.equal(caps.actions.find(a=>a.name==='meeting.start').supported,false);
  assert.equal(caps.actions.find(a=>a.name==='screenshot.capture').supported,true);
  assert.equal((await ok(entry,['actions','--offline'],f.env)).live,false);
  const action=await ok(entry,['actions','screenshot.capture'],f.env);assert.equal(action.name,'screenshot.capture');assert.ok(action.inputSchema);assert.deepEqual(action.permissions,['capture']);
  for(const args of [['screenshot'],['note','create','--body','private'],['annotate','--id','shot-x','--ops','[]']]) {
   const r=await cli(entry,args,f.env);assert.equal(r.code,4);assert.equal(r.data.error.code,'AGENT_DISABLED');
  }
  for(const args of [['meeting','start'],['dictation','start'],['record','start'],['live-text'],['capture','ocr','--id','shot-x'],['open']]) {
   const r=await cli(entry,args,f.env);assert.equal(r.code,6);assert.equal(r.data.error.code,'unsupported_on_platform');
  }
  const invalid=await cli(entry,['annotate','--id','a','--ops','not-json'],f.env);assert.equal(invalid.code,5);assert.equal(invalid.data.error.code,'INVALID_ARGUMENTS');
  const doc=await ok(entry,['doctor'],f.env);assert.equal(doc.app.platform,'linux');assert.ok(doc.app.dependencies);assert.equal(doc.app.permissions.capture,false);
 });
 test(`${label}: notes, deduplication, pending jobs, git and unchanged Brain CLI`,async t=>{
  const f=await fixture(t);await f.grants({enabled:true,library:true});
  // Existing personal files and staged work are never included in our commit.
  await exec('git',['-C',f.root,'init','--quiet']);await writeFile(path.join(f.root,'personal.txt'),'leave staged');await exec('git',['-C',f.root,'add','personal.txt']);
  const request=randomUUID(),args=['note','create','--body','Local Linux needle evidence','--title','Linux note','--request-id',request];
  const note=await ok(entry,args,f.env);assert.match(note.id,/^note-/);assert.equal(note.git.committed,true);assert.equal(note.job_id,request);
  const again=await ok(entry,args,f.env);assert.equal(again.id,note.id);assert.equal((await readdir(path.join(f.root,'notes'))).length,1);
  const conflict=await cli(entry,['note','create','--body','different','--request-id',request],f.env);assert.equal(conflict.data.error.code,'ID_CONFLICT');
  const search=await ok(entry,['search','--query','needle'],f.env);assert.match(JSON.stringify(search),/Linux note/);
  const native=await ok(path.join(repo,'integrations/brain/cli.mjs'),['search','{"query":"needle"}'],f.env);assert.match(JSON.stringify(native),/Linux note/);
  const files=(await exec('git',['-C',f.root,'show','--pretty=','--name-only','HEAD'])).stdout;assert.match(files,/catalog.json/);assert.doesNotMatch(files,/personal.txt/);
  assert.match((await exec('git',['-C',f.root,'status','--porcelain'])).stdout,/A  personal.txt/);
  const second=randomUUID(),pending=await ok(entry,['note','create','--body','async receipt','--request-id',second,'--no-wait'],f.env);
  assert.equal(pending.job_id,second);
  let receipt;for(let i=0;i<100;i++){receipt=await ok(entry,['job',second],f.env);if(receipt.job.state!=='running')break;await new Promise(r=>setTimeout(r,50));}
  assert.equal(receipt.job.state,'succeeded');assert.equal((await ok(entry,['jobs'],f.env)).jobs.length,2);
  const shared=randomUUID(),sharedArgs=['note','create','--body','Concurrent retry','--request-id',shared];
  const twins=await Promise.all([ok(entry,sharedArgs,f.env),ok(entry,sharedArgs,f.env)]);assert.equal(twins[0].id,twins[1].id);

 });
 test(`${label}: annotation pixels, crop-last, preservation, preview and dry-run`,async t=>{
  const f=await fixture(t);await f.grants({enabled:true,markup:true});const source=await seededImage(f);
  const original=await readFile(source.file),ops=[{op:'box',rect:[10,10,60,40],color:'#FF0000'},{op:'arrow',from:[20,80],to:[100,110]},{op:'highlight',rect:[100,10,80,40],color:'#FFFF00'},{op:'pixelate',rect:[80,80,70,70]},{op:'crop',rect:[5,5,240,160]}];
  const dry=await ok(entry,['annotate','--id',source.id,'--ops',JSON.stringify(ops),'--dry-run'],f.env);assert.equal(dry.valid,true);assert.equal(dry.width,240);assert.equal((await readdir(path.join(f.root,'screenshots'))).length,1);
  const invalid=await cli(entry,['annotate','--id',source.id,'--ops','[{"op":"crop","rect":[0,0,999,50]}]'],f.env);assert.equal(invalid.data.error.code,'INVALID_ARGUMENTS');
  const preview=await ok(entry,['annotate','--id',source.id,'--ops',JSON.stringify(ops),'--preview'],f.env);assert.equal(preview.preview,true);assert.equal((await readdir(path.join(f.root,'screenshots'))).length,1);assert.ok((await stat(preview.path)).size);
  const annotated=await ok(entry,['annotate','--id',source.id,'--ops',JSON.stringify(ops)],f.env);
  assert.equal(annotated.width,240);assert.equal(annotated.height,160);assert.equal(annotated.source_id,source.id);assert.notEqual(annotated.id,source.id);assert.equal(annotated.git.committed,true);
  assert.deepEqual(await readFile(source.file),original);assert.notDeepEqual(await readFile(annotated.path),original);
  const image=await ok(path.join(repo,'integrations/brain/cli.mjs'),['image',JSON.stringify({path:annotated.brain_path})],f.env);assert.equal(image.width,240);assert.equal(image.image.mimeType,'image/png');
  const thumb=await ok(path.join(repo,'integrations/brain/cli.mjs'),['image',JSON.stringify({path:annotated.brain_path,size:'thumbnail'})],f.env);assert.ok(thumb.width<=400);
 });
 test(`${label}: Linux Xvfb screenshot backend, display and region, OCR and text`,{skip:process.platform!=='linux'},async t=>{
  assert.ok(process.env.DISPLAY,'Run Linux contract tests under xvfb-run');
  const f=await fixture(t);await f.grants({enabled:true,capture:true,markup:true});
  const displays=await ok(entry,['screens','list'],f.env);assert.ok(displays.result.length);
  const screen=await ok(entry,['screenshot'],f.env);assert.equal(screen.width,displays.width);assert.equal(screen.ocr_status,'ready');assert.equal(screen.git.committed,true);
  const display=await ok(entry,['screenshot','--display','main'],f.env);assert.equal(display.width,displays.result.find(d=>d.is_main).width);
  const region=await ok(entry,['screenshot','--display','id:0','--region','10,20,300,180'],f.env);assert.equal(region.width,300);assert.equal(region.height,180);
  const global=await ok(entry,['screenshot','--region',`10,${displays.height-200},300,180`],f.env);assert.equal(global.height,180);
  // Exercise automatic fallback with scrot and tesseract absent from PATH.
  const fallback=path.join(f.base,'bin');await mkdir(fallback);
  for(const tool of ['convert','import','xdpyinfo','xrandr','git']) {const executable=await command(tool);if(executable)await symlink(executable,path.join(fallback,tool));}
  const fallbackCapture=await ok(entry,['screenshot','--display','main','--region','0,0,100,100'],{...f.env,PATH:fallback});
  assert.equal(fallbackCapture.backend,'import');assert.equal(fallbackCapture.ocr_status,'unavailable');
  const invalid=await cli(entry,['screenshot','--display','missing'],f.env);assert.equal(invalid.data.error.code,'INVALID_ARGUMENTS');
  const im=await command('magick')||await command('convert');
  // A white fixture guarantees predictable OCR independent of Xvfb's wallpaper.
  await exec(im,['-size','600x180','xc:white',path.join(f.base,'white.png')]);
  await writeFile(region.path,await readFile(path.join(f.base,'white.png')));
  const text=await ok(entry,['annotate','--id',region.id,'--ops',JSON.stringify([{op:'text',at:[20,20],text:'LINUX NEEDLE',font_size:42,color:'#000000'}])],f.env);
  assert.equal(text.ocr_status,'ready');assert.match((await readFile(path.join(f.root,text.brain_path),'utf8')),/LINUX NEEDLE/);
  assert.match(JSON.stringify(await ok(entry,['search','--query','NEEDLE'],f.env)),/screenshots/);
  // XML must remain literal annotation text, never an SVG external resource.
  await ok(entry,['annotate','--id',region.id,'--ops',JSON.stringify([{op:'text',at:[5,5],text:'<image href="file:///etc/passwd"/> & %[@secret]',font_size:16}]),'--preview'],f.env);
 });
}
test('multi-display geometry preserves the CLI coordinate contract',()=>{
 const displays=parseMonitors('Monitors: 2\n 0: +*DP-1 800/200x600/150+0+0 DP-1\n 1: +HDMI-1 640/150x480/120+800+100 HDMI-1',600);
 const desktop={displays,width:1440,height:600};assert.equal(displays.length,2);
 assert.deepEqual(captureRect({display:'id:1',region:[10,20,100,50]},desktop),[810,120,100,50]);
 assert.deepEqual(captureRect({region:[810,430,100,50]},desktop),[810,120,100,50]);
 assert.throws(()=>captureRect({region:[750,0,100,100]},desktop),/one selected display/);
});
test('linked/private config and linked Brain directories fail closed',async t=>{
 const f=await fixture(t);await f.grants({enabled:true,library:true});
 await chmod(path.join(f.env.XDG_CONFIG_HOME,'myman/agents.json'),0o644);
 assert.equal((await cli(entries[0],['note','create','--body','blocked'],f.env)).data.error.code,'UNSAFE_PATH');
 await chmod(path.join(f.env.XDG_CONFIG_HOME,'myman/agents.json'),0o600);
 const outside=path.join(f.base,'outside');await mkdir(outside);await symlink(outside,path.join(f.root,'notes'));
 assert.equal((await cli(entries[0],['note','create','--body','blocked'],f.env)).data.error.code,'UNSAFE_PATH');assert.deepEqual(await readdir(outside),[]);
});
for(const entry of ['../app-server.mjs','../bundle/app-server.mjs',...(process.platform==='linux'?['../../app-server.mjs']:[])])test(`${entry}: identical MCP tool names, permissions and structured unsupported errors`,async t=>{
 const f=await fixture(t),client=new Client({name:'linux-contract',version:'1.0.0'});
 const transport=new StdioClientTransport({command:process.execPath,args:[path.resolve(here,entry)],env:f.env,stderr:'pipe'});
 await client.connect(transport);t.after(()=>client.close());
 const list=await client.listTools();assert.equal(list.tools.length,catalog.actions.length+3);
 for(const action of catalog.actions)assert.ok(list.tools.find(t=>t.name==='myman_app_'+action.name.replaceAll('.','_')));
 const caps=(await client.callTool({name:'myman_app_capabilities',arguments:{}})).structuredContent;assert.equal(caps.platform,'linux');assert.equal(caps.permissions.enabled,false);
 const blocked=await client.callTool({name:'myman_app_screenshot_capture',arguments:{}});assert.equal(blocked.isError,true);assert.equal(blocked.structuredContent.error.code,'AGENT_DISABLED');
 const unsupported=await client.callTool({name:'myman_app_dictation_start',arguments:{}});assert.equal(unsupported.isError,true);assert.equal(unsupported.structuredContent.error.code,'unsupported_on_platform');
 await f.grants({enabled:true,library:true});
 const request=randomUUID(),note=await client.callTool({name:'myman_app_note_create',arguments:{body:'MCP Linux note',_request_id:request}});assert.match(note.structuredContent.id,/^note-/);
 const repeated=await client.callTool({name:'myman_app_note_create',arguments:{body:'MCP Linux note',_request_id:request}});assert.equal(repeated.structuredContent.id,note.structuredContent.id);
});
test('Linux installer is idempotent, preserves grants, and installed bundles run without npm', {skip:process.platform!=='linux'},async t=>{
 const f=await fixture(t);await f.grants({enabled:true,library:true});const env={...f.env,MYMAN_INSTALL_PREFIX:path.join(f.base,'install')};
 for(let i=0;i<2;i++)await exec('bash',[path.join(repo,'scripts/install-linux.sh')],{env});
 const cliPath=path.join(env.MYMAN_INSTALL_PREFIX,'share/myman/cli.mjs');
 const caps=await ok(cliPath,['actions'],env);assert.equal(caps.permissions.library,true);assert.equal(caps.permissions.capture,false);
 const note=await ok(cliPath,['note','create','--body','Installed package works'],env);assert.match(note.id,/^note-/);
 await ok(path.join(f.root,'tools/cli.mjs'),['search','--query','Installed'],env);
});

test('first Linux write preserves legacy documents and catalog entries',async t=>{
 const f=await fixture(t);await f.grants({enabled:true,library:true});await mkdir(path.join(f.root,'notes'));
 await writeFile(path.join(f.root,'notes/legacy.md'),'---\nid: legacy\ncreated: 2026-09-20T10:00:00Z\n---\n# Legacy evidence\nStill searchable.\n');
 await ok(entries[0],['note','create','--body','new evidence'],f.env);
 const result=await ok(path.join(repo,'integrations/brain/cli.mjs'),['search','{"query":"Legacy"}'],f.env);assert.match(JSON.stringify(result),/legacy.md/);
 const before=JSON.parse(await readFile(path.join(f.root,'catalog.json'),'utf8'));before.exports[0].pinned=true;before.exports[0].custom_metadata='preserve';await writeFile(path.join(f.root,'catalog.json'),JSON.stringify(before));
 await ok(entries[0],['note','create','--body','another note'],f.env);
 const after=JSON.parse(await readFile(path.join(f.root,'catalog.json'),'utf8'));assert.deepEqual(after.exports[0],before.exports[0]);
});

test('maximum-size UTF-8 note input remains readable from its durable receipt',async t=>{
 const f=await fixture(t);await f.grants({enabled:true,library:true});
 const body='界'.repeat(349500), file=path.join(f.base,'large-note.md');await writeFile(file,body);
 const request=randomUUID(),args=['note','create','--body-file',file,'--request-id',request];
 const [note,retry]=await Promise.all([ok(entries[1],args,f.env),ok(entries[1],args,f.env)]);assert.equal(note.id,retry.id);assert.equal(note.body,body);
 const receipt=await ok(entries[1],['job',note.job_id],f.env);assert.equal(receipt.job.state,'succeeded');assert.equal(receipt.job.result.id,note.id);
 const bad=await cli(entries[1],['note','create','--body','relative root'],{...f.env,MYMAN_BRAIN_ROOT:'relative'});assert.equal(bad.data.error.code,'INVALID_ROOT');
});
