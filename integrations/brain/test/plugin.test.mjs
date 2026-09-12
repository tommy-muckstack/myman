import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
const readJSON=async path=>JSON.parse(await readFile(new URL(path,import.meta.url),'utf8'));
test('marketplace manifests match official pinned schemas and bundled MCP is portable',async()=>{
 const ajv=new Ajv2020({strict:false,validateFormats:false});
 const plugin=await readJSON('./schemas/plugin.schema.json'), mcp=await readJSON('./schemas/mcp.schema.json');
 for(const path of ['../../../plugin.json','../../grok-bot/plugin.json']){
   const manifest=await readJSON(path);assert.ok(ajv.validate(plugin,manifest),JSON.stringify(ajv.errors));assert.equal(manifest.version,'0.6.0');
 }
 const config=await readJSON('../../../mcp.json');assert.ok(ajv.validate(mcp,config),JSON.stringify(ajv.errors));
 assert.equal(config.mcpServers['myman-brain'].args[0],'${PLUGIN_ROOT}/src/Resources/BrainCompanion/server.mjs');
 await access(new URL('../../../src/Resources/BrainCompanion/server.mjs',import.meta.url));
 await assert.rejects(access(new URL('../../grok-bot/mcp.json',import.meta.url)));
 const skill=await readFile(new URL('../../grok-bot/skills/myman/SKILL.md',import.meta.url),'utf8');assert.match(skill,/local-computer/);assert.match(skill,/offline/);
});
