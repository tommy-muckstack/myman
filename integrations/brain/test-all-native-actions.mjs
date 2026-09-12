// Explicit isolated verification only. No user library or installed app is used.
import assert from 'node:assert/strict';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { catalog, invoke, request } from './actions.mjs';
import { Brain } from './brain.mjs';
import { execute, tools } from './tools.mjs';
import { randomUUID } from 'node:crypto';
const root = process.argv[2]; assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const fixture = JSON.parse(await readFile(root+'/ready.json')); assert.equal(fixture.root,root);
assert.equal(fixture.socket,root+'/IPC/control.sock');
process.env.MYMAN_AGENT_SOCKET=fixture.socket;
const covered = new Set(), report=[];
async function run(action,args={},expected) {
  process.stderr.write(`Testing ${action}\n`);
  let result;
  try { result = await invoke(action,args); }
  catch(error) { if(!expected)throw error;result={job:{state:'failed',error:{code:error.code}}}; }
  if(expected) assert.equal(result.job.error?.code,expected,JSON.stringify(result));
  else assert.equal(result.job.state,'succeeded',JSON.stringify(result));
  covered.add(action); report.push({action,state:result.job.state,error:result.job.error});
  await writeFile(root+'/all-actions-progress.json',JSON.stringify(report,null,2));
  return result.job.result;
}
const status = await run('app.status'); assert.equal(status.version,'1.1.60-preview');
await run('app.doctor');
await run('screens.list'); await run('app.open',{surface:'search'});
const settings = await run('settings.read');
await run('settings.update',{automatic_themes:false});
await run('settings.update',{automatic_themes:settings.automatic_themes});
const note = await run('note.create',{body:'# Agent test note\nCapture workflow verification.'});
await run('note.append',{id:note.id,body:'Appended fixture.'});
const original = await run('item.read',{id:note.id});
await run('note.update',{id:note.id,body:'# Agent test note\nUpdated fixture.',expected_updated_at:original.updated_at});
await run('note.update',{id:note.id,body:'Conflict',expected_updated_at:original.updated_at},'EDIT_CONFLICT');
await run('item.rename',{id:note.id,title:'Renamed fixture'});
await run('item.pin',{id:note.id,pinned:true});
await run('item.exclude',{id:note.id,excluded:true}); await run('item.exclude',{id:note.id,excluded:false});
const shot = await run('screenshot.import',{path:fixture.fixture});
const edit = await run('screenshot.edit',{id:shot.id,annotations:[{type:'box',rect:[20,20,500,200]},{type:'arrow',from:[60,250],to:[200,300]},{type:'text',rect:[40,80,500,80],text:'CLI verification'},{type:'highlight',rect:[50,400,450,70]},{type:'pixelate',rect:[720,20,100,80]},{type:'image',rect:[650,400,180,120],path:fixture.fixture}],background:'ocean',corner_radius:18});
assert.notEqual(shot.path,edit.path);
await run('screenshot.ocr',{id:shot.id});
const pixels = await run('screenshot.image',{id:edit.id}); assert.equal(pixels.image.mimeType,'image/png');
await run('clipboard.write',{text:'My Man agent fixture'});
assert.equal((await run('clipboard.read',{format:'text'})).text,'My Man agent fixture');
await run('clipboard.write',{id:edit.id});
const clip = await run('clipboard.read',{format:'image'}); await writeFile(root+'/all-actions-clipboard.png',Buffer.from(clip.image.data,'base64'));
// A flat text screenshot may correctly have no separable foreground.
const cutout = await invoke('screenshot.remove_background',{id:shot.id});
assert.ok(cutout.job.state==='succeeded'||cutout.job.error?.code==='NO_FOREGROUND',JSON.stringify(cutout)); covered.add('screenshot.remove_background'); report.push({action:'screenshot.remove_background',state:cutout.job.state,error:cutout.job.error});
await run('theme.assign',{id:fixture.theme_a,item_id:shot.id});
await run('theme.assign',{id:fixture.theme_b,item_id:note.id});
await run('theme.rename',{id:fixture.theme_a,title:'Agent capture fixtures'});
await run('theme.pin',{id:fixture.theme_a,pinned:true});
await run('theme.merge',{id:fixture.theme_b,target_id:fixture.theme_a});
await run('item.related',{id:shot.id});
await run('theme.assign',{id:fixture.theme_a,item_id:shot.id,remove:true});
await run('theme.dismiss',{id:fixture.theme_a});
const task = await run('task.create',{title:'Verify CLI fixture',notes:'Temporary task',due:'2026-09-12T12:00:00-04:00'});
await run('task.update',{id:task.id,title:'Verified CLI',done:true,clear_due:true}); await run('task.delete',{id:task.id,confirm:true});
await run('meeting.notes',{id:fixture.meeting_id});
const config=await run('meeting.config.read');
await run('meeting.config.update',{auto_record_meetings:config.auto_record_meetings});
const meeting = await run('meeting.start',{title:'Agent recording fixture'});
await run('meeting.rename',{session_id:meeting.session_id,title:'Renamed agent fixture'});
await new Promise(r=>setTimeout(r,1100));
await run('meeting.stop',{session_id:meeting.session_id});
const discarded = await run('meeting.start',{title:'Discard fixture'});
await run('meeting.discard',{session_id:discarded.session_id});
const voice = await run('dictation.start');
const stop = await invoke('dictation.stop',{session_id:voice.session_id});
assert.ok(stop.job.state==='succeeded'||stop.job.error?.code==='TRANSCRIPTION_FAILED',JSON.stringify(stop)); covered.add('dictation.stop'); report.push({action:'dictation.stop',state:stop.job.state,error:stop.job.error});
const cancelled = await run('dictation.start'); await run('dictation.cancel',{session_id:cancelled.session_id});
if(status.permissions.screen_recording) {
  const windows=await run('windows.list');
  const ownWindow=windows.find(w=>w.title==='My Man · isolated verification');
  assert.ok(ownWindow);
  await run('screenshot.capture',{window_id:ownWindow.id});
  await run('screenshot.capture_markup',{region:fixture.region,annotations:[{type:'box',rect:[20,20,100,100],color:'#FF0000'}]});
  await run('screenshot.capture',{region:fixture.region});
  const recording=await run('recording.start',{region:fixture.region,microphone:false});
  await run('recording.microphone',{session_id:recording.session_id,enabled:false});
  await new Promise(r=>setTimeout(r,1800));
  const movie=await run('recording.stop',{session_id:recording.session_id}); assert.ok((await stat(movie.path)).size>1000);
  await run('clipboard.write',{id:movie.id});
  const cancel=await run('recording.start',{region:fixture.region,microphone:false,system_audio:false});
  await new Promise(r=>setTimeout(r,1100));
  await run('recording.cancel',{session_id:cancel.session_id});
}
const font=await run('font.create',{id:shot.id,name:'Agent complete font'});
assert.equal((await readFile(font.path)).subarray(0,4).toString(),'OTTO');
await run('font.file',{id:font.id}); await run('font.open',{id:font.id});
await run('item.open',{id:font.id});
// Give exported read tools their normal asynchronous publication window.
const brain=new Brain(root+'/Brain');
let list; for(let n=0;n<50;n++){ list=await execute(brain,'collect',{query:'Agent complete font'}); if(list.results?.length)break; await new Promise(r=>setTimeout(r,200)); }
const queryArgs={status:{},search:{query:'fixture'},recent:{},meetings:{query:'fixture'},collect:{},screenshots:{},meeting_screenshots:{meeting_path:''},read:{path:''},image:{path:''},tasks:{state:'all'}};
const meetings=await execute(brain,'meetings',{query:'CLI fixture meeting'});
queryArgs.meeting_screenshots.meeting_path=meetings.results?.[0]?.path;
const screenshots=await execute(brain,'screenshots',{});queryArgs.image.path=screenshots.results?.[0]?.path;
queryArgs.read.path=queryArgs.image.path;
const queried=[];
for(const name of Object.keys(tools)) { await execute(brain,name,queryArgs[name]); queried.push(name); }
const cached = await invoke('item.read',{id:note.id});
await run('item.delete',{id:note.id,confirm:true});
await assert.rejects(request({method:'job',id:cached.job.id}),{code:'JOB_NOT_FOUND'});
await run('history.clear',{confirm:false},'CONFIRMATION_REQUIRED');
await run('history.clear',{confirm:true});
const missing=catalog.actions.filter(a=>!covered.has(a.name)).map(a=>a.name);
assert.deepEqual(missing,[]);
await writeFile(root+'/all-actions-report.json',JSON.stringify({passed:true,advertised:catalog.actions.length,covered:[...covered],queried,report},null,2));
console.log(JSON.stringify({passed:true,actions:covered.size,queries:queried.length,report:root+'/all-actions-report.json'}));
