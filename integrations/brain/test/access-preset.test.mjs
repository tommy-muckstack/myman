import test from 'node:test';
import assert from 'node:assert/strict';
import { exitCode } from '../app-cli.mjs';
import { renderDoctor } from '../agent-access.mjs';

test('GRANT_OFF tells the caller a person must act, with its own exit code', () => {
  assert.equal(exitCode('GRANT_OFF'), 7);
});

test('doctor names the preset and the grants that are off, in plain words', () => {
  const text = renderDoctor({
    app: { ok: true },
    node: 'v22',
    agent_access: {
      source: 'running_app',
      grants: { enabled: true, capture: true, markup: true, recording: false, library: true, sharing: false, control: false },
      preset: 'ask',
    },
  });
  assert.match(text, /Preset: Ask each time\./);
  assert.match(text, /Off: /);
  assert.match(text, /Off: .*screen recordings/);
});

test('doctor says a hand-set configuration has no preset', () => {
  const text = renderDoctor({ app: { ok: true }, node: 'v22', agent_access: { source: 'running_app', grants: { enabled: true }, preset: null } });
  assert.match(text, /Preset: custom \(set by hand\)\./);
});
