import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BASIC_LATIN } from '../engine/types';
import { skeleton } from '../engine/skeletons';
import { parsePath } from '../engine/paths';

test('every non-space basic Latin target has distinct valid anatomical construction', () => {
  const outlines = new Map<string, string>();
  for (const char of BASIC_LATIN.filter(c => c !== ' ')) {
    const paths = skeleton(char, 2);
    assert.ok(paths.length, `Missing ${char}`);
    for (const path of paths) {
      const box = parsePath(path).getBoundingBox();
      assert.ok([box.x1, box.x2, box.y1, box.y2].every(Number.isFinite), char);
    }
    outlines.set(char, paths.join(' '));
  }
  for (const pair of ['aA', 'gG', '0O', 'bd', 'pq', 'MW', 'nh', 'nu']) assert.notEqual(outlines.get(pair[0]), outlines.get(pair[1]), pair);
});

test('bowl construction responds to measured roundness rather than a fixed font outline', () => {
  assert.notEqual(skeleton('o', 1.8).join(), skeleton('o', 3).join());
});
