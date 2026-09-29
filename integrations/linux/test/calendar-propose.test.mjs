import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,mkdir,writeFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport} from '@modelcontextprotocol/client/stdio';
import {proposalRequest,proposalResult} from '../calendar-propose.mjs';
import {defaultGrants,capGrants} from '../policy.mjs';
const here=path.dirname(fileURLToPath(import.meta.url)), exec=promisify(execFile);
const fixtures=JSON.parse(await readFile(new URL('../../../Tests/MyManTests/Fixtures/calendar-proposal.json',import.meta.url),'utf8'));
for(const f of fixtures)test(f.name,()=>{
 const request=proposalRequest(f.args),result=proposalResult(request,{complete:true,scope:'own_calendar',busy:f.busy},Date.parse(f.now));
 assert.deepEqual(result.slots.map(s=>s.start),f.starts);assert.equal(result.candidate_count,f.count);assert.equal(result.truncated,f.count>request.limit);
 assert.equal(result.preview.complete,!!f.starts.length);assert.equal(result.preview.start,f.starts[0]??null);
 for(const slot of result.slots)assert.equal(Date.parse(slot.end)-Date.parse(slot.start),request.duration*60_000);
 assert.equal(result.side_effects,false);assert.equal(result.booked,false);assert.equal(result.booking_supported,false);
 assert.equal(result.preview.requires_human_book,true);assert.equal(result.preview.send_invitations,false);assert.equal(result.teammate_availability,'unknown');
});
test('invalid inputs and incomplete reads never become successful proposals',()=>{
 const args=fixtures[0].args;
 for(const patch of [{title:'  '},{title:'a\nb'},{title:'x'.repeat(201)},{time_zone:'Mars/Olympus'},{time_zone:'EST'},{duration_minutes:true},{duration_minutes:0},{duration_minutes:481},{duration_minutes:1.5},{limit:21},{guests:['']},{guests:Array(21).fill('A')},{proposed_starts:[]},{proposed_starts:['2026-09-29T10:00:00']}])assert.throws(()=>proposalRequest({...args,...patch}),{code:'INVALID_ARGUMENTS'});
 for(const availability of [{complete:false,scope:'own_calendar',busy:[]},{complete:true,scope:'guests',busy:[]},{complete:true,scope:'own_calendar',busy:[{start:'bad',end:'bad'}]}])assert.throws(()=>proposalResult(proposalRequest(args),availability,0),{code:'INCOMPLETE_AVAILABILITY'});
 assert.deepEqual(proposalRequest({...args,guests:[' Jilles ','Harshil']}).guests,['Jilles','Harshil']);
 assert.equal(defaultGrants.calendar_propose,false);
 assert.equal(capGrants({...defaultGrants,enabled:true,calendar_propose:true},{...defaultGrants,enabled:true}).calendar_propose,false);
});
// Future dates relative to the actual clock: this contract test does not age out.
const day=new Date(Date.now()+7*86400_000).toISOString().slice(0,10),after=day+'T00:00:00Z',before=day+'T23:59:59Z';
const args={title:'Coffee',after,before,time_zone:'UTC',guests:['Jilles','Harshil']};
async function fixture(t){
 const root=await mkdtemp(path.join(await realpath(tmpdir()),'myman-proposal-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const config=path.join(root,'config','myman');await mkdir(config,{recursive:true,mode:0o700});
 const env={...process.env,XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(root,'state'),MYMAN_BRAIN_ROOT:path.join(root,'Brain')};delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
 const file=path.join(root,'own.ics'),date=day.replaceAll('-','');
 await writeFile(file,`BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:synthetic\r\nDTSTART:${date}T090000Z\r\nDTEND:${date}T100000Z\r\nSUMMARY:Private event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`,{mode:0o600});
 const grants=values=>writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,...values}}),{mode:0o600});await grants({});
 const configure=()=>writeFile(path.join(config,'calendar.json'),JSON.stringify({version:1,ics_path:file,time_zone:'UTC'}),{mode:0o600});
 return {root,config,env,file,grants,configure};
}
async function cli(entry,command,env){
 let result;try{result=await exec(process.execPath,[path.resolve(here,'..',entry),...command,'--json'],{env,timeout:12000});}catch(e){result=e;}
 assert.equal(result.stderr,'');return JSON.parse(result.stdout);
}
const command=['calendar','propose','--title',args.title,'--after',after,'--before',before,'--time-zone','UTC','--guests',JSON.stringify(args.guests)];
for(const entry of ['cli.mjs','bundle/cli.mjs'])test(`${entry}: proposal grant, scope, revocation and read-only ICS contract`,async t=>{
 const f=await fixture(t);
 assert.equal((await cli(entry,command,f.env)).error.code,'unsupported_on_platform');
 assert.equal((await cli(entry,['actions','calendar.propose'],f.env)).supported,false);
 await f.configure();assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({calendar_read:true});assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({calendar_propose:true});assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({calendar_read:true,calendar_propose:true});
 const prior=await readFile(f.file), result=await cli(entry,command,f.env);
 assert.equal(result.ok,true);assert.equal(result.slots[0].start,day+'T10:00:00.000Z');assert.equal(result.preview.guest_count,2);
 assert.equal(result.preview.send_invitations,false);assert.equal(result.availability.freshness,'local_snapshot');assert.deepEqual(await readFile(f.file),prior);
 assert.doesNotMatch(JSON.stringify(result),/Private event|synthetic/);
 const caps=await cli(entry,['actions','calendar.propose'],f.env);assert.equal(caps.supported,true);assert.deepEqual(caps.permissions,['calendar_read','calendar_propose']);
 for(const extra of ['book','confirm','busy','now','send-invitations'])assert.equal((await cli(entry,[...command,'--'+extra,'true'],f.env)).error.code,'INVALID_ARGUMENTS');
 const token='synthetic-proposal-reader',registry={machine_id:'proposal-test',required:true,agents:[{id:'reader',name:'Reader',scopes:['calendar_read'],digest:createHash('sha256').update(token).digest('hex')}]};
 const identityFile=path.join(f.config,'identities.json'),named={...f.env,MYMAN_AGENT_TOKEN:token};
 await writeFile(identityFile,JSON.stringify(registry),{mode:0o600});assert.equal((await cli(entry,command,named)).error.code,'AGENT_SCOPE_DENIED');
 registry.agents[0].scopes.push('calendar_propose');await writeFile(identityFile,JSON.stringify(registry));assert.equal((await cli(entry,command,named)).ok,true);
 registry.agents[0].revoked=true;await writeFile(identityFile,JSON.stringify(registry));assert.equal((await cli(entry,command,named)).error.code,'INVALID_CREDENTIAL');await rm(identityFile);
 await writeFile(f.file,'broken');assert.equal((await cli(entry,command,f.env)).error.code,'INVALID_ICS');
 await f.grants({calendar_read:true});assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
});
for(const entry of ['app-server.mjs','bundle/app-server.mjs'])test(`${entry}: MCP previews share live owner grants`,async t=>{
 const f=await fixture(t),client=new Client({name:'proposal-fixture',version:'1'});
 await client.connect(new StdioClientTransport({command:process.execPath,args:[path.resolve(here,'..',entry)],env:f.env,stderr:'pipe'}));t.after(()=>client.close());
 const tool=(await client.listTools()).tools.find(x=>x.name==='myman_app_calendar_propose');assert.equal(tool.annotations.readOnlyHint,true);assert.match(tool.description,/calendar_propose/);
 const call=()=>client.callTool({name:tool.name,arguments:args});
 assert.equal((await call()).structuredContent.error.code,'unsupported_on_platform');await f.configure();
 await f.grants({calendar_read:true});assert.equal((await call()).structuredContent.error.code,'AGENT_DISABLED');
 await f.grants({calendar_read:true,calendar_propose:true});const r=(await call()).structuredContent;
 assert.equal(r.slots[0].start,day+'T10:00:00.000Z');assert.equal(r.booked,false);
 await f.grants({calendar_propose:true});assert.equal((await call()).structuredContent.error.code,'AGENT_DISABLED');
});
