// Durable agent credentials for host environments (Mac mini, SSH, MCP).
//
// A person issues a named credential in Settings → Agents (or Linux
// `myman agents add`), then stores MYMAN_AGENT_TOKEN and MYMAN_MACHINE_ID in
// `${XDG_CONFIG_HOME:-~/.config}/myman/agent.env` (mode 600). The CLI and MCP
// load that file into process.env when those variables are not already set, so
// hosts do not need to paste secrets into chat. Loading credentials never
// grants capture/markup/recording/library/sharing — grants stay human-only.
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { BrainError } from './brain.mjs';

export const CREDENTIAL_KEYS = ['MYMAN_AGENT_TOKEN', 'MYMAN_MACHINE_ID', 'MYMAN_AGENT_ID'];
export const ENV_FILE_NAME = 'agent.env';

const fail = (code, message, extra = {}) => { const error = new BrainError(code, message); Object.assign(error, extra); throw error; };

export function configDir(env = process.env, home = homedir()) {
  const xdg = env.XDG_CONFIG_HOME;
  if (xdg && path.isAbsolute(xdg)) return path.join(xdg, 'myman');
  return path.join(home, '.config', 'myman');
}

export function envFilePath(env = process.env, home = homedir()) {
  return path.join(configDir(env, home), ENV_FILE_NAME);
}

// Parse KEY=value / export KEY=value lines. No shell expansion, no unknown keys.
export function parseEnvFile(text) {
  const values = {};
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!match) continue;
    const key = match[1];
    if (!CREDENTIAL_KEYS.includes(key)) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!value) continue;
    values[key] = value;
  }
  return values;
}

function fileMeta(filePath, { statSync: stat = statSync, existsSync: exists = existsSync } = {}) {
  if (!exists(filePath)) return { exists: false, mode: null, mode_ok: false };
  try {
    const mode = stat(filePath).mode & 0o777;
    return { exists: true, mode, mode_ok: (mode & 0o077) === 0 };
  } catch {
    return { exists: false, mode: null, mode_ok: false };
  }
}

function presence(env, fileValues, key) {
  if (env[key]) return env[key] === fileValues[key] ? 'environment_and_file' : 'environment';
  if (fileValues[key]) return 'file';
  return 'missing';
}

// Read-only report for doctor / agents status. Never includes secret values.
export function credentialsStatus({
  env = process.env,
  home = homedir(),
  readFileSync: read = readFileSync,
  existsSync: exists = existsSync,
  statSync: stat = statSync,
} = {}) {
  const file = envFilePath(env, home);
  const meta = fileMeta(file, { existsSync: exists, statSync: stat });
  let fileValues = {}, parse_error = null;
  if (meta.exists) {
    try { fileValues = parseEnvFile(read(file, 'utf8')); }
    catch (error) { parse_error = error.message ?? String(error); }
  }
  const keys = {};
  for (const key of CREDENTIAL_KEYS) keys[key] = presence(env, fileValues, key);
  const missing = CREDENTIAL_KEYS.filter(key => key !== 'MYMAN_AGENT_ID' && keys[key] === 'missing');
  const optional_missing = keys.MYMAN_AGENT_ID === 'missing' ? ['MYMAN_AGENT_ID'] : [];
  const ready = missing.length === 0;
  return {
    ok: true,
    path: file,
    file_exists: meta.exists,
    file_mode: meta.mode === null ? null : `0${meta.mode.toString(8)}`,
    file_mode_ok: meta.exists ? meta.mode_ok : null,
    keys,
    ready,
    missing,
    optional_missing,
    ...(parse_error ? { parse_error } : {}),
    note: ready
      ? 'Named credentials are available to this process (from the environment and/or agent.env). This does not grant capture/markup access.'
      : `Named credentials are incomplete. A person stores MYMAN_AGENT_TOKEN and MYMAN_MACHINE_ID in ${file} (mode 600), or sets them in the host environment. Never paste tokens into chat.`,
  };
}

// Apply file values into env for keys that are unset. Idempotent; never overwrites.
export function loadAgentEnv({
  env = process.env,
  home = homedir(),
  readFileSync: read = readFileSync,
  existsSync: exists = existsSync,
  statSync: stat = statSync,
} = {}) {
  const status = credentialsStatus({ env, home, readFileSync: read, existsSync: exists, statSync: stat });
  const loaded = [];
  if (status.file_exists && !status.parse_error) {
    let fileValues = {};
    try { fileValues = parseEnvFile(read(status.path, 'utf8')); } catch { /* status already notes parse_error */ }
    for (const key of CREDENTIAL_KEYS) {
      if (env[key] || !fileValues[key]) continue;
      env[key] = fileValues[key];
      loaded.push(key);
    }
  }
  // Recompute after load so doctor sees the filled process env.
  const after = credentialsStatus({ env, home, readFileSync: read, existsSync: exists, statSync: stat });
  return { ...after, loaded_from_file: loaded, applied: loaded.length > 0 };
}

let ensured = false;
export function resetAgentEnvCache() { ensured = false; }
export function ensureAgentEnv(options) {
  if (ensured && !options?.force) return credentialsStatus(options);
  ensured = true;
  return loadAgentEnv(options);
}

