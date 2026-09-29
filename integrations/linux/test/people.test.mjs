import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,realpath,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport} from '@modelcontextprotocol/client/stdio';
import {peopleExport} from '../people.mjs';
import {defaultGrants,capGrants} from '../policy.mjs';

const exec=promisify(execFile),here=path.dirname(fileURLToPath(import.meta.url));
const people='# People\n\nPeople from recorded meetings, most-met first.\n\n- **Jilles Smith** — jilles@example.test — 2 meetings, last Sep 29, 2026\n- **Developer** — 1 meeting, last Sep 28, 2026\n- **Sam Jones** — sam.j@example.test — 4 meetings, last Sep 29, 2026\n- **Sam Patel** — sam.p@example.test — 3 meetings, last Sep 29, 2026\n';
test('people.md parser accepts only existing exported identities and never derives an email',()=>{
 assert.deepEqual(peopleExport(people).slice(0,2),[{name:'Jilles Smith',email:'jilles@example.test',source:'people'},{name:'Developer',email:undefined,source:'people'}]);
 assert.deepEqual(peopleExport('# People\n\nPeople from recorded meetings, most-met first.\n'),[]);
 for(const text of ['no export', '# People\n- **Bad** — name@example.test\n'])assert.throws(()=>peopleExport(text),{code:'PEOPLE_SOURCE_INVALID'});
});
test('people grants start off and remain capped by the root policy',()=>{
 assert.equal(defaultGrants.people_read,false);
 assert.equal(capGrants({...defaultGrants,enabled:true,people_read:true},{...defaultGrants,enabled:true}).people_read,false);
});
async function fixture(t){
 const root=await mkdtemp(path.join(await realpath(tmpdir()),'myman-people-test-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const config=path.join(root,'config','myman'),brain=path.join(root,'Brain');
 await mkdir(config,{recursive:true,mode:0o700});await mkdir(brain,{mode:0o700});
 const env={...process.env,XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(root,'state'),MYMAN_BRAIN_ROOT:brain};delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
 const file=path.join(brain,'people.md'),grants=values=>writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,...values}}),{mode:0o600});
 await grants({});return {root,config,brain,file,grants,env};
}
async function cli(entry,args,env){
 let result;try{result=await exec(process.execPath,[path.resolve(here,'..',entry),...args,'--json'],{env,timeout:15000});}catch(e){result=e;}
 assert.equal(result.stderr,'');return JSON.parse(result.stdout);
}
const command=['people','resolve','--names','["jilles","Developer","Sam","Hidden"]','--limit','1'];
for(const entry of ['cli.mjs','bundle/cli.mjs'])test(`${entry}: grant, saved-source privacy, ambiguity and named scopes`,async t=>{
 const f=await fixture(t);
 assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({library:true});assert.equal((await cli(entry,command,f.env)).error.code,'AGENT_DISABLED');
 await f.grants({people_read:true});assert.equal((await cli(entry,command,f.env)).error.code,'unsupported_on_platform');
 await writeFile(f.file,people,{mode:0o600});await mkdir(path.join(f.brain,'meetings'));
 await writeFile(path.join(f.brain,'meetings','old.md'),'---\nparticipants:\n  - Hidden Person <hidden@example.test>\n---\n# Private meeting\n');
 const result=await cli(entry,command,f.env);assert.equal(result.ok,true);
 assert.deepEqual(result.results.map(r=>r.status),['resolved','missing_email','ambiguous','not_found']);
 assert.equal(result.results[2].total,2);assert.equal(result.results[2].truncated,true);
 assert.equal(result.contacts_accessed,false);assert.equal(result.side_effects,false);assert.equal(result.source,'people_export');
 assert.equal(await readFile(f.file,'utf8'),people);assert.doesNotMatch(JSON.stringify(result),/hidden@example|Private meeting|meetCount|lastMet/i);
 const caps=await cli(entry,['actions','people.resolve'],f.env);assert.deepEqual(caps.permissions,['people_read']);assert.equal(caps.readOnly,true);
 assert.equal((await cli(entry,[...command,'--path',f.file],f.env)).error.code,'INVALID_ARGUMENTS');
 const token='synthetic-people-reader',registry={machine_id:'people-test',required:true,agents:[{id:'reader',name:'Reader',scopes:['library'],digest:createHash('sha256').update(token).digest('hex')}]};
 const identity=path.join(f.config,'identities.json'),namedEnv={...f.env,MYMAN_AGENT_TOKEN:token};await writeFile(identity,JSON.stringify(registry),{mode:0o600});
 assert.equal((await cli(entry,command,namedEnv)).error.code,'AGENT_SCOPE_DENIED');
 registry.agents[0].scopes.push('people_read');await writeFile(identity,JSON.stringify(registry));assert.equal((await cli(entry,command,namedEnv)).ok,true);
 registry.agents[0].revoked=true;await writeFile(identity,JSON.stringify(registry));assert.equal((await cli(entry,command,namedEnv)).error.code,'INVALID_CREDENTIAL');await rm(identity);
 await writeFile(f.file,'# People\n- **Broken**');assert.equal((await cli(entry,command,f.env)).error.code,'PEOPLE_SOURCE_INVALID');
 await rm(f.file);const target=path.join(f.root,'outside.md');await writeFile(target,people);await symlink(target,f.file);
 assert.equal((await cli(entry,command,f.env)).error.code,'UNSAFE_PATH');
});
for(const entry of ['app-server.mjs','bundle/app-server.mjs'])test(`${entry}: MCP schema and live grant revocation`,async t=>{
 const f=await fixture(t);await writeFile(f.file,people,{mode:0o600});const client=new Client({name:'people-fixture',version:'1'});
 await client.connect(new StdioClientTransport({command:process.execPath,args:[path.resolve(here,'..',entry)],env:f.env,stderr:'pipe'}));t.after(()=>client.close());
 const tool=(await client.listTools()).tools.find(t=>t.name==='myman_app_people_resolve');assert.equal(tool.annotations.readOnlyHint,true);assert.match(tool.description,/people_read/);
 const call=()=>client.callTool({name:tool.name,arguments:{names:['Jilles']}});
 assert.equal((await call()).structuredContent.error.code,'AGENT_DISABLED');await f.grants({people_read:true});
 assert.equal((await call()).structuredContent.results[0].status,'resolved');await f.grants({people_read:false});
 assert.equal((await call()).structuredContent.error.code,'AGENT_DISABLED');
});
