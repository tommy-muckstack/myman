import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {Client} from '@modelcontextprotocol/client';
import {StdioClientTransport} from '@modelcontextprotocol/client/stdio';
const env={...process.env};delete env.MYMAN_AGENT_TOKEN;delete env.MYMAN_MACHINE_ID;
for(const entry of ['cli.mjs','bundle/cli.mjs'])test(`${entry}: booking stays unsupported on Linux`,()=>{
 for(const command of [['calendar','book','--title','Coffee','--start','2030-10-01T10:00:00Z','--time-zone','UTC','--duration-minutes','30'],['calendar','booking','--booking-id','fixture']]) {
  let stdout;try{stdout=execFileSync(process.execPath,[new URL('../'+entry,import.meta.url).pathname,...command,'--json'],{env,encoding:'utf8',stdio:['ignore','pipe','pipe']});}catch(e){stdout=e.stdout;}
  assert.equal(JSON.parse(stdout).error.code,'unsupported_on_platform');
 }
});
for(const entry of ['app-server.mjs','bundle/app-server.mjs'])test(`${entry}: MCP exposes preview-only contract and unsupported execution`,async t=>{
 const client=new Client({name:'booking-fixture',version:'1'});
 await client.connect(new StdioClientTransport({command:process.execPath,args:[new URL('../'+entry,import.meta.url).pathname],env,stderr:'pipe'}));t.after(()=>client.close());
 const tools=(await client.listTools()).tools,book=tools.find(x=>x.name==='myman_app_calendar_book');assert.match(book.description,/human/);assert.equal(book.inputSchema.additionalProperties,false);assert.equal(book.inputSchema.properties.confirm,undefined);
 const result=await client.callTool({name:book.name,arguments:{title:'Coffee',start:'2030-10-01T10:00:00Z',time_zone:'UTC',duration_minutes:30}});assert.equal(result.structuredContent.error.code,'unsupported_on_platform');
});
