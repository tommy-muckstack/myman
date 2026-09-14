// Opt-in, synthetic library only. Never points at the installed app's socket.
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
const root=process.argv[2];assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const ready=JSON.parse(await readFile(root+'/ready.json'));assert.equal(ready.socket,root+'/IPC/control.sock');
const agents=JSON.parse(await readFile(root+'/test-credentials.json'));
const cli=fileURLToPath(new URL('../../src/Resources/BrainCompanion/cli.mjs',import.meta.url));
const measurements=[];
async function call(args,actor=0,errorCode){
 const started=performance.now();let stdout;
 try{({stdout}=await promisify(execFile)(process.execPath,[cli,...args,'--json'],{env:{...process.env,MYMAN_AGENT_SOCKET:ready.socket,MYMAN_AGENT_TOKEN:agents[actor].token},maxBuffer:8*1024*1024}));}catch(error){stdout=error.stdout;if(!stdout)throw error;}
 const value=JSON.parse(stdout);if(errorCode)assert.equal(value.error?.code,errorCode,JSON.stringify(value));else assert.notEqual(value.ok,false,JSON.stringify(value));
 measurements.push({action:args.slice(0,2).join(' '),milliseconds:Math.round(performance.now()-started),expected_error:errorCode??null});return value;
}
const note=await call(['note','create','--title','Synthetic handoff note','--body','Review this synthetic checkout flow.']);
const shot=await call(['capture','import','--path',ready.fixture]);
const context=await call(['workflow','context','--ids',JSON.stringify([note.id,shot.id,ready.meeting_id])]);
assert.equal(context.attachments.length,2);assert.equal(context.host_delivery,'not_sent');
const markdown=await readFile(context.attachments[0].path,'utf8');assert.match(markdown,/Synthetic handoff note/);assert.match(markdown,/meeting-/);assert.match(markdown,/screenshot/);
await call(['workflow','context','--ids',JSON.stringify([note.id])],2,'AGENT_SCOPE_DENIED');
await call(['capture','float','--id',shot.id]);
await call(['workflow','open','--tab','activity']);
await call(['workflow','cancel','--job-id','00000000-0000-0000-0000-000000000000'],0,'NOT_CANCELLABLE');
await call(['share','publish','--id',shot.id,'--expected-revision','1'],0,'INVALID_ARGUMENTS');
const jobs=await call(['jobs']);assert.ok(Array.isArray(jobs.jobs));
const current=await call(['library','read','--id',note.id]);
await call(['library','hide','--id',note.id,'--expected-revision',String(current.revision??current.item?.revision)]);
await call(['workflow','context','--ids',JSON.stringify([note.id])],0,'NOT_FOUND');
const report={passed:true,commands:measurements.length,mixed_content_handoff:true,scope_isolation:true,recovery_receipts:true,measurements,host_dispatch:'tracked separately',competitors:{cleanshot_x:'not measured',granola:'not measured',wispr_flow:'not measured'}};
await writeFile(root+'/workflow-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify({passed:true,commands:measurements.length}));
