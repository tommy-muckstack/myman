// Run only against the debug preview's explicitly isolated Brain and socket.
import { readFile, writeFile, stat } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
const root=process.argv[2],denied=process.argv.includes('--denied');
assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const ready=JSON.parse(await readFile(root+'/ready.json'));assert.equal(ready.root,root);assert.equal(ready.socket,root+'/IPC/control.sock');
const cli=fileURLToPath(new URL('./cli.mjs',import.meta.url));const report=[];
async function run(args,expected=0){
 let stdout,stderr,code=0;try{({stdout,stderr}=await promisify(execFile)(process.execPath,[cli,'--root',root+'/Brain',...args,'--json'],{env:{...process.env,MYMAN_AGENT_SOCKET:ready.socket},maxBuffer:20*1024*1024}));}catch(e){stdout=e.stdout;stderr=e.stderr;code=e.code;}
 assert.equal(code,expected,`${args.join(' ')}: ${stdout} ${stderr}`);assert.equal(stderr,'');assert.equal(stdout.trim().split('\n').length,1);
 const result=JSON.parse(stdout);report.push({command:args.slice(0,2).join(' '),exit:code,ok:result.ok!==false});return result;
}
const doctor=await run(['doctor']);assert.equal(doctor.app.agents.capture,!denied);
if(denied){
 for(const args of [['screenshot','--mode','agent'],['annotate','--id','shot-fixture'],['meeting','start'],['record','start'],['dictation','start'],['note','create','--body','Must not be created'],['library','delete','--id','fixture','--confirm']])assert.equal((await run(args,4)).error.code,'AGENT_DISABLED');
 const config=await run(['settings','get']);assert.equal(config.agents.library,false);
 assert.equal((await run(['settings','set','--key','agentCaptureEnabled','--value','true'],5)).error.code,'INVALID_ARGUMENTS');
}else{
 const note=await run(['note','create','--title','CLI parity fixture','--body','Initial body']);
 const before=await run(['library','read','--id',note.id]);assert.equal(before.title,'CLI parity fixture');
 await run(['note','append','--id',note.id,'--body','Appended body']);
 const after=await run(['library','read','--id',note.id]);assert.equal(after.body,'Initial body\n\nAppended body');assert.equal(after.title,before.title);
 await run(['note','update','--id',note.id,'--body','Must not overwrite','--expected-updated-at',before.updated_at],5);
 const shot=await run(['capture','import','--path',ready.fixture]);
 const ops=JSON.stringify([{op:'box',rect:[20,20,100,60],color:'#FF0000'},{op:'text',at:[30,40],text:'CLI fixture',color:'#0000FF'}]);
 const dry=await run(['annotate','--id',shot.id,'--ops',ops,'--dry-run']);assert.equal(dry.valid,true);assert.equal(dry.annotation_count,2);
 const edited=await run(['annotate','--id',shot.id,'--ops',ops,'--save']);assert.notEqual(edited.id,shot.id);assert.ok((await stat(edited.path)).size>1000);
 await run(['capture','ocr','--id',edited.id]);await run(['capture','copy','--id',edited.id,'--image']);
 if(doctor.app.permissions.screen_recording){
  const windows=await run(['windows','list']);const own=windows.result.find(w=>w.title==='My Man · isolated verification');assert.ok(own);
  const captured=await run(['screenshot','--mode','agent','--window-id',own.id]);assert.ok(captured.scale>0);assert.ok((await stat(captured.path)).size>1000);
  const marked=await run(['capture-markup','--mode','agent','--region',ready.region.join(','),'--ops',ops]);assert.ok((await stat(marked.path)).size>1000);
  const started=await run(['record','start','--region',ready.region.join(','),'--mic','off','--system-audio','off','--webcam','off']);
  await new Promise(r=>setTimeout(r,1600));await run(['record','status']);
  const video=await run(['record','stop','--session-id',started.session_id]);assert.ok((await stat(video.path)).size>1000);
  const discard=await run(['record','start','--region',ready.region.join(','),'--mic','off','--system-audio','off']);await new Promise(r=>setTimeout(r,1100));await run(['record','cancel','--session-id',discard.session_id]);
 }
 const task=await run(['task','add','--title','Fixture followup']);await run(['task','complete','--id',task.id]);await run(['task','reopen','--id',task.id]);
 await run(['theme','add','--id',ready.theme_a,'--item-id',edited.id]);await run(['theme','remove','--id',ready.theme_a,'--item-id',edited.id]);
 // Export is intentionally asynchronous; wait for the new note to be searchable.
 let search;for(let i=0;i<30;i++){search=await run(['library','search','--query','Appended','--kind','notes']);if(search.results?.length)break;await new Promise(r=>setTimeout(r,200));}assert.ok(search.results.length);
 await run(['task','delete','--id',task.id],5);await run(['task','delete','--id',task.id,'--confirm']);
 await run(['library','delete','--id',note.id],5);await run(['library','delete','--id',note.id,'--confirm']);
}
await writeFile(root+'/cli-report.json',JSON.stringify({passed:true,denied,commands:report.length,report},null,2));console.log(JSON.stringify({passed:true,denied,commands:report.length}));
