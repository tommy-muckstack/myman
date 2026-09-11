import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, realpath, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { Brain } from '../brain.mjs';
import { execute } from '../tools.mjs';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA5sAAAAASUVORK5CYII=', 'base64');
async function fixture(t) {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), 'myman-visual-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  for (const directory of ['meetings', 'screenshots', 'assets/capture-thumbnails', 'tools']) await mkdir(path.join(root, directory), { recursive: true });
  const put = (name, text) => writeFile(path.join(root, name), text);
  await put('meetings/demo.md', '---\nid: demo-id\nstarted: 2026-09-11T13:00:00Z\nended: 2026-09-11T14:00:00Z\nparticipants:\n  - Jared Lane\n---\n# Jared product demo\nA product review.');
  const exports = [{ path: 'meetings/demo.md', kind: 'meetings', title: 'Jared product demo', timestamp: '2026-09-11T13:00:00Z' }];
  for (const [id, time, tag, app, sequence] of [['screen', '13:01', 'web-app', 'Google Chrome', 'a'], ['duplicate', '13:02', 'web-app', 'Google Chrome', 'a'], ['deck', '13:03', 'slide-deck', 'Google Chrome', 'b'], ['unknown', '13:04', 'document', null, null], ['outside', '14:00', 'web-app', 'Google Chrome', 'c']]) {
    await put(`screenshots/${id}.md`, `---\nid: ${id}\ncaptured: 2026-09-11T${time}:00Z\nocr_text: |-\n${'  Source OCR\n'.repeat(130)}  Registration price $49\n---\n# Job Board\nWeb app showing repair estimates.`);
    await put(`assets/capture-thumbnails/${id}.png`, png);
    exports.push({ path: `screenshots/${id}.md`, kind: 'screenshots', title: id === 'deck' ? 'Board slides' : 'Job Board', timestamp: `2026-09-11T${time}:00Z`, app, tags: [{ name: tag, confidence: 0.8 }], sequence_id: sequence, thumbnail_path: path.join(root, `assets/capture-thumbnails/${id}.png`), contains_confidential: id === 'deck' ? 'likely' : 'not_detected', contains_pii: 'not_detected', captured_local: `2026-09-11T09:${time.slice(3)}:00-04:00`, timezone: 'America/New_York', meetings: time < '14:00' ? [{ id: 'demo-id', path: 'meetings/demo.md', association: 'recorded_during' }] : [] });
  }
  const catalog = { version: 1, exports };
  await put('catalog.json', JSON.stringify(catalog));
  return { root, put, catalog, brain: new Brain(root) };
}

test('one request resolves meeting descriptions and combines app/tag/sequence filters', async t => {
  const { brain } = await fixture(t);
  const all = await execute(brain, 'screenshots', { meeting: 'Jared demo' });
  assert.equal(all.needs_disambiguation, false); assert.equal(all.total, 4);
  const filtered = await execute(brain, 'screenshots', { meeting: 'demo-id', app: 'Chrome', exclude_tags: ['slide-deck'], unique: true });
  assert.equal(filtered.total, 1);
  assert.equal(filtered.results[0].sequence_id, 'a');
  assert.equal(filtered.results[0].timezone, 'America/New_York');
  assert.equal(filtered.items_without_app_metadata, 1); assert.equal(filtered.partial, true);
  const searched = await execute(brain, 'screenshots', { meeting: 'meetings/demo.md', query: '$49', tags: ['web-app'] });
  assert.equal(searched.total, 2);
  assert.ok(searched.results.every(r => r.timestamp && r.meetings[0].id === 'demo-id'));
  const first = await execute(brain, 'screenshots', { meeting: 'Jared demo', limit: 2 });
  const second = await execute(brain, 'screenshots', { meeting: 'Jared demo', limit: 2, offset: first.next_offset });
  assert.equal(new Set([...first.results, ...second.results].map(r => r.path)).size, 4);
});

