import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// Meetings run with a generated tone standing in for the microphone and
// computer audio (ffmpeg lavfi, paced in real time) and a stand-in
// transcription command, so no microphone or Whisper model is needed.
const here = path.dirname(new URL(import.meta.url).pathname), cli = path.join(here, '../cli.mjs');
const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0, hasScript = spawnSync('script', ['--version']).status === 0;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const quote = s => `'${s.replace(/'/g, `'\\''`)}'`;
async function setup(grants) {
  const home = await mkdtemp(path.join(tmpdir(), 'myman-meeting-'));
  const config = path.join(home, 'config/myman'), brain = path.join(home, 'brain');
  await mkdir(config, { recursive: true }); await chmod(path.join(home, 'config'), 0o700); await chmod(config, 0o700);
  await writeFile(path.join(config, 'agents.json'), JSON.stringify({ version: 1, grants }), { mode: 0o600 });
  await mkdir(brain); spawnSync('git', ['init', '-q', brain]);
  const env = { ...process.env, XDG_CONFIG_HOME: path.join(home, 'config'), XDG_STATE_HOME: path.join(home, 'state'), MYMAN_BRAIN_ROOT: brain,
    MYMAN_AUDIO_FORMAT: 'lavfi', MYMAN_MIC_DEVICE: 'sine=f=440:d=30,arealtime',
    MYMAN_SYSTEM_DEVICE: 'aevalsrc=if(between(t\\,1\\,2)\\,sin(2*PI*300*t)\\,0):d=30:s=16000,arealtime',
    MYMAN_TRANSCRIBE_COMMAND: 'echo heard' };
  delete env.MYMAN_AGENT_TOKEN;
  return { home, brain, env };
}
// The person at the terminal: run through script(1) so stdin/stdout are a TTY.
function asPerson(env, args) {
  const out = spawnSync('script', ['-qec', [process.execPath, cli, ...args].map(quote).join(' '), '/dev/null'], { env });
  return JSON.parse(out.stdout.toString().trim().split('\n').pop());
}
const asAgent = (env, args) => { const out = spawnSync(process.execPath, [cli, ...args, '--json'], { env }); return { status: out.status, ...JSON.parse(out.stdout.toString()) }; };

test('a person records a meeting; it is saved at once and transcribed on this computer as You and Others', { skip: !(hasFfmpeg && hasScript) }, async () => {
  const { brain, env } = await setup({ enabled: false });
  const started = asPerson(env, ['meeting', 'start', '--title', 'Weekly sync', '--json']);
  assert.equal(started.ok, true, JSON.stringify(started)); assert.deepEqual(started.tracks, ['You', 'Others']); assert.equal(started.started_by, 'person');
  assert.equal(asPerson(env, ['meeting', 'start', '--json']).error.code, 'MEETING_ACTIVE');
  await sleep(1500);
  const shown = JSON.parse(spawnSync(process.execPath, [cli, 'indicator', '--json'], { env }).stdout.toString());
  assert.equal(shown.class, 'meeting'); assert.match(shown.text, /^● MIC 0:0\d$/);
  await sleep(1500);
  const stopped = asPerson(env, ['meeting', 'stop', '--json']);
  assert.equal(stopped.ok, true, JSON.stringify(stopped)); assert.equal(stopped.meeting.transcript_status, 'processing');
  assert.match(stopped.meeting.brain_path, /^meetings\/\d{4}-\d{2}-\d{2}-[0-9a-f]{8}\.md$/);
  const file = path.join(brain, stopped.meeting.brain_path);
  let doc = '';
  for (let i = 0; i < 100 && !/transcript_status: ready/.test(doc); i++) { await sleep(200); doc = await readFile(file, 'utf8'); }
  assert.match(doc, /^---\nid: [0-9a-f-]{36}\nkind: meeting\nstarted: .+\nended: .+\nsource: "linux"\ntranscript_status: ready\n/);
  assert.match(doc, /participants:\n  - "You"\n  - "Others"\n/);
  assert.match(doc, /\n# Weekly sync\n\n## Transcript\n\n\*\*You\*\* \[0:00\]: heard .+chunk-You-0\.wav/);
  assert.match(doc, /\*\*Others\*\* \[0:01\]: heard /);
  const catalog = JSON.parse(await readFile(path.join(brain, 'catalog.json'), 'utf8'));
  assert.equal(catalog.exports[0].item_id, `meeting-${started.id}`); assert.equal(catalog.exports[0].kind, 'meetings'); assert.equal(catalog.exports[0].revision, 2);
  const left = await readdir(path.join(env.XDG_STATE_HOME, 'myman/meetings', started.id));
  assert.deepEqual(left, ['session.json'], 'audio is deleted after transcription');
  assert.equal(asPerson(env, ['meeting', 'stop', '--id', started.id, '--json']).meeting.id, `meeting-${started.id}`, 'stopping again returns the same meeting');
});

test('cancel stops the recording and saves nothing', { skip: !(hasFfmpeg && hasScript) }, async () => {
  const { brain, env } = await setup({ enabled: false });
  const started = asPerson(env, ['meeting', 'start', '--no-system-audio', '--json']);
  assert.deepEqual(started.tracks, ['You']);
  const canceled = asPerson(env, ['meeting', 'cancel', '--json']);
  assert.equal(canceled.saved, false);
  assert.deepEqual((await readdir(brain)).filter(f => f !== '.git'), []);
  assert.equal(asPerson(env, ['meeting', 'status', '--json']).active, null);
});

test('agents need the microphone grant, which is off by default; live meeting notes stay Mac-only', async () => {
  const { env } = await setup({ enabled: true, recording: true });
  const denied = asAgent(env, ['meeting', 'start']);
  assert.equal(denied.ok, false); assert.equal(denied.error.code, 'AGENT_DISABLED'); assert.match(denied.error.message, /microphone/);
  const other = asAgent(env, ['meeting', 'live']);
  assert.equal(other.status, 6); assert.equal(other.error.code, 'unsupported_on_platform');
  const { defaultGrants } = await import('../policy.mjs');
  assert.equal(defaultGrants.microphone, false);
});
