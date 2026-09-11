import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

test('official MCP client initializes, discovers tools, reads fixtures, and receives safe errors', { timeout: 15000 }, async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'myman-mcp-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, 'meetings'));
  const content = '# Weekly planning\nAlex will send the proposal.\n';
  await writeFile(path.join(root, 'meetings/weekly.md'), content);
  const client = new Client({ name: 'myman-test-client', version: '1.0.0' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('../server.mjs', import.meta.url))],
    env: { ...process.env, MYMAN_BRAIN_ROOT: root }, stderr: 'pipe',
  });
  t.after(() => client.close());
  await client.connect(transport);
  const { tools } = await client.listTools();
  assert.equal(tools.length, 5);
  assert.ok(tools.every(tool => tool.annotations.readOnlyHint && !tool.annotations.destructiveHint));
  const search = await client.callTool({ name: 'myman_brain_search', arguments: { query: 'proposal' } });
  assert.ok(!search.isError, JSON.stringify(search));
  const found = JSON.parse(search.content[0].text).results[0];
  assert.equal(found.path, 'meetings/weekly.md');
  const read = await client.callTool({ name: 'myman_brain_read', arguments: { path: found.path } });
  assert.equal(JSON.parse(read.content[0].text).content, content);
  const denied = await client.callTool({ name: 'myman_brain_read', arguments: { path: '../../secrets.env' } });
  assert.equal(denied.isError, true);
  assert.equal(JSON.parse(denied.content[0].text).error.code, 'INVALID_PATH');
  const missing = await client.callTool({ name: 'myman_brain_tasks', arguments: {} });
  assert.equal(missing.isError, true);
  assert.equal(await readFile(path.join(root, 'meetings/weekly.md'), 'utf8'), content);
});
