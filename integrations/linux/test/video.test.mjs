import assert from 'node:assert/strict';
import test from 'node:test';
import { filterGraph, prepareEdits, sampleTimes } from '../video.mjs';

test('frame times match the Mac: evenly spaced by default, strictly inside the video', () => {
  assert.deepEqual(sampleTimes(undefined, 4, 8), [1, 3, 5, 7]);
  assert.deepEqual(sampleTimes([0, 2.5], 6, 3), [0, 2.5]);
  assert.throws(() => sampleTimes([3], 6, 3), e => e.code === 'INVALID_ARGUMENTS');
  assert.throws(() => sampleTimes(undefined, 13, 3), e => e.code === 'INVALID_ARGUMENTS');
  assert.throws(() => sampleTimes(undefined, 2, 0), e => e.code === 'INVALID_ARGUMENTS');
});

test('edit validation follows AgentVideoEdits: rects, zoom limits, text rules, overlaps', () => {
  const ok = prepareEdits([
    { type: 'caption', start: 0, end: 2, text: 'Nothing is sent yet' },
    { type: 'step', start: 1, end: 3, number: 2, text: 'Click Save' },
    { type: 'title', start: 0, end: 1, text: 'Intro' },
    { type: 'redact', start: 0, end: 5, rect: [0, 0, 100, 40] },
    { type: 'zoom', start: 2, end: 4, rect: [100, 100, 640, 400] },
  ], 1280, 800, 5);
  assert.equal(ok.length, 5);
  const [caption, step, title] = ok;
  assert.ok(caption.y > 600, 'captions sit at the bottom'); assert.equal(step.y, 16, 'steps sit at the top');
  assert.equal(title.y, Math.round((800 - title.boxHeight) / 2)); assert.equal(title.opacity, 1);
  assert.equal(step.lines[0], '2. Click Save');
  const bad = [
    [{ type: 'zoom', start: 0, end: 1, rect: [0, 0, 100, 100] }], // > 8x
    [{ type: 'zoom', start: 0, end: 2, rect: [0, 0, 640, 400] }, { type: 'zoom', start: 1, end: 3, rect: [0, 0, 640, 400] }],
    [{ type: 'caption', start: 0, end: 2, text: 'a' }, { type: 'caption', start: 1, end: 3, text: 'b' }],
    [{ type: 'redact', start: 0, end: 1, rect: [1200, 0, 100, 10] }],
    [{ type: 'redact', start: 0, end: 1, rect: [0, 0, 10, 10], text: 'x' }],
    [{ type: 'caption', start: 0, end: 1, text: 'x', number: 1 }],
    [{ type: 'step', start: 0, end: 1, text: 'x', number: 1.5 }],
    [{ type: 'caption', start: 2, end: 1, text: 'x' }],
    [{ type: 'caption', start: 0, end: 6, text: 'x' }],
    [{ type: 'blur', start: 0, end: 1 }],
  ];
  for (const edits of bad) assert.throws(() => prepareEdits(edits, 1280, 800, 5), e => e.code === 'INVALID_ARGUMENTS', JSON.stringify(edits));
  assert.throws(() => prepareEdits([{ type: 'title', start: 0, end: 1, text: 'word '.repeat(40) }], 200, 60, 5), /does not fit/);
});

test('filter graph redacts before zooming, overlays text last, then trims', () => {
  const edits = prepareEdits([{ type: 'redact', start: 0, end: 5, rect: [0, 0, 100, 40] }, { type: 'zoom', start: 2, end: 4, rect: [100, 100, 640, 400] }, { type: 'caption', start: 0, end: 2, text: "It's <ok>" }], 1280, 800, 5);
  const g = filterGraph(edits, 1280, 800, 1, 4, null);
  assert.ok(g.indexOf('drawbox') < g.indexOf('crop=640:400:100:100') && g.indexOf('crop=') < g.indexOf('[1:v]overlay'));
  assert.match(g, /trim=start=1\.000:end=4\.000,setpts=PTS-STARTPTS,format=yuv420p\[out\]$/);
  assert.ok(!g.includes("It's"), 'text never enters the filter graph; it is rendered to an image first');
  assert.match(filterGraph([], 1280, 800, 0, 1, [640, 480]), /scale=w='min\(iw,640\)'/);
});
