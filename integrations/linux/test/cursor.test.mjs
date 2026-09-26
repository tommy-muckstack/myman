import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { activity, build, summary, track } from '../cursor.mjs';

// Stand-in xdotool and xinput: the pointer walks right, then a left click,
// a right click (ignored: only buttons 1-3 count, wheel is 4+), and typing.
async function fakes() {
  const dir = await mkdtemp(path.join(tmpdir(), 'myman-cursor-'));
  await writeFile(path.join(dir, 'xdotool'), `#!/bin/sh\nn=$(cat "${dir}/n" 2>/dev/null || echo 0); echo $((n+1)) > "${dir}/n"\necho "X=$((100 + n * 5))"; echo "Y=$((300 + n))"; echo SCREEN=0; echo WINDOW=1\n`);
  await writeFile(path.join(dir, 'xinput'), `#!/bin/sh\nsleep 0.3\nprintf 'EVENT type 15 (RawButtonPress)\\n    device: 2 (11)\\n    detail: 1\\n    valuators:\\nEVENT type 15 (RawButtonPress)\\n    device: 2 (11)\\n    detail: 5\\n'\nfor i in 1 2 3 4; do printf 'EVENT type 13 (RawKeyPress)\\n    device: 3 (9)\\n    detail: 38\\n'; done\nsleep 5\n`);
  await chmod(path.join(dir, 'xdotool'), 0o755); await chmod(path.join(dir, 'xinput'), 0o755);
  return dir;
}

test('the tracker logs pointer moves inside the region, clicks and typing moments, never which keys', async () => {
  const dir = await fakes(), log = path.join(dir, 'log.jsonl');
  process.env.PATH = `${dir}:${process.env.PATH}`;
  const session = { session_type: 'x11', region: [50, 200, 800, 600], origin: [0, 0], recorded: 10, run_started_at: new Date().toISOString(), max_duration: 60 };
  const until = Date.now() + 1300;
  await track(session, log, async () => Date.now() < until, { exit: false });
  const lines = (await readFile(log, 'utf8')).trim().split('\n').map(l => JSON.parse(l));
  assert.deepEqual({ ...lines[0], t: 0 }, { t: 0, e: 'info', pointer: 'tracked', input: 'tracked' });
  const moves = lines.filter(l => !l.e);
  assert.ok(moves.length >= 10, `sampled ${moves.length} positions`);
  assert.deepEqual([moves[0].x, moves[0].y], [50, 100], 'positions are relative to the recorded region');
  assert.ok(moves[0].t >= 10, 'times continue after earlier segments');
  const clicks = lines.filter(l => l.e === 'click');
  assert.equal(clicks.length, 1); assert.equal(clicks[0].b, 1);
  const keys = lines.filter(l => l.e === 'key');
  assert.equal(keys.length, 4); assert.deepEqual(Object.keys(keys[0]).sort(), ['e', 't'], 'a key press records only its time');
  const saved = await build(log, { width: 800, height: 600, duration: 30 });
  assert.equal(saved.pointer, 'tracked'); assert.equal(saved.clicks_tracked, true);
  assert.equal(saved.clicks.length, 1); assert.equal(saved.keys.length, 4);
  assert.deepEqual(saved.fields.moves, ['t', 'x', 'y']);
  assert.match(summary(saved), /pointer positions, 1 clicks, 4 key presses, \d+ moments of activity$/);
});

test('activity finds clicks, typing bursts and places the pointer settled, and merges nearby ones', () => {
  const moves = [[0, 10, 10], [1, 400, 300], [4, 405, 302], [8, 700, 500]];
  const spans = activity({ moves, clicks: [[4.2, 405, 302, 1]], keys: [5, 5.3, 5.6, 5.9], width: 800, height: 600, duration: 12 });
  assert.equal(spans.length, 2);
  assert.deepEqual(spans[0].reasons.sort(), ['click', 'pointer settled', 'typing']);
  assert.deepEqual([spans[0].x, spans[0].y], [400, 300]);
  assert.equal(spans[0].start, 0.4); assert.equal(spans[0].end, 7.9);
  assert.deepEqual(spans[1], { start: 7.4, end: 10, x: 700, y: 500, reasons: ['pointer settled'] });
});

test('a desktop without pointer access says so instead of pretending', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'myman-cursor-')), log = path.join(dir, 'log.jsonl');
  await writeFile(log, JSON.stringify({ t: 0, e: 'info', pointer: 'unavailable', input: 'unavailable' }) + '\n');
  const saved = await build(log, { width: 10, height: 10, duration: 1 });
  assert.equal(saved.pointer, 'unavailable'); assert.equal(saved.clicks_tracked, false);
  assert.match(summary(saved), /pointer position unavailable.*not detected on this desktop/);
});
