import test from 'node:test';
import assert from 'node:assert/strict';
import { realpath, mkdtemp, mkdir, writeFile, readFile, rm, symlink, link, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { Brain, limits } from '../brain.mjs';
import { execute } from '../tools.mjs';

export async function fixture(t) {
  const base = await mkdtemp(path.join(tmpdir(), 'myman-brain-test-'));
  t.after(() => rm(base, { recursive: true, force: true }));
  const root = path.join(base, 'MyMan Brain');
  await mkdir(root);
  for (const folder of ['meetings', 'notes', 'recordings', 'screenshots']) await mkdir(path.join(root, folder));
  const put = async (relative, text) => writeFile(path.join(root, relative), text);
  await put('meetings/2026-09-01-budget.md', '---\nstarted: 2026-09-01T13:00:00Z\nlow_content: true\n---\n\n# Budget review\n\n**Alex** [0:01]: Ship the launch on Friday.\n');
  await put('notes/2026-09-02-launch.md', '---\ncreated: 2026-09-02T14:00:00Z\n---\n# Launch checklist\nBudget approved.\n');
  await put('screenshots/2026-09-03-launch.md', '# Launch checklist\nBudget approved.\n');
  await put('tasks.md', '# Tasks\n\n- [ ] Send proposal  <!-- meeting, 2026-09-01 -->\n- [ ] Call Alex\n\n## Done\n\n- [x] Book room\n');
  return { base, root, put, brain: new Brain(root) };
}

test('search finds keywords, prioritizes deliberate sources, and cites exact text', async t => {
  const { brain } = await fixture(t);
  const result = await execute(brain, 'search', { query: 'LAUNCH budget' });
  assert.deepEqual(result.results.map(r => r.kind), ['meetings', 'notes', 'screenshots']);
  const meeting = result.results.find(r => r.kind === 'meetings');
  assert.equal(meeting.low_content, true);
  const read = await execute(brain, 'read', { path: meeting.path, offset: meeting.read_offset });
  assert.equal(read.source.start_line, meeting.source.start_line);
  assert.ok(read.content.startsWith(meeting.excerpt));
  assert.equal((await execute(brain, 'search', { query: 'nonexistent' })).total_matches, 0);
  assert.equal((await execute(brain, 'search', { query: 'budget', kind: 'meetings' })).results.length, 1);
});

test('Unicode case folding preserves original excerpt positions', async t => {
  const { brain, put } = await fixture(t);
  await put('notes/unicode.md', '# İİİİİİİİİİİİİİİİİİİİİİİİİİİİİİ\nTarget\nAnother line\n');
  const found = (await execute(brain, 'search', { query: 'target' })).results[0];
  assert.equal(found.source.start_line, 2);
  assert.ok(found.excerpt.startsWith('Target'));
  const page = await execute(brain, 'read', { path: found.path, offset: found.read_offset });
  assert.ok(page.content.startsWith('Target'));
});

test('recent uses capture date despite file modification dates, with deterministic pagination', async t => {
  const { root, brain } = await fixture(t);
  await utimes(path.join(root, 'meetings/2026-09-01-budget.md'), new Date(), new Date('2030-01-01'));
  const a = await execute(brain, 'recent', { kind: 'meetings', limit: 1 });
  assert.equal(a.results[0].timestamp, '2026-09-01T13:00:00.000Z');
  const first = await execute(brain, 'recent', { limit: 2 });
  const second = await execute(brain, 'recent', { limit: 2, offset: first.next_offset });
  assert.equal(new Set([...first.results, ...second.results].map(x => x.path)).size, 4);
});

test('read paginates long lines without content loss and uses LF-based citations', async t => {
  const { brain, put } = await fixture(t);
  const original = '# Long\r\n' + 'hello 😀 '.repeat(5000) + '\r\nEnd';
  await put('notes/long.md', original);
  let content = '', offset = 0;
  do {
    const page = await execute(brain, 'read', { path: 'notes/long.md', offset, max_chars: 999 });
    assert.equal(page.source.start_line, content.split('\n').length);
    content += page.content;
    offset = page.next_offset;
  } while (offset !== null);
  assert.equal(content, original.replaceAll('\r\n', '\n'));
  await assert.rejects(execute(brain, 'read', { path: 'notes/long.md', offset: 200000 }), { code: 'INVALID_OFFSET' });
});

test('tasks distinguishes open and done, paginates, and does not alter exports', async t => {
  const { brain, root } = await fixture(t);
  const before = await readFile(path.join(root, 'tasks.md'));
  const first = await execute(brain, 'tasks', { limit: 1 });
  assert.equal(first.total, 2);
  assert.equal(first.results[0].title, 'Send proposal');
  assert.equal(first.results[0].source.start_line, 3);
  const next = await execute(brain, 'tasks', { offset: first.next_offset });
  assert.equal(next.results[0].title, 'Call Alex');
  assert.equal(next.next_offset, null);
  assert.equal((await execute(brain, 'tasks', { state: 'done' })).results[0].title, 'Book room');
  assert.equal((await execute(brain, 'tasks', { state: 'all' })).total, 3);
  assert.deepEqual(await readFile(path.join(root, 'tasks.md')), before);
});

test('missing root, absent tasks, and empty tasks are distinct; reads reflect new exports', async t => {
  const { brain, base, root, put } = await fixture(t);
  await assert.rejects(new Brain(path.join(base, 'missing')).status(), { code: 'BRAIN_NOT_FOUND' });
  await rm(path.join(root, 'tasks.md'));
  await assert.rejects(execute(brain, 'tasks'), { code: 'DOCUMENT_NOT_FOUND' });
  await put('tasks.md', '# Tasks\n');
  assert.equal((await execute(brain, 'tasks')).total, 0);
  await put('tasks.md', '# Tasks\n- [ ] New task\n');
  assert.equal((await execute(brain, 'tasks')).total, 1);
});

test('read denies traversal, hidden files, media, nested paths, and arbitrary singleton files', async t => {
  const { brain, base } = await fixture(t);
  await writeFile(path.join(base, 'secret.md'), 'outside-secret');
  for (const relative of ['../secret.md', '/etc/passwd', 'notes/../../secret.md', 'notes/../tasks.md', 'notes//x.md', 'notes\\x.md', 'notes/.secret.md', 'notes/a/b.md', 'notes/image.png', 'secrets.env', 'README.md', 'notes/x.md\0']) {
    await assert.rejects(execute(brain, 'read', { path: relative }), { code: 'INVALID_PATH' });
  }
});

test('symlinked roots, files, folders, and hard-linked files cannot disclose outside data', async t => {
  const { brain, base, root } = await fixture(t);
  await writeFile(path.join(base, 'secret.md'), 'outside-secret');
  await symlink(root, path.join(base, 'alias'));
  await assert.rejects(new Brain(path.join(base, 'alias')).status(), { code: 'INVALID_ROOT' });
  await symlink(path.join(base, 'secret.md'), path.join(root, 'notes/link.md'));
  await link(path.join(base, 'secret.md'), path.join(root, 'notes/hard.md'));
  for (const file of ['notes/link.md', 'notes/hard.md']) await assert.rejects(brain.load(file), { code: 'UNSAFE_PATH' });
  await rm(path.join(root, 'recordings'), { recursive: true });
  await symlink(base, path.join(root, 'recordings'));
  await assert.rejects(brain.load('recordings/secret.md'), { code: 'UNSAFE_PATH' });
  const result = await execute(brain, 'search', { query: 'outside-secret' });
  assert.equal(result.results.length, 0);
  assert.equal(result.partial, true);
  assert.ok(result.warning_count >= 3);
});

test('oversized and invalid files produce partial scan warnings without leaking content', async t => {
  const { brain, put } = await fixture(t);
  await put('notes/large.md', 'x'.repeat(limits.fileBytes + 1));
  await put('notes/invalid.md', Buffer.from([0xff, 0xfe]));
  await put('notes/binary.md', 'abc\0def');
  for (const [file, code] of [['large', 'FILE_TOO_LARGE'], ['invalid', 'INVALID_TEXT'], ['binary', 'INVALID_TEXT']]) await assert.rejects(brain.load(`notes/${file}.md`), { code });
  const result = await execute(brain, 'search', { query: 'budget' });
  assert.equal(result.partial, true);
  assert.equal(result.warning_count, 3);
  assert.ok(result.results.length > 0);
});

test('malformed metadata stays plain text and media references are not followed', async t => {
  const { brain, put } = await fixture(t);
  await put('recordings/example.md', '---\nstarted: not-a-date\nfile: /etc/passwd\n---\n# Example\nA recording transcript.');
  const result = await execute(brain, 'read', { path: 'recordings/example.md' });
  assert.equal(result.timestamp, null);
  assert.ok(result.content.endsWith('A recording transcript.'));
  assert.equal(result.content.includes('root:'), false);
});

test('arguments reject invalid limits, unknown fields, and attempted root overrides', async t => {
  const { brain } = await fixture(t);
  for (const args of [{ query: 'x', limit: 0 }, { query: 'x', limit: 51 }, { query: 'x', root: '/' }, { query: 'x', kind: 'private' }, null]) {
    await assert.rejects(execute(brain, 'search', args), { code: 'INVALID_ARGUMENTS' });
  }
  await assert.rejects(execute(brain, 'search', { query: '!!!' }), { code: 'INVALID_QUERY' });
  await assert.rejects(execute(brain, 'constructor'), { code: 'UNKNOWN_TOOL' });
});

test('CLI returns JSON, uses a root with spaces, and reports errors on stderr', async t => {
  const { brain, root } = await fixture(t);
  const cli = fileURLToPath(new URL('../cli.mjs', import.meta.url));
  const run = (...args) => spawnSync(process.execPath, [cli, '--root', root, ...args], { encoding: 'utf8' });
  const good = run('tasks');
  assert.equal(good.status, 0, good.stderr);
  assert.deepEqual(JSON.parse(good.stdout), await execute(brain, 'tasks'));
  assert.equal(good.stderr, '');
  const invalid = run('read', '{invalid');
  assert.equal(invalid.status, 1);
  assert.equal(invalid.stdout, '');
  assert.equal(JSON.parse(invalid.stderr).error.code, 'INVALID_COMMAND');
  const denied = run('read', '{"path":"../secret.md"}');
  assert.equal(JSON.parse(denied.stderr).error.code, 'INVALID_PATH');
});

test('meeting discovery separates participants from mentions and preserves ambiguous calls', async t => {
  const { brain, put } = await fixture(t);
  const call = (date, people, title, body = '') => `---\nstarted: ${date}T09:00:00-04:00\nended: ${date}T10:00:00-04:00\nparticipants:\n${people.map(p => '  - ' + p).join('\n')}\n---\n# ${title}\n${body}`;
  await put('meetings/a.md', call('2026-09-10', ['Jared Lane <jared@example.com>', 'Zoë Park'], 'Design review', 'Pricing flow'));
  await put('meetings/b.md', call('2026-09-11', ['Jared Lane', 'Zoë Park'], 'Design review'));
  await put('meetings/mention.md', call('2026-09-11', ['Alex'], 'Other call', 'We mentioned Jared and Zoe.'));
  const candidates = await execute(brain, 'meetings', { participants: ['jared', 'zoe'], limit: 1 });
  assert.equal(candidates.total, 2);
  assert.equal(candidates.next_offset, 1);
  assert.equal(candidates.results[0].path, 'meetings/b.md');
  const next = await execute(brain, 'meetings', { participants: ['jared', 'zoe'], offset: candidates.next_offset });
  assert.equal(next.results[0].started_at, '2026-09-10T13:00:00.000Z');
  assert.equal(next.results[0].interval_available, true);
  assert.equal((await execute(brain, 'meetings', { participants: ['Jar'] })).total, 0);
  assert.equal((await execute(brain, 'meetings', { participants: ['jared@example.com'] })).total, 1);
  assert.equal((await execute(brain, 'meetings', { participants: ['Jared'], query: 'pricing', started_after: '2026-09-10T00:00:00-04:00', started_before: '2026-09-11T00:00:00-04:00' })).total, 1);
  const mentions = await execute(brain, 'meetings', { query: 'Jared' });
  assert.equal(mentions.total, 3);
  assert.equal(mentions.results.at(-1).matched_in, 'meeting_content');
});

test('meeting screenshots use full real interval, offset dates, exact boundaries, and all pages', async t => {
  const { brain, put, root } = await fixture(t);
  await put('meetings/call.md', '---\nstarted: 2026-09-10T23:30:00-04:00\nended: 2026-09-11T01:00:00-04:00\n---\n# Long call\n');
  const shot = (time, file = '/Users/example/MyMan Screenshots/image.png') => `---\ncaptured: ${time}\nfile: ${file}\n---\n# Screenshot\n(no text detected)`;
  await put('screenshots/before.md', shot('2026-09-11T03:29:59Z'));
  await put('screenshots/end.md', shot('2026-09-11T05:00:00Z'));
  await put('screenshots/after.md', shot('2026-09-11T05:00:01Z'));
  for (let i = 0; i < 55; i++) await put(`screenshots/item-${String(i).padStart(2, '0')}.md`, shot(new Date(Date.parse('2026-09-11T03:30:00Z') + i * 60000).toISOString()));
  await utimes(path.join(root, 'screenshots/before.md'), new Date(), new Date('2026-09-11T04:00:00Z'));
  const first = await execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/call.md' });
  assert.equal(first.total, 55);
  assert.equal(first.results.length, 50);
  assert.equal(first.results[0].seconds_into_meeting, 0);
  assert.equal(first.results[0].image_path, '/Users/example/MyMan Screenshots/image.png');
  assert.equal(first.partial, true); // original undated fixture is not silently assigned
  assert.equal(first.screenshots_without_capture_time, 1);
  const last = await execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/call.md', offset: first.next_offset });
  assert.equal(last.results.length, 5);
  assert.equal(last.results.at(-1).seconds_into_meeting, 54 * 60);
  assert.equal(last.next_offset, null);
  assert.equal(new Set([...first.results, ...last.results].map(s => s.path)).size, 55);
  const cli = fileURLToPath(new URL('../cli.mjs', import.meta.url));
  const run = spawnSync(process.execPath, [cli, '--root', root, 'meeting_screenshots', JSON.stringify({ meeting_path: 'meetings/call.md', offset: 50 })], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(JSON.parse(run.stdout).results.length, 5);
});

test('incomplete, reversed, invalid, and timezone-free meeting intervals are never guessed', async t => {
  const { brain, put } = await fixture(t);
  for (const [start, end] of [['2026-09-11T13:00:00Z', ''], ['2026-09-11T13:00:00Z', '2026-09-11T12:00:00Z'], ['2026-09-11T13:00:00', '2026-09-11T14:00:00'], ['2026-02-30T13:00:00Z', '2026-03-01T14:00:00Z']]) {
    await put('meetings/invalid.md', `---\nstarted: ${start}\nended: ${end}\n---\n# Call\n`);
    await assert.rejects(execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/invalid.md' }), { code: 'MEETING_INTERVAL_UNAVAILABLE' });
  }
  await assert.rejects(execute(brain, 'meetings', { started_after: 'yesterday' }), { code: 'INVALID_ARGUMENTS' });
  await assert.rejects(execute(brain, 'meetings', { started_after: '2026-09-11T14:00:00Z', started_before: '2026-09-11T13:00:00Z' }), { code: 'INVALID_RANGE' });
  await assert.rejects(execute(brain, 'meeting_screenshots', { meeting_path: 'notes/2026-09-02-launch.md' }), { code: 'INVALID_PATH' });
  await assert.rejects(execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/../../secret.md' }), { code: 'INVALID_PATH' });
});

test('deleted exports disappear, missing images remain references, and scan failures are explicit', async t => {
  const { brain, put, root, base } = await fixture(t);
  await put('meetings/call.md', '---\nstarted: 2026-09-11T13:00:00Z\nended: 2026-09-11T14:00:00Z\n---\n# Call\n');
  await put('screenshots/during.md', '---\ncaptured: 2026-09-11T13:01:00Z\nfile: /missing/image.png\n---\n# Screenshot\n');
  await symlink(path.join(base, 'outside.md'), path.join(root, 'screenshots/link.md'));
  const result = await execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/call.md' });
  assert.equal(result.total, 1);
  assert.equal(result.results[0].image_path, '/missing/image.png');
  assert.equal(result.partial, true);
  assert.ok(result.warnings.some(w => w.code === 'UNSAFE_PATH'));
  await rm(path.join(root, 'screenshots/during.md'));
  assert.equal((await execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/call.md' })).total, 0);
  await rm(path.join(root, 'meetings/call.md'));
  await assert.rejects(execute(brain, 'meeting_screenshots', { meeting_path: 'meetings/call.md' }), { code: 'DOCUMENT_NOT_FOUND' });
});

test('collect combines time, kinds, phrases, alternatives, and full-evidence pagination', async t => {
  const { brain, put } = await fixture(t);
  await put('screenshots/prices.md', '---\ncaptured: 2026-09-02T14:30:00Z\n---\n# Plans\nRegistration price $49. Renewal is $59.');
  await put('meetings/window.md', '---\nstarted: 2026-09-02T14:00:00Z\nended: 2026-09-02T15:00:00Z\n---\n# Pricing\n');
  const matches = await execute(brain, 'collect', { kinds: ['screenshots', 'notes'], query: '"registration price" launch', match: 'any', after: '2026-09-02T10:00:00-04:00', before: '2026-09-02T11:00:00-04:00', limit: 1 });
  assert.equal(matches.total, 2);
  assert.equal(matches.results[0].path, 'screenshots/prices.md');
  const source = await execute(brain, 'read', { path: matches.results[0].path, offset: matches.results[0].read_offset });
  assert.ok(source.content.startsWith(matches.results[0].excerpt));
  assert.equal(source.source.start_line, matches.results[0].source.start_line);
  assert.equal((await execute(brain, 'collect', { kinds: ['screenshots'], query: '"price registration"' })).total, 0);
  assert.equal((await execute(brain, 'collect', { kinds: ['screenshots'], query: 'registration $49' })).total, 1);
  const during = await execute(brain, 'collect', { kinds: ['notes', 'screenshots'], during: 'meetings/window.md' });
  assert.equal(during.total, 2);
  assert.equal(during.relationship, 'captured_during_meeting');
  await assert.rejects(execute(brain, 'collect', { participants: ['Jared'] }), { code: 'INVALID_ARGUMENTS' });
  await assert.rejects(execute(brain, 'collect', { during: 'meetings/window.md', after: '2026-09-02T14:00:00Z' }), { code: 'INVALID_ARGUMENTS' });
  await assert.rejects(execute(brain, 'collect', { theme: 'pricing' }), { code: 'CATALOG_REQUIRED' });
});

test('catalog provides saved themes, pinning, full tasks and dictation while excluding stale files', async t => {
  const { brain, put, root } = await fixture(t);
  for (const folder of ['dictations', 'task-items', 'themes']) await mkdir(path.join(root, folder));
  await put('dictations/thought.md', '---\ncreated: 2026-09-11T13:00:00Z\n---\n# Pricing idea\nTry a renewal offer.');
  await put('themes/pricing.md', '# Pricing research\nnotes/2026-09-02-launch.md');
  await put('task-items/task.md', '---\ncreated: 2026-09-10T13:00:00Z\n---\n# Compare plans\nInclude taxes and renewal prices.');
  const entries = [
    { path: 'notes/2026-09-02-launch.md', kind: 'notes', title: 'Launch checklist', timestamp: '2026-09-02T14:00:00Z', pinned: true, themes: [{ id: 'theme1', title: 'Pricing research' }] },
    { path: 'dictations/thought.md', kind: 'dictations', title: 'Pricing idea', timestamp: '2026-09-11T13:00:00Z', themes: [{ id: 'theme1', title: 'Pricing research' }] },
    { path: 'themes/pricing.md', kind: 'themes', title: 'Pricing research', timestamp: '2026-09-11T13:00:00Z' },
    { path: 'task-items/task.md', kind: 'tasks', title: 'Compare plans', timestamp: '2026-09-10T13:00:00Z', done: false },
  ];
  await put('catalog.json', JSON.stringify({ version: 1, generated_at: '2026-09-11T14:00:00Z', exports: entries }));
  const themed = await execute(brain, 'collect', { theme: 'theme1', limit: 1 });
  assert.equal(themed.total, 2);
  assert.equal(themed.results[0].kind, 'dictations');
  assert.equal((await execute(brain, 'collect', { theme: 'Pricing', pinned_only: true })).total, 1);
  assert.equal((await execute(brain, 'collect', { kinds: ['themes'] })).results[0].title, 'Pricing research');
  const tasks = await execute(brain, 'tasks');
  assert.equal(tasks.total, 1); // legacy tasks.md is superseded, never duplicated
  assert.equal(tasks.results[0].title, 'Compare plans');
  assert.equal((await execute(brain, 'collect', { kinds: ['tasks'], query: 'renewal', state: 'open', after: '2026-09-10T00:00:00Z' })).total, 1);
  await put('task-items/task.md', '---\ncreated: 2026-09-01T13:00:00Z\ncompleted: 2026-09-10T13:00:00Z\ndue: 2026-09-12T00:00:00Z\n---\n# Compare plans\nInclude renewal prices.');
  assert.equal((await execute(brain, 'collect', { kinds: ['tasks'], date_field: 'task_completed', after: '2026-09-10T00:00:00Z', before: '2026-09-11T00:00:00Z' })).total, 1);
  assert.equal((await execute(brain, 'collect', { kinds: ['tasks'], date_field: 'task_due', before: '2026-09-11T00:00:00Z' })).total, 0);
  assert.equal((await execute(brain, 'search', { kind: 'meetings', query: 'proposal' })).total_matches, 0);
  await assert.rejects(execute(brain, 'read', { path: 'meetings/2026-09-01-budget.md' }), { code: 'DOCUMENT_NOT_FOUND' });
  await put('catalog.json', JSON.stringify({ version: 1, exports: entries.filter(e => e.kind !== 'dictations') }));
  assert.equal((await execute(brain, 'collect', { kinds: ['dictations'] })).total, 0);
  await assert.rejects(execute(brain, 'read', { path: 'dictations/thought.md' }), { code: 'DOCUMENT_NOT_FOUND' });
  await rm(path.join(root, 'task-items/task.md'));
  assert.equal((await execute(brain, 'collect', { kinds: ['tasks'] })).partial, true);
});

test('broken or linked catalogs never fall back to disclosing excluded legacy exports', async t => {
  const { brain, put, root, base } = await fixture(t);
  await put('catalog.json', '{invalid');
  await assert.rejects(execute(brain, 'collect', {}), { code: 'INVALID_CATALOG' });
  await put('catalog.json', JSON.stringify({ version: 1, exports: [{ path: '../secret.md', kind: 'notes' }] }));
  await assert.rejects(execute(brain, 'read', { path: 'notes/2026-09-02-launch.md' }), { code: 'INVALID_CATALOG' });
  await rm(path.join(root, 'catalog.json'));
  await writeFile(path.join(base, 'catalog.json'), JSON.stringify({ version: 1, exports: [] }));
  await symlink(path.join(base, 'catalog.json'), path.join(root, 'catalog.json'));
  await assert.rejects(execute(brain, 'collect', {}), { code: 'UNSAFE_PATH' });
});

test('image access requires a catalog-listed original, ignores markdown paths, and reflects exclusion', async t => {
  const { brain, root, base, put } = await fixture(t);
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA5sAAAAASUVORK5CYII=', 'base64');
  const original = path.join(await realpath(base), 'original.png');
  await writeFile(original, png);
  const relative = 'screenshots/2026-09-03-launch.md';
  await put(relative, '---\nfile: /etc/passwd\ncaptured: 2026-09-03T12:00:00Z\n---\n# Screenshot');
  await assert.rejects(execute(brain, 'image', { path: relative }), { code: 'CATALOG_REQUIRED' });
  const catalog = file => JSON.stringify({ version: 1, exports: [{ path: relative, kind: 'screenshots', image_path: file }] });
  await put('catalog.json', catalog(original));
  const result = await execute(brain, 'image', { path: relative });
  assert.deepEqual(Buffer.from(result.image.data, 'base64'), png);
  assert.equal(result.width, 1); assert.equal(result.height, 1);
  await symlink(original, path.join(base, 'linked.png'));
  await put('catalog.json', catalog(path.join(base, 'linked.png')));
  await assert.rejects(execute(brain, 'image', { path: relative }), { code: 'UNSAFE_PATH' });
  await put('catalog.json', catalog(original));
  await writeFile(original, 'this is plain text, not an image'.repeat(5));
  await assert.rejects(execute(brain, 'image', { path: relative }), { code: 'INVALID_IMAGE' });
  await writeFile(original, Buffer.alloc(8 * 1024 * 1024 + 1));
  await assert.rejects(execute(brain, 'image', { path: relative }), { code: 'IMAGE_TOO_LARGE' });
  await put('catalog.json', JSON.stringify({ version: 1, exports: [] }));
  await assert.rejects(execute(brain, 'image', { path: relative }), { code: 'DOCUMENT_NOT_FOUND' });
  assert.equal(await readFile(path.join(root, relative), 'utf8'), '---\nfile: /etc/passwd\ncaptured: 2026-09-03T12:00:00Z\n---\n# Screenshot');
});
