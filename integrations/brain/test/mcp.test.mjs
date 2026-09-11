import test from 'node:test';
import assert from 'node:assert/strict';
import { realpath, mkdtemp, mkdir, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

test('official MCP client initializes, discovers tools, reads fixtures, and receives safe errors', { timeout: 15000 }, async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'myman-mcp-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, 'meetings'));
  const content = '---\nstarted: 2026-09-11T13:00:00Z\nended: 2026-09-11T14:00:00Z\nparticipants:\n  - Alex Lane <alex@example.com>\n---\n# Weekly planning\nAlex will send the proposal.\n';
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
  assert.equal(tools.length, 9);
  assert.ok(tools.every(tool => tool.annotations.readOnlyHint && !tool.annotations.destructiveHint));
  const search = await client.callTool({ name: 'myman_brain_search', arguments: { query: 'proposal' } });
  assert.ok(!search.isError, JSON.stringify(search));
  const found = JSON.parse(search.content[0].text).results[0];
  assert.equal(found.path, 'meetings/weekly.md');
  const read = await client.callTool({ name: 'myman_brain_read', arguments: { path: found.path } });
  assert.equal(JSON.parse(read.content[0].text).content, content);
  await mkdir(path.join(root, 'screenshots'));
  await writeFile(path.join(root, 'screenshots/during.md'), '---\ncaptured: 2026-09-11T13:59:00Z\nfile: /Users/example/Captures/design.png\n---\n# Screenshot\n');
  const meetings = await client.callTool({ name: 'myman_brain_meetings', arguments: { participants: ['Alex'] } });
  assert.equal(meetings.structuredContent.total, 1);
  const shots = await client.callTool({ name: 'myman_brain_meeting_screenshots', arguments: { meeting_path: meetings.structuredContent.results[0].path } });
  assert.equal(shots.structuredContent.total, 1);
  assert.equal(shots.structuredContent.results[0].seconds_into_meeting, 3540);
  assert.equal(shots.structuredContent.results[0].image_path, '/Users/example/Captures/design.png');
  const denied = await client.callTool({ name: 'myman_brain_read', arguments: { path: '../../secrets.env' } });
  assert.equal(denied.isError, true);
  assert.equal(JSON.parse(denied.content[0].text).error.code, 'INVALID_PATH');
  const missing = await client.callTool({ name: 'myman_brain_tasks', arguments: {} });
  assert.equal(missing.isError, true);
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA5sAAAAASUVORK5CYII=', 'base64');
  const imagePath = path.join(await realpath(root), 'original.png');
  await writeFile(imagePath, png);
  await writeFile(path.join(root, 'catalog.json'), JSON.stringify({ version: 1, exports: [
    { path: 'meetings/weekly.md', kind: 'meetings', title: 'Weekly planning', timestamp: '2026-09-11T13:00:00Z' },
    { path: 'screenshots/during.md', kind: 'screenshots', title: 'Design', timestamp: '2026-09-11T13:59:00Z', image_path: imagePath },
  ] }));
  const collected = await client.callTool({ name: 'myman_brain_collect', arguments: { kinds: ['screenshots'], during: 'meetings/weekly.md' } });
  assert.equal(collected.structuredContent.total, 1);
  const image = await client.callTool({ name: 'myman_brain_image', arguments: { path: collected.structuredContent.results[0].path } });
  assert.ok(!image.isError, JSON.stringify(image));
  assert.equal(image.content[1].type, 'image');
  assert.equal(image.content[1].mimeType, 'image/png');
  assert.deepEqual(Buffer.from(image.content[1].data, 'base64'), png);
  assert.equal(await readFile(path.join(root, 'meetings/weekly.md'), 'utf8'), content);
});
