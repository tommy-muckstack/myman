import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { alternativeFor, closest, human, suggestCommand, suggestFlag } from '../guide.mjs';
const run = promisify(execFile);
const cli = new URL('../cli.mjs', import.meta.url).pathname;
async function json(...args) { try { const { stdout } = await run(process.execPath, [cli, ...args]); return JSON.parse(stdout); } catch (error) { return JSON.parse(error.stdout); } }

test('suggests the command or flag that was probably meant', () => {
  assert.deepEqual(suggestCommand(['library', 'serch', '--query', 'x']).suggestions, ['library search']);
  assert.deepEqual(suggestCommand(['libary', 'search']).suggestions, ['library']);
  assert.equal(suggestCommand(['library', 'search', '--query', 'x']), null);
  assert.deepEqual(suggestFlag("Unknown option '--quer'. To specify").suggestions, ['--query']);
  assert.deepEqual(closest('item.reed', ['item.read', 'item.related', 'task.create']), ['item.read', 'item.related']);
  assert.match(alternativeFor('theme.rename'), /Mac-only/);
});

test('typos return suggestions in JSON, never a bare parse error', async () => {
  const typo = await json('library', 'serch', '--query', 'x', '--json');
  assert.equal(typo.error.code, 'INVALID_ARGUMENTS');
  assert.deepEqual(typo.error.suggestions, ['myman library search']);
  assert.doesNotMatch(typo.error.message, /valid JSON/);
  const flag = await json('library', 'search', '--quer', 'x', '--json');
  assert.deepEqual(flag.error.suggestions, ['--query']);
  const action = await json('invoke', 'item.reed', '{}', '--json');
  assert.match(action.error.message, /Did you mean item\.read/);
  const mac = await json('invoke', 'theme.rename', '{}', '--json');
  assert.equal(mac.error.code, 'unsupported_on_platform');
  assert.match(mac.error.alternative, /library search/);
});

test('plain-text rendering is readable', () => {
  const text = human({ ok: true, query: 'deck', total: 1, results: [{ id: 'shot-1', kind: 'screenshot', title: 'Deck', reasons: ['exact phrase'] }] });
  assert.match(text, /1 results:\n- Deck \(screenshot, shot-1\)\n {4}why: exact phrase/);
  const error = human({ ok: false, error: { code: 'INVALID_ARGUMENTS', message: 'Unknown command.', suggestions: ['myman library search'] } });
  assert.match(error, /^Error: Unknown command\.\nDid you mean: myman library search\?/);
});