test('ambiguous calls are returned as candidates and date bounds stay explicit', async t => {
  const { brain, put, catalog } = await fixture(t);
  await put('meetings/other.md', '---\nid: second\nstarted: 2026-09-10T13:00:00Z\nended: 2026-09-10T14:00:00Z\n---\n# Jared product demo\n');
  catalog.exports.push({ path: 'meetings/other.md', kind: 'meetings', title: 'Jared product demo', timestamp: '2026-09-10T13:00:00Z' });
  await put('catalog.json', JSON.stringify(catalog));
  const result = await execute(brain, 'screenshots', { meeting: 'Jared demo' });
  assert.equal(result.needs_disambiguation, true); assert.equal(result.matching_meetings, 2); assert.deepEqual(result.results, []);
  assert.equal((await execute(brain, 'screenshots', { after: '2026-09-11T09:00:00-04:00', before: '2026-09-11T10:00:00-04:00' })).total, 4);
  await assert.rejects(execute(brain, 'screenshots', { meeting: 'demo-id', after: '2026-09-11T13:00:00Z' }), { code: 'INVALID_ARGUMENTS' });
});

test('thumbnail reads use only current owned catalog references and never silently open originals', async t => {
  const { brain, root, put, catalog } = await fixture(t);
  const result = await execute(brain, 'image', { path: 'screenshots/screen.md', size: 'thumbnail' });
  assert.equal(result.width, 1); assert.equal(result.size, 'thumbnail'); assert.deepEqual(Buffer.from(result.image.data, 'base64'), png);
  await assert.rejects(execute(brain, 'image', { path: 'screenshots/screen.md' }), { code: 'IMAGE_UNAVAILABLE' });
  catalog.exports[1].thumbnail_path = path.join(root, 'outside.png');
  await put('outside.png', png); await put('catalog.json', JSON.stringify(catalog));
  await assert.rejects(execute(brain, 'image', { path: 'screenshots/screen.md', size: 'thumbnail' }), { code: 'THUMBNAIL_UNAVAILABLE' });
  catalog.exports[1].thumbnail_path = path.join(root, 'assets/capture-thumbnails/link.png');
  await symlink(path.join(root, 'outside.png'), catalog.exports[1].thumbnail_path); await put('catalog.json', JSON.stringify(catalog));
  await assert.rejects(execute(brain, 'image', { path: 'screenshots/screen.md', size: 'thumbnail' }), { code: 'UNSAFE_PATH' });
  catalog.exports.splice(1, 1); await put('catalog.json', JSON.stringify(catalog));
  await assert.rejects(execute(brain, 'image', { path: 'screenshots/screen.md', size: 'thumbnail' }), { code: 'DOCUMENT_NOT_FOUND' });
});

test('bundled CLI and MCP run from an isolated Brain with no node_modules', { timeout: 15000 }, async t => {
  const { root } = await fixture(t);
  const resources = fileURLToPath(new URL('../../../src/Resources/BrainCompanion/', import.meta.url));
  for (const name of ['cli.mjs', 'server.mjs']) await copyFile(path.join(resources, name), path.join(root, 'tools', name));
  const run = spawnSync(process.execPath, ['tools/cli.mjs', '--root', root, 'screenshots', '--meeting', 'Jared demo', '--exclude-tag', 'slide-deck', '--unique'], { cwd: root, encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr); assert.equal(JSON.parse(run.stdout).total, 2);
  const meetings = spawnSync(process.execPath, ['tools/cli.mjs', '--root', root, 'meetings', '--participant', 'Jared', '--after', '2026-09-01T00:00:00Z'], { cwd: root, encoding: 'utf8' });
  assert.equal(meetings.status, 0, meetings.stderr); assert.equal(JSON.parse(meetings.stdout).total, 1);
  const recordings = spawnSync(process.execPath, ['tools/cli.mjs', '--root', root, 'recordings', '--query', 'pricing'], { cwd: root, encoding: 'utf8' });
  assert.equal(recordings.status, 0, recordings.stderr); assert.equal(JSON.parse(recordings.stdout).total, 0);
  const client = new Client({ name: 'bundled-test', version: '1.0.0' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, 'tools/server.mjs')], env: { ...process.env, MYMAN_BRAIN_ROOT: root }, stderr: 'pipe' });
  t.after(() => client.close()); await client.connect(transport);
  const shots = await client.callTool({ name: 'myman_brain_screenshots', arguments: { meeting: 'Jared demo', tags: ['web-app'], unique: true } });
  assert.equal(shots.structuredContent.total, 1);
  const image = await client.callTool({ name: 'myman_brain_image', arguments: { path: shots.structuredContent.results[0].path, size: 'thumbnail' } });
  assert.equal(image.content[1].type, 'image');
  assert.deepEqual(Buffer.from(image.content[1].data, 'base64'), png);
});
