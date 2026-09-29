import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,realpath,chmod,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport} from '@modelcontextprotocol/client/stdio';
import {parseICS} from '../calendar-ics.mjs';
import {calendarRange,instant} from '../calendar-range.mjs';
import {defaultGrants,capGrants} from '../policy.mjs';

const exec=promisify(execFile), here=path.dirname(fileURLToPath(import.meta.url));
const after='2026-09-29T00:00:00Z',before='2026-10-02T00:00:00Z',range=calendarRange({after,before});
const cal=(...events)=>['BEGIN:VCALENDAR','VERSION:2.0',...events,'END:VCALENDAR'].join('\r\n');
const event=(uid,...lines)=>['BEGIN:VEVENT',`UID:${uid}`,...lines,'END:VEVENT'].join('\r\n');
const parse=(text,r=range,zone='America/New_York',owner)=>parseICS(text,r,zone,owner);
const busy=(start,end)=>({start,end});
const sample=cal(event('synthetic','DTSTART:20260929T100000Z','DTEND:20260929T110000Z','SUMMARY:Private title','ATTENDEE:mailto:private@example.test'));

test('explicit bounds validate dates, offsets, ordering and maximum range',()=>{
 assert.equal(instant('2026-09-29T10:00:00-04:00'),instant('2026-09-29T14:00:00.000Z'));
 for(const text of ['2026-02-30T00:00:00Z','2026-09-29','2026-09-29T00:00:00','2026-09-29T24:00:00Z','2026-09-29T00:60:00Z','2026-09-29T00:00:00+00:99']) assert.ok(Number.isNaN(instant(text)));
 for(const args of [{after,before:after},{after:before,before:after},{after,before:'2026-11-02T00:00:00Z'}])assert.throws(()=>calendarRange(args),{code:'INVALID_ARGUMENTS'});
});
test('busy intervals merge and clip without metadata or false boundary conflicts',()=>{
 const result=parse(cal(event('a','DTSTART:20260928T230000Z','DTEND:20260929T103000Z'),event('b','DTSTART:20260929T100000Z','DTEND:20260929T110000Z'),event('c','DTSTART:20260929T110000Z','DTEND:20260929T120000Z'),event('d','DTSTART:20261002T000000Z','DTEND:20261002T010000Z')));
 assert.deepEqual(result.busy,[busy('2026-09-29T00:00:00.000Z','2026-09-29T12:00:00.000Z')]);
 assert.equal(result.teammate_availability,'unknown');assert.equal(result.side_effects,false);assert.equal(result.complete,true);
 const privateResult=parse(sample);assert.doesNotMatch(JSON.stringify(privateResult),/Private|example|synthetic|attendee|title|uid/i);
 assert.deepEqual(parse(cal()).busy,[]);
});
test('canceled, transparent and owner-declined events are free; tentative is busy',()=>{
 const events=[event('a','STATUS:CANCELLED'),event('b','DTSTART:20260929T100000Z','DTEND:20260929T110000Z','TRANSP:TRANSPARENT'),event('c','DTSTART:20260929T120000Z','DTEND:20260929T130000Z','ATTENDEE;PARTSTAT=DECLINED:mailto:owner@example.test'),event('d','DTSTART:20260929T140000Z','DTEND:20260929T150000Z','STATUS:TENTATIVE')];
 assert.deepEqual(parse(cal(...events),range,'America/New_York','owner@example.test').busy,[busy('2026-09-29T14:00:00.000Z','2026-09-29T15:00:00.000Z')]);
 assert.equal(parse(cal(...events)).busy.length,2,'without owner identity, RSVP is conservatively busy');
});
test('all-day dates have exclusive ends and follow the configured zone over DST',()=>{
 const r=calendarRange({after:'2026-11-01T00:00:00-04:00',before:'2026-11-02T00:00:00-05:00'});
 assert.deepEqual(parse(cal(event('all','DTSTART;VALUE=DATE:20261101')),r).busy,[busy('2026-11-01T04:00:00.000Z','2026-11-02T05:00:00.000Z')]);
 const result=parse(cal(event('days','DTSTART;VALUE=DATE:20260929','DTEND;VALUE=DATE:20261001')));
 assert.deepEqual(result.busy,[busy('2026-09-29T04:00:00.000Z','2026-10-01T04:00:00.000Z')]);
});
test('IANA and floating times follow the owner zone and recurring DST changes',()=>{
 const r=calendarRange({after:'2026-10-31T00:00:00Z',before:'2026-11-03T00:00:00Z'});
 const result=parse(cal(event('a','DTSTART;TZID=America/New_York:20261031T100000','DTEND;TZID=America/New_York:20261031T110000','RRULE:FREQ=DAILY;COUNT=3')),r);
 assert.deepEqual(result.busy.map(b=>b.start),['2026-10-31T14:00:00.000Z','2026-11-01T15:00:00.000Z','2026-11-02T15:00:00.000Z']);
 assert.deepEqual(parse(cal(event('b','DTSTART:20260929T100000','DURATION:PT45M'))).busy,[busy('2026-09-29T14:00:00.000Z','2026-09-29T14:45:00.000Z')]);
});
test('embedded VTIMEZONE definitions take precedence over an IANA zone name',()=>{
 const timezone=['BEGIN:VTIMEZONE','TZID:America/New_York','BEGIN:STANDARD','DTSTART:19700101T000000','TZOFFSETFROM:+0200','TZOFFSETTO:+0200','END:STANDARD','END:VTIMEZONE'].join('\r\n');
 const result=parse(cal(timezone,event('a','DTSTART;TZID=America/New_York:20260929T100000','DTEND;TZID=America/New_York:20260929T110000')));
 assert.deepEqual(result.busy,[busy('2026-09-29T08:00:00.000Z','2026-09-29T09:00:00.000Z')]);
});
test('EXDATE, RDATE and moved/canceled exceptions use only their own UID',()=>{
 const result=parse(cal(event('series','DTSTART:20260929T100000Z','DTEND:20260929T110000Z','RRULE:FREQ=DAILY;COUNT=4','EXDATE:20261001T100000Z','RDATE:20260929T150000Z'),event('series','RECURRENCE-ID:20260930T100000Z','DTSTART:20260930T140000Z','DTEND:20260930T150000Z'),event('series','RECURRENCE-ID:20261002T100000Z','STATUS:CANCELLED'),event('other','DTSTART:20260930T100000Z','DTEND:20260930T110000Z')));
 assert.deepEqual(result.busy,[busy('2026-09-29T10:00:00.000Z','2026-09-29T11:00:00.000Z'),busy('2026-09-29T15:00:00.000Z','2026-09-29T16:00:00.000Z'),busy('2026-09-30T10:00:00.000Z','2026-09-30T11:00:00.000Z'),busy('2026-09-30T14:00:00.000Z','2026-09-30T15:00:00.000Z')]);
});
test('an exception moved into the query from a later recurrence is included',()=>{
 const result=parse(cal(event('a','DTSTART:20261010T100000Z','DTEND:20261010T110000Z','RRULE:FREQ=DAILY;COUNT=3'),event('a','RECURRENCE-ID:20261011T100000Z','DTSTART:20260929T120000Z','DTEND:20260929T130000Z')));
 assert.deepEqual(result.busy,[busy('2026-09-29T12:00:00.000Z','2026-09-29T13:00:00.000Z')]);
});
test('canceled exceptions need no replacement dates and remove a slot inside the query',()=>{
 const result=parse(cal(event('a','DTSTART:20260929T100000Z','DURATION:PT1H','RRULE:FREQ=DAILY;COUNT=2'),event('a','RECURRENCE-ID:20260929T100000Z','STATUS:CANCELLED')));
 assert.deepEqual(result.busy,[busy('2026-09-30T10:00:00.000Z','2026-09-30T11:00:00.000Z')]);
});
test('VFREEBUSY periods and durations ignore FBTYPE=FREE',()=>{
 const text=cal(['BEGIN:VFREEBUSY','FREEBUSY:20260929T100000Z/20260929T110000Z,20260929T120000Z/PT30M','FREEBUSY;FBTYPE=FREE:20260929T140000Z/PT1H','END:VFREEBUSY'].join('\r\n'));
 assert.deepEqual(parse(text).busy,[busy('2026-09-29T10:00:00.000Z','2026-09-29T11:00:00.000Z'),busy('2026-09-29T12:00:00.000Z','2026-09-29T12:30:00.000Z')]);
});
test('malformed and unsupported data errors never become an empty successful calendar',()=>{
 for(const text of ['junk',cal(event('a','DTSTART:20260230T100000Z','DTEND:20260230T110000Z')),cal(event('a','DTSTART:20260929T120000Z','DTEND:20260929T110000Z'))])assert.throws(()=>parse(text));
 for(const text of [cal(event('a','DTSTART;TZID=Mars/Olympus:20260929T100000','DURATION:PT1H')),cal(event('a','DTSTART:20260929T100000Z','RRULE:FREQ=DAILY'),event('a','RECURRENCE-ID;RANGE=THISANDFUTURE:20260930T100000Z','DTSTART:20260930T110000Z')),cal(event('a','DTSTART;TZID=America/New_York:20260929T100000','DURATION:PT1H','EXDATE:20260930T140000Z'))])assert.throws(()=>parse(text),{code:'ICS_UNSUPPORTED'});
});
test('nonexistent floating DST times fail; repeated times cover both possible instants',()=>{
 const spring=calendarRange({after:'2026-03-08T00:00:00Z',before:'2026-03-09T00:00:00Z'});
 assert.throws(()=>parse(cal(event('a','DTSTART:20260308T023000','DURATION:PT15M')),spring),{code:'ICS_UNSUPPORTED'});
 const fall=calendarRange({after:'2026-11-01T00:00:00Z',before:'2026-11-02T00:00:00Z'});
 assert.deepEqual(parse(cal(event('a','DTSTART:20261101T013000','DURATION:PT15M')),fall).busy,[busy('2026-11-01T05:30:00.000Z','2026-11-01T06:45:00.000Z')]);
});
test('recurrence bounds fail closed instead of normalizing malformed or ambiguous rules',()=>{
 for(const rule of ['FREQ=DAILY;INTERVAL=0','FREQ=DAILY;COUNT=0','FREQ=DAILY;COUNT=2;UNTIL=20261001T100000Z','FREQ=DAILY;UNTIL=20260230T100000Z','FREQ=MONTHLY;BYMONTHDAY=0'])assert.throws(()=>parse(cal(event('a','DTSTART:20260929T100000Z','DURATION:PT1H',`RRULE:${rule}`))));
 for(const rule of ['FREQ=DAILY;RSCALE=HEBREW','FREQ=DAILY;SKIP=FORWARD'])assert.throws(()=>parse(cal(event('a','DTSTART:20260929T100000Z',`RRULE:${rule}`))),{code:'ICS_UNSUPPORTED'});
 assert.throws(()=>parse(cal(event('a','DTSTART;TZID=Asia/Tokyo:20260929T100000','DURATION:PT1H','RRULE:FREQ=DAILY;UNTIL=20260930T010000Z'))),{code:'ICS_UNSUPPORTED'});
 assert.deepEqual(parse(cal(event('a','DTSTART:20260929T100000Z','DURATION:PT1H','RRULE:FREQ=DAILY;UNTIL=20260930T100000Z'))).busy.map(b=>b.start),['2026-09-29T10:00:00.000Z','2026-09-30T10:00:00.000Z']);
 assert.throws(()=>parse(cal(event('a','DTSTART:20260929T000000Z','DURATION:PT1S','RRULE:FREQ=SECONDLY;COUNT=20001'))),{code:'CALENDAR_LIMIT_EXCEEDED'});
 assert.throws(()=>parse(cal('BEGIN:VFREEBUSY\r\nFREEBUSY:20260230T100000Z/PT1H\r\nEND:VFREEBUSY')),{code:'INVALID_ICS'});
});
test('calendar read grants start off and an administrator ceiling can only narrow them',()=>{
 assert.equal(defaultGrants.calendar_read,false);
 assert.equal(capGrants({...defaultGrants,enabled:true,calendar_read:true},{...defaultGrants,enabled:true}).calendar_read,false);
});

