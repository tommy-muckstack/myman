import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { musicTrack, withMusic } from '../actions.mjs';

test('built-in music tracks are found from flags and recipes', () => {
  assert.equal(musicTrack({ music: 'calm' }), 'calm');
  assert.equal(musicTrack({ music: '/tmp/song.m4a' }), null);
  assert.equal(musicTrack({ music: 'none' }), null);
  assert.equal(musicTrack({ recipe: { music: { track: 'cinematic', volume: 0.3 } } }), 'cinematic');
  assert.equal(musicTrack({ recipe: { music: { file: '/tmp/a.wav' } } }), null);
  assert.equal(musicTrack({ recipe: { music: true } }), 'upbeat');
  assert.equal(musicTrack({ auto_zoom: 'normal' }), null);
});

test('a built-in track is composed once, cached, and handed to the app as a file', async () => {
  const cache = await mkdtemp(path.join(os.tmpdir(), 'myman-music-'));
  try {
    const flag = await withMusic({ id: 'r1', music: 'calm' }, { cache });
    assert.equal(flag.music, path.join(cache, 'calm-v1.wav'));
    assert.equal(flag.music_track, 'calm');
    assert.equal((await readFile(flag.music)).subarray(0, 4).toString(), 'RIFF');
    const recipe = await withMusic({ id: 'r1', recipe: { music: { track: 'calm', volume: 0.3 } } }, { cache });
    assert.deepEqual(recipe.recipe.music, { volume: 0.3, file: path.join(cache, 'calm-v1.wav') });
    assert.equal(recipe.music_track, 'calm');
    await assert.rejects(withMusic({ id: 'r1', music: 'polka' }, { cache }), /upbeat, calm, cinematic/);
    const own = { id: 'r1', music: '/tmp/mine.wav' };
    assert.equal(await withMusic(own, { cache }), own);
  } finally { await rm(cache, { recursive: true, force: true }); }
});

test('a demo gets the upbeat track unless its script chooses otherwise', async () => {
  const { withDemoMusic } = await import('../actions.mjs');
  const cache = await mkdtemp(path.join(os.tmpdir(), 'myman-music-'));
  try {
    const script = { app: 'Spotify', steps: [{ click: [10, 10] }] };
    const upbeat = await withDemoMusic({ script }, { cache });
    assert.equal(upbeat.music_track, 'upbeat');
    assert.deepEqual(upbeat.script.polish.music, { file: path.join(cache, 'upbeat-v1.wav') });
    assert.equal(upbeat.script.steps, script.steps);
    const calm = await withDemoMusic({ script: { ...script, polish: { music: 'calm', background: 'ocean' } } }, { cache });
    assert.equal(calm.music_track, 'calm'); assert.equal(calm.script.polish.background, 'ocean');
    for (const args of [{ script: { ...script, polish: false } }, { script: { ...script, polish: { music: 'none' } } }, { script, dry_run: true }]) {
      assert.equal(await withDemoMusic(args, { cache }), args);
    }
  } finally { await rm(cache, { recursive: true, force: true }); }
});
