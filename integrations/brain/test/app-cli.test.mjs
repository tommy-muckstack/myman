import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import { plan, run, exitCode } from '../app-cli.mjs';
import { catalog, describe } from '../actions.mjs';
const ajv=new Ajv({strict:false});
const fixture='shot-fixture';
const cases=[
 ['timer start --seconds 600','timer.start',{seconds:600}],
 ['timer sound --session-id timer-id --enabled off','timer.sound',{session_id:'timer-id',enabled:false}],
 ['timer start --seconds 30 --sound-enabled off','timer.start',{seconds:30,sound_enabled:false}],
 ['reminder sound --id reminder-id --enabled on','reminder.sound',{id:'reminder-id',enabled:true}],
 ['reminder create --seconds 30 --message Pizza --sound-enabled off','reminder.create',{seconds:30,message:'Pizza',sound_enabled:false}],
 ['timer pause --session-id timer-id','timer.pause',{session_id:'timer-id'}],
 ['timer resume --session-id timer-id','timer.resume',{session_id:'timer-id'}],
 ['timer cancel --session-id timer-id','timer.cancel',{session_id:'timer-id'}],
 ['reminder create --seconds 600 --message Pizza','reminder.create',{seconds:600,message:'Pizza'}],
 ['reminder list','reminder.list',{}],
 ['reminder cancel --id reminder-id','reminder.cancel',{id:'reminder-id'}],
 ['tool evaluate --input #fffffd','tool.evaluate',{input:'#fffffd'}],
 ['calendar list --after 2026-09-23T00:00:00Z --before 2026-09-24T00:00:00Z','calendar.list',{after:'2026-09-23T00:00:00Z',before:'2026-09-24T00:00:00Z'}],
 ['screenshot --mode agent --display main --region 0,0,100,200 --wait --json','screenshot.capture',{display:'main',region:[0,0,100,200]}],
 ['screenshot --mode agent --window-id 42 --save-only','screenshot.capture',{window_id:'42'}],
 ['record start --display main --mic off --system-audio off --webcam off','recording.start',{display:'main',microphone:false,system_audio:false,webcam:false}],
 ['record stop --session-id take','recording.stop',{session_id:'take'}],
 ['record cancel --session-id take','recording.cancel',{session_id:'take'}],
 ['meeting start --title Review','meeting.start',{title:'Review'}],
 ['meeting stop --session-id take','meeting.stop',{session_id:'take'}],
 ['meeting rename --session-id take --title Review','meeting.rename',{session_id:'take',title:'Review'}],
 ['meeting cancel --session-id take','meeting.discard',{session_id:'take'}],
 ['dictation start','dictation.start',{}],['dictation stop --session-id take','dictation.stop',{session_id:'take'}],['dictation cancel --session-id take','dictation.cancel',{session_id:'take'}],
 ['note create --title Followups --body Review','note.create',{title:'Followups',body:'Review'}],['note append --id note-fixture --body Next','note.append',{id:'note-fixture',body:'Next'}],
 ['library pin --id shot-fixture','item.pin',{id:fixture,pinned:true}],['library unpin --id shot-fixture','item.pin',{id:fixture,pinned:false}],['library hide --id shot-fixture','item.exclude',{id:fixture,excluded:true}],['library unhide --id shot-fixture','item.exclude',{id:fixture,excluded:false}],['library delete --id shot-fixture --confirm','item.delete',{id:fixture,confirm:true}],
 ['theme add --id theme --item-id shot-fixture','theme.assign',{id:'theme',item_id:fixture}],['theme remove --id theme --item-id shot-fixture','theme.assign',{id:'theme',item_id:fixture,remove:true}],['theme merge --id theme --target-id other','theme.merge',{id:'theme',target_id:'other'}],
 ['task add --title Review','task.create',{title:'Review'}],['task complete --id task','task.update',{id:'task',done:true}],['task reopen --id task','task.update',{id:'task',done:false}],['task delete --id task --confirm','task.delete',{id:'task',confirm:true}],
 ['capture copy --id shot-fixture --text-only','clipboard.write',{id:fixture,format:'text'}],['capture ocr --id shot-fixture','screenshot.ocr',{id:fixture}],['font create --id shot-fixture --name Fixture','font.create',{id:fixture,name:'Fixture'}],
 ['settings set --key automatic_themes --value false','settings.update',{automatic_themes:false}],
];
for(const [command,name,args]of cases)test(command,async()=>{
 const p=await plan(command.split(' '));assert.equal(p.type,'action');assert.equal(p.name,name);assert.deepEqual(p.args,args);
 const validate=ajv.compile(describe(name).inputSchema);assert.ok(validate(p.args),JSON.stringify(validate.errors));
});
test('markup file, colors, text origin and crop map to native pixel schema',async t=>{
 const root=await mkdtemp(path.join(tmpdir(),'myman-cli-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const ops=[{op:'arrow',from:[1,2],to:[40,50],color:'#FF0000'},{op:'text',at:[10,20],text:'Review',font_size:30},{op:'crop',rect:[0,0,100,100]}];
 await writeFile(path.join(root,'ops.json'),JSON.stringify(ops));
 const p=await plan(['annotate','--id',fixture,'--ops-file',path.join(root,'ops.json'),'--dry-run','--json']);
 assert.equal(p.args.annotations.length,2);assert.deepEqual(p.args.annotations[1].rect,[10,20,1,1]);assert.equal(p.args.annotations[0].color,'#FF0000');assert.deepEqual(p.args.crop,[0,0,100,100]);assert.ok(ajv.validate(describe(p.name).inputSchema,p.args));
 await writeFile(path.join(root,'body.md'),'# Followups\n\n- Review');
 assert.equal((await plan(['note','create','--body-file',path.join(root,'body.md')])).args.body,'# Followups\n\n- Review');
});
test('demo reads its steps file and names the app to show',async t=>{
 const root=await mkdtemp(path.join(tmpdir(),'myman-demo-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const script={steps:[{click:[40,30]},{type:'hello'},{key:'cmd+s'}],title:'Spotify in 20 seconds'};
 await writeFile(path.join(root,'steps.json'),JSON.stringify(script));
 const p=await plan(['demo','--app','Spotify','--script',path.join(root,'steps.json'),'--dry-run']);
 assert.equal(p.name,'demo.run');assert.deepEqual(p.args,{app:'Spotify',script,dry_run:true});
 assert.ok(ajv.validate(describe('demo.run').inputSchema,p.args));
 assert.deepEqual(describe('demo.run').permissions,['recording','control']);
 const look=await plan(['demo','--look','--app','Spotify','--window','Library']);assert.deepEqual(look.args,{look:true,app:'Spotify',window:'Library'});assert.ok(ajv.validate(describe('demo.run').inputSchema,look.args));
});
test('legacy UI aliases dispatch only explicit UI and never toggle on an invalid flag',async()=>{
 const opened=[];for(const host of ['open','screenshot','note','dictation','meeting','record','settings','cancel-meeting'])assert.equal((await run([host],{open:async h=>opened.push(h)})).interactive,true);
 assert.equal(opened.length,8);
 for(const args of [['screenshot','--region','0,0,100,100'],['record','start','--mode','interactive'],['note','create','--clipboard'],['screenshot','--mode','agent','--open-editor','--save-only'],['annotate','--id',fixture,'--ops','nope'],['task','list','--bad'],['note','append','--body','a','--body-file','-']])await assert.rejects(plan(args));
});
test('timeouts preserve job IDs; disabled permissions and stale sessions have stable exits',async()=>{
 const running=await run(['record','start','--json'],{invoke:async()=>({ok:true,job:{id:'pending',state:'running'}})});
 assert.equal(running.error.code,'PROCESSING_TIMEOUT');assert.equal(running.job_id,'pending');assert.equal(exitCode(running.error.code),7);
 const pending=await run(['record','start','--no-wait'],{invoke:async()=>({ok:true,job:{id:'pending',state:'running'}})});assert.equal(pending.pending,true);assert.equal(pending.ok,true);
 const denied=await run(['record','start'],{invoke:async()=>({ok:true,job:{id:'test',state:'failed',error:{code:'AGENT_DISABLED'}}})});assert.equal(denied.ok,false);assert.equal(exitCode(denied.error.code),4);
 assert.equal(exitCode('PERMISSION_REQUIRED'),2);assert.equal(exitCode('SESSION_MISMATCH'),5);
});
test('CLI errors are a single stdout JSON object, and stdin creates the requested note body',()=>{
 const cli=fileURLToPath(new URL('../cli.mjs',import.meta.url));
 const bad=spawnSync(process.execPath,[cli,'annotate','--ops','broken','--json'],{encoding:'utf8'});assert.equal(bad.status,5);assert.equal(bad.stderr,'');assert.equal(JSON.parse(bad.stdout).ok,false);assert.equal(bad.stdout.trim().split('\n').length,1);
});
test('retrieval aliases preserve time, kind, and descriptor filters',async()=>{
 const recent=await plan(['library','recent','--kind','screenshots','--limit','4']);assert.equal(recent.name,'recent');assert.deepEqual(recent.args,{kind:'screenshots',limit:4});
 const shots=await plan(['screenshots','--meeting','Jordan demo','--app','Chrome','--exclude-tag','slide-deck']);assert.deepEqual(shots.args,{meeting:'Jordan demo',app:'Chrome',exclude_tags:['slide-deck']});
 const themes=await plan(['theme','list']);assert.equal(themes.name,'collect');assert.deepEqual(themes.args.kinds,['themes']);
});
test('every discoverable action is reachable through invoke and carries explicit consent metadata',async()=>{
 for(const action of catalog.actions){const p=await plan(['invoke',action.name,'{}']);assert.equal(p.name,action.name);assert.ok(Array.isArray(action.permissions));}
});

for(const [command,name,args] of [
 ['record start --window-id 42 --max-duration 30 --mic off','recording.start',{window_id:'42',max_duration:30,microphone:false}],
 ['record pause --session-id take','recording.pause',{session_id:'take'}],
 ['record resume --session-id take','recording.resume',{session_id:'take'}],
 ['record result --session-id take','recording.status',{session_id:'take'}],
 ['record frames --id recording-fixture --times 0.1,2.5 --width 400','recording.frames',{id:'recording-fixture',times:[0.1,2.5],width:400}],
 ['record export --id recording-fixture --start 1 --end 5 --max-bytes 1000000','recording.export',{id:'recording-fixture',start:1,end:5,max_bytes:1000000}],
 ['capture targets --id shot-fixture --query Save','screenshot.targets',{id:'shot-fixture',query:'Save'}],
]) test(command,async()=>{const p=await plan(command.split(' '));assert.equal(p.name,name);assert.deepEqual(p.args,args);assert.ok(ajv.validate(describe(name).inputSchema,p.args));});
test('OCR-targeted preview preserves native target selectors and rejects side effects',async()=>{
 const ops=JSON.stringify([{op:'circle',target_text:'$49'},{op:'callout',target_region:'ocr-fixture',number:2,text:'Review'}]);
 const p=await plan(['annotate','--id',fixture,'--ops',ops,'--preview']);
 assert.equal(p.args.preview,true);assert.equal(p.args.annotations[0].target_text,'$49');assert.ok(ajv.validate(describe(p.name).inputSchema,p.args));
 for(const flags of [['--preview','--clipboard'],['--preview','--open-editor'],['--preview','--dry-run']])await assert.rejects(plan(['annotate','--id',fixture,...flags]));
 await assert.rejects(plan(['record','result']));
 assert.equal(exitCode('AMBIGUOUS_TARGET'),5);
});

for(const [command,name,args]of[
 ['library search --query pricing --kind screenshots --semantic --limit 5','capture.search',{query:'pricing',kind:'screenshots',semantic:true,limit:5}],
 ['note attach --id note-a --source-id shot-a --alt Example','note.attach',{id:'note-a',source_id:'shot-a',alt:'Example'}],
 ['font match --id shot-a --region 1,2,100,80','font.match',{id:'shot-a',region:[1,2,100,80]}],
 ['font preview --id note-a --text ABC','font.preview',{id:'note-a',text:'ABC'}]
])test(command,async()=>{const p=await plan(command.split(' '));assert.equal(p.name,name);assert.deepEqual(p.args,args);assert.ok(ajv.validate(describe(p.name).inputSchema,p.args));});
test('discovery, receipts and explicit offline search route without hidden mutations',async()=>{
 assert.equal((await plan(['actions'])).type,'discovery');assert.equal((await plan(['actions','--offline'])).offline,true);
 assert.equal((await plan(['jobs'])).type,'jobs');assert.equal((await plan(['library','search','--query','pricing','--offline'])).type,'read');
 await assert.rejects(plan(['library','search','--query','pricing','--root','/tmp/other']));
 const interrupted=await run(['note','create','--body','x'],{invoke:async()=>({ok:true,recovered:true,job:{id:'saved',state:'interrupted',error:{code:'APP_RESTARTED'}}})});assert.equal(interrupted.ok,false);assert.equal(interrupted.recovered,true);
});

test('workflow CLI preserves three-part routes, integer revisions and object regions', async () => {
  const scroll = await plan(['capture','scroll','start','--region','{"x":10,"y":20,"width":500,"height":400}']);
  assert.equal(scroll.name,'capture.scroll.start');
  assert.deepEqual(scroll.args.region,{x:10,y:20,width:500,height:400});
  const decision = await plan(['decision','create','--source-id','meeting-fixture','--expected-revision','3','--topic','Launch','--text','Launch Tuesday','--quote','We agreed to launch on Tuesday.']);
  assert.equal(decision.args.expected_revision,3);
  assert.equal((await plan(['workflow','context','--ids','["note-fixture","meeting-fixture"]'])).args.ids.length,2);
  await assert.rejects(plan(['capture','scroll','start','--region','not-json']));
  await assert.rejects(plan(['capture','scroll','stop','extra','--session-id','fixture']));
});