async function fixture(t) {
 const root=await mkdtemp(path.join(await realpath(tmpdir()),'myman-calendar-test-'));
 t.after(()=>rm(root,{recursive:true,force:true}));
 const config=path.join(root,'config','myman');await mkdir(config,{recursive:true,mode:0o700});
 const env={...process.env,XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(root,'state'),MYMAN_BRAIN_ROOT:path.join(root,'Brain')};delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
 const file=path.join(root,'calendar.ics');await writeFile(file,sample,{mode:0o600});
 const grants=values=>writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,...values}}),{mode:0o600});
 const configure=()=>writeFile(path.join(config,'calendar.json'),JSON.stringify({version:1,ics_path:file,time_zone:'America/New_York'}),{mode:0o600});
 await grants({});return {root,config,env,file,grants,configure};
}
async function cli(entry,args,env) {
 let result;try {result=await exec(process.execPath,[path.resolve(here,'..',entry),...args,'--json'],{env,timeout:12_000});}catch(e){result=e;}
 assert.equal(result.stderr,'');return JSON.parse(result.stdout);
}
const command=['calendar','free','--after',after,'--before',before];
for(const entry of ['cli.mjs','bundle/cli.mjs'])test(`${entry}: local-only owner configuration, grant checks, worker and JSON result`,async t=>{
 const f=await fixture(t);
 assert.equal((await cli(entry,command,f.env)).error.code,'unsupported_on_platform');
 await f.configure();assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({library:true});assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({calendar_read:true});
 const prior=await readFile(f.file), result=await cli(entry,command,f.env);
 assert.equal(result.ok,true);assert.deepEqual(result.busy,[busy('2026-09-29T10:00:00.000Z','2026-09-29T11:00:00.000Z')]);
 assert.equal(result.complete,true);assert.deepEqual(await readFile(f.file),prior);
 const caps=await cli(entry,['actions','calendar.freebusy'],f.env);assert.equal(caps.supported,true);assert.deepEqual(caps.permissions,['calendar_read']);
 assert.equal((await cli(entry,[...command,'--path',f.file],f.env)).error.code,'INVALID_ARGUMENTS');
 const token='synthetic-calendar-reader', registry={machine_id:'calendar-test',required:true,agents:[{id:'reader',name:'Reader',scopes:['library'],digest:createHash('sha256').update(token).digest('hex')}]};
 const identityFile=path.join(f.config,'identities.json'), namedEnv={...f.env,MYMAN_AGENT_TOKEN:token};
 await writeFile(identityFile,JSON.stringify(registry),{mode:0o600});
 assert.equal((await cli(entry,command,namedEnv)).error.code,'AGENT_SCOPE_DENIED');
 registry.agents[0].scopes.push('calendar_read');await writeFile(identityFile,JSON.stringify(registry));
 assert.equal((await cli(entry,command,namedEnv)).ok,true);
 registry.agents[0].revoked=true;await writeFile(identityFile,JSON.stringify(registry));
 assert.equal((await cli(entry,command,namedEnv)).error.code,'INVALID_CREDENTIAL');await rm(identityFile);
 await chmod(f.file,0o644);assert.equal((await cli(entry,command,f.env)).error.code,'CALENDAR_UNAVAILABLE');await chmod(f.file,0o600);
 await writeFile(f.file,'broken');assert.equal((await cli(entry,command,f.env)).error.code,'INVALID_ICS');
 const target=path.join(f.root,'other.ics');await writeFile(target,sample,{mode:0o600});await rm(f.file);await symlink(target,f.file);
 assert.equal((await cli(entry,command,f.env)).error.code,'CALENDAR_UNAVAILABLE');
 await chmod(path.join(f.config,'calendar.json'),0o644);
 assert.equal((await cli(entry,command,f.env)).error.code,'INVALID_CALENDAR_CONFIG');
});
for(const entry of ['app-server.mjs','bundle/app-server.mjs'])test(`${entry}: MCP advertises the same schema and honors live grant revocation`,async t=>{
 const f=await fixture(t), client=new Client({name:'calendar-fixture',version:'1'});
 await client.connect(new StdioClientTransport({command:process.execPath,args:[path.resolve(here,'..',entry)],env:f.env,stderr:'pipe'}));t.after(()=>client.close());
 const tool=(await client.listTools()).tools.find(x=>x.name==='myman_app_calendar_freebusy');assert.equal(tool.annotations.readOnlyHint,true);assert.match(tool.description,/calendar_read/);
 const call=()=>client.callTool({name:tool.name,arguments:{after,before}});
 assert.equal((await call()).structuredContent.error.code,'unsupported_on_platform');
 await f.configure();assert.equal((await call()).structuredContent.error.code,'AGENT_DISABLED');
 await f.grants({calendar_read:true});assert.equal((await call()).structuredContent.busy.length,1);
 await f.grants({calendar_read:false});assert.equal((await call()).structuredContent.error.code,'AGENT_DISABLED');
});