// Human-only: write current env credentials into agent.env (mode 600).
// Unlike `agents grant`, MYMAN_AGENT_TOKEN may already be set (that is the value).
export async function saveCredentials({
  env = process.env,
  home = homedir(),
  stdin = process.stdin,
  stdout = process.stdout,
  stderr = process.stderr,
  ask,
  writeFileSync: write = writeFileSync,
  mkdirSync: mkdir = mkdirSync,
  chmodSync: chmod = chmodSync,
  existsSync: exists = existsSync,
  readFileSync: read = readFileSync,
} = {}) {
  if (env.CI) fail('HUMAN_REQUIRED', 'Only the person at this computer can save agent credentials, from an interactive Terminal (not from CI). Nothing changed.', {
    hint: `Ask the person to run in Terminal: myman agents credentials save`,
  });
  if (!stdin?.isTTY || !stdout?.isTTY) fail('HUMAN_REQUIRED', 'Only the person at this computer can save agent credentials, from an interactive Terminal (not from an agent). Nothing changed.', {
    hint: `Ask the person to run in Terminal: myman agents credentials save`,
  });
  const token = env.MYMAN_AGENT_TOKEN;
  const machine = env.MYMAN_MACHINE_ID;
  if (!token || !machine) fail('INVALID_ARGUMENTS', 'Set MYMAN_AGENT_TOKEN and MYMAN_MACHINE_ID in this shell first (from Settings → Agents), then re-run agents credentials save. Nothing was written.', {
    hint: 'In My Man Settings → Agents, add/copy the credential and machine ID into this Terminal session, then run: myman agents credentials save',
  });
  const file = envFilePath(env, home);
  const dir = path.dirname(file);
  const lines = [
    '# My Man agent credentials for this login.',
    '# Mode 600. The CLI and MCP load this file when MYMAN_AGENT_TOKEN /',
    '# MYMAN_MACHINE_ID / MYMAN_AGENT_ID are unset in the process environment.',
    '# Never commit this file or paste these values into chat.',
    '# Saving credentials does not grant capture/markup — use agents grant for that.',
    `export MYMAN_AGENT_TOKEN=${shellSingle(token)}`,
    `export MYMAN_MACHINE_ID=${shellSingle(machine)}`,
  ];
  if (env.MYMAN_AGENT_ID) lines.push(`export MYMAN_AGENT_ID=${shellSingle(env.MYMAN_AGENT_ID)}`);
  lines.push('');
  stderr.write([
    '', 'My Man agent credentials', '',
    `You are about to write MYMAN_AGENT_TOKEN and MYMAN_MACHINE_ID to:`,
    `  ${file}`,
    '', 'Any program running as you that loads this file (including AI agents) can use',
    'these credentials until you delete the file or revoke the agent in Settings → Agents.',
    'This does not turn on capture/markup grants.',
    '', 'To confirm, type exactly: save credentials', '',
  ].join('\n'));
  const answer = ask ? await ask('> ') : await prompt(stdin, stderr);
  if (answer.trim() !== 'save credentials') fail('CANCELLED', 'Confirmation did not match. Nothing changed.');
  mkdir(dir, { recursive: true, mode: 0o700 });
  try { chmod(dir, 0o700); } catch {}
  write(file, lines.join('\n'), { mode: 0o600 });
  try { chmod(file, 0o600); } catch {}
  // Verify we can read back the keys without echoing secrets.
  const written = parseEnvFile(read(file, 'utf8'));
  if (!written.MYMAN_AGENT_TOKEN || !written.MYMAN_MACHINE_ID) fail('SETTING_NOT_APPLIED', `Could not verify credentials were written to ${file}.`);
  const zshenv = path.join(home, '.zshenv');
  const sourceLine = `[ -r ${file.replace(home, '$HOME')} ] && source ${file.replace(home, '$HOME')}`;
  const zshenv_has_source = exists(zshenv) && read(zshenv, 'utf8').includes('agent.env');
  return {
    ok: true,
    saved: true,
    path: file,
    keys_written: Object.keys(written),
    file_mode: '0600',
    zshenv_has_source,
    ...(zshenv_has_source ? {} : {
      next: `Optional: so interactive shells also get the variables, add this line to ~/.zshenv:\n  ${sourceLine}`,
      zshenv_line: sourceLine,
    }),
    note: 'Credentials are saved. Grants are separate: run myman agents grant ... as a person if capture/markup are still off. Verify with: myman doctor --plain',
  };
}

function shellSingle(value) {
  // Safe for KEY='...' form; values are base64/uuid so usually fine unquoted too.
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

async function prompt(input, output) {
  const readline = await import('node:readline/promises');
  const rl = readline.createInterface({ input, output, terminal: true });
  try { return await rl.question('> '); } finally { rl.close(); }
}

export function credentialsNextSteps(status, env = process.env) {
  if (status.ready) return [];
  const file = status.path;
  const steps = [];
  if (!status.file_exists) {
    steps.push({
      id: 'save_credentials',
      for: 'person',
      summary: 'Save MYMAN_AGENT_TOKEN and MYMAN_MACHINE_ID to agent.env',
      run: 'myman agents credentials save',
      alternative: `Create ${file} (mode 600) with export MYMAN_AGENT_TOKEN=... and export MYMAN_MACHINE_ID=...`,
      note: 'A person issues the credential in Settings → Agents, sets the variables in an interactive Terminal, then runs agents credentials save (asks to type: save credentials). Agents cannot save credentials. This does not grant capture/markup.',
    });
  } else if (status.missing.length) {
    steps.push({
      id: 'fix_credentials',
      for: 'person',
      summary: `agent.env is missing ${status.missing.join(' and ')}`,
      run: 'myman agents credentials save',
      alternative: `Edit ${file} (mode 600) so it exports ${status.missing.join(' and ')}`,
      note: 'After editing, re-run myman doctor --plain. Never paste tokens into chat.',
    });
  }
  if (status.file_exists && status.file_mode_ok === false) {
    steps.push({
      id: 'credentials_mode',
      for: 'person',
      summary: 'Tighten agent.env permissions to mode 600',
      run: `chmod 600 ${file}`,
      note: 'Other users on this Mac should not be able to read agent credentials.',
    });
  }
  return steps;
}
