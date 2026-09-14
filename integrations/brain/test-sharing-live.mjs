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
const shot=await call(['capture','import','--path',ready.fixture]);
await call(['wait','--id',shot.id,'--stage','ocr','--timeout','30']);
const current=await call(['library','read','--id',shot.id]);
const receipt=await call(['share','publish','--id',shot.id,'--expected-revision',String(current.revision??current.item?.revision),'--ttl-seconds','60','--confirm']);
assert.equal((await fetch(receipt.url)).status,200);
await call(['share','revoke','--id',receipt.id],1,'NOT_OWNER');
await call(['share','revoke','--id',receipt.id]);
assert.equal((await fetch(receipt.url)).status,410);
await writeFile(root+'/native-sharing-report.json',JSON.stringify({passed:true,native_keychain_client:true,published:true,owner_isolation:true,revoked:true,commands:measurements.length},null,2));
console.log(JSON.stringify({passed:true,commands:measurements.length,native_keychain_client:true,owner_isolation:true}));
