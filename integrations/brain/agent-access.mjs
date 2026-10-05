// Human-only agent access helpers for the Mac CLI: next-step hints, passive
// grant status, `myman agents grant|revoke|status|open` and `myman install-cli`.
//
// Grants are the person's decision. Nothing here is a catalog action, so no
// MCP tool, `invoke`, socket request or `settings set` can reach `grant`. The
// command refuses inside an agent environment or without an interactive
// terminal, takes no bypass flag, and only writes after the person types a
// confirmation that names exactly what is being allowed. The same-login trust
// boundary is unchanged: the app already reads these preferences from this
// login, and the typed prompt is a guardrail against accidents and
// non-interactive automation, not a sandbox against a hostile process.
import { execFile } from 'node:child_process';
import { accessSync, constants, lstatSync, mkdirSync, realpathSync, symlinkSync } from 'node:fs';
import { homedir, userInfo } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { BrainError } from './brain.mjs';
import { credentialsStatus, credentialsNextSteps, envFilePath } from './agent-credentials.mjs';

export const BUNDLE_ID = 'com.muckstack.myman';
export const APP_CLI = '/Applications/My Man.app/Contents/Resources/myman';
export const LAUNCH_COMMAND = 'open -a "My Man"';
export const PROCESS_NAME = 'MyMan';

// Groups a person may allow from Terminal. Each maps to the same preference the
// Settings → Agents toggle writes (AgentConsent.keys in the app).
export const GRANTABLE = {
  capture: { key: 'agentCaptureEnabled', label: 'Capture screenshots without the picker', allows: 'take screenshots of any display or window without the region picker, and list shareable windows' },
  markup: { key: 'agentMarkupEnabled', label: 'Edit screenshots and create fonts', allows: 'import and edit images, remove backgrounds and create fonts' },
  recording: { key: 'agentRecordingEnabled', label: 'Control meetings, dictation and screen recordings', allows: 'start and control meeting, dictation and screen recordings' },
  library: { key: 'agentLibraryEnabled', label: 'Create and change notes, tasks and library items', allows: 'create and change notes, tasks, themes and library items, write the clipboard, and change safe settings' },
  sharing: { key: 'agentSharingEnabled', label: 'Publish explicitly selected captures to shared links', allows: 'publish captures you select to shared links' },
};
// Grants that stay in Settings → Agents only; the CLI never writes these.
export const SETTINGS_ONLY = {
  enabled: 'Allow local app commands',
  control: 'Take over the mouse and keyboard to record app demos',
  calendar_read: 'Read calendar free/busy',
  calendar_propose: 'Prepare calendar event previews',
  calendar_write: 'Book events after I review and press Book',
  scheduling_parse: 'Parse meeting requests without accessing calendars',
  people_read: 'Resolve saved people and emails',
};
const MASTER_KEY = 'agentActionsEnabled';
// Environment that marks a process as an agent host. Their presence blocks `grant`.
export const AGENT_ENV = ['MYMAN_AGENT_TOKEN', 'MYMAN_AGENT_ID', 'MYMAN_MACHINE_ID', 'CI'];

const fail = (code, message, extra = {}) => { const error = new BrainError(code, message); Object.assign(error, extra); throw error; };
const quote = value => /^[A-Za-z0-9_./:@%+=,-]+$/.test(value) ? value : `"${value}"`;

export function helperPath(env = process.env) { return env.MYMAN_HELPER_PATH || APP_CLI; }
export function onPath(env = process.env, name = 'myman') {
  for (const dir of (env.PATH || '').split(path.delimiter).filter(entry => path.isAbsolute(entry))) {
    try { accessSync(path.join(dir, name), constants.X_OK); return true; } catch {}
  }
  return false;
}
// What a person should type: `myman` when it resolves, else the exact path.
export function cli(env = process.env) { return onPath(env) ? 'myman' : quote(helperPath(env)); }
export function cliInstall(env = process.env) { return `${quote(helperPath(env))} install-cli`; }

export function cliStatus(env = process.env) {
  const helper = helperPath(env), onPathNow = onPath(env);
  return {
    path: helper, on_path: onPathNow,
    ...(onPathNow ? {} : { install_command: cliInstall(env), note: `myman is not on PATH. Run it as ${quote(helper)} or put it on PATH with install-cli.` }),
  };
}

const run = async (file, args) => (await promisify(execFile)(file, args, { timeout: 5000, encoding: 'utf8' })).stdout;
export const realDeps = {
  platform: () => process.platform,
  defaults: args => run('/usr/bin/defaults', args),
  pgrep: async () => { try { return (await run('/usr/bin/pgrep', ['-x', PROCESS_NAME])).trim().length > 0; } catch { return false; } },
};

// Passive, read-only: what the preferences say, even while the app is closed.
export async function readGrants(deps = realDeps) {
  if (deps.platform() !== 'darwin') fail('unsupported_on_platform', 'Agent preferences are read from macOS defaults.');
  const read = async key => {
    try { return (await deps.defaults(['read', BUNDLE_ID, key])).trim(); } catch { return null; }
  };
  const result = {};
  for (const [group, { key }] of Object.entries(GRANTABLE)) result[group] = (await read(key)) === '1';
  const master = await read(MASTER_KEY);
  result.enabled = master === null ? true : master === '1';
  return result;
}
export async function appRunning(deps = realDeps) { return deps.pgrep(); }

// Why `grant` must not run: an agent environment or no interactive terminal.
export function humanBlock({ env = process.env, stdin = process.stdin, stdout = process.stdout } = {}) {
  const present = AGENT_ENV.filter(name => env[name]);
  if (present.length) return `an agent environment is present (${present.join(', ')})`;
  if (!stdin?.isTTY || !stdout?.isTTY) return 'this is not an interactive terminal';
  return null;
}

export function parseGroups(names, { allowEmpty = false } = {}) {
  const wanted = (names ?? []).flatMap(name => String(name).split(',')).map(name => name.trim().toLowerCase()).filter(Boolean);
  if (!wanted.length) { if (allowEmpty) return []; fail('INVALID_ARGUMENTS', `Name what to change: ${Object.keys(GRANTABLE).join(', ')}, or all.`); }
  const groups = new Set();
  for (const name of wanted) {
    if (name === 'all') Object.keys(GRANTABLE).forEach(group => groups.add(group));
    else if (Object.hasOwn(GRANTABLE, name)) groups.add(name);
    else if (Object.hasOwn(SETTINGS_ONLY, name) || name === 'control') fail('INVALID_ARGUMENTS', `"${name}" can only be changed in My Man Settings → Agents (${SETTINGS_ONLY[name] ?? name}). Run: ${cli()} agents open`);
    else fail('INVALID_ARGUMENTS', `Unknown group "${name}". Use ${Object.keys(GRANTABLE).join(', ')}, or all.`);
  }
  return Object.keys(GRANTABLE).filter(group => groups.has(group));
}
export const phrase = groups => `grant ${groups.join(' ')}`;

function requireDarwin(deps, what) {
  if (deps.platform() !== 'darwin') fail('unsupported_on_platform', `${what} is only available on macOS. On Linux, agent grants are edited by the person in agents.json (see docs/linux-agents.md).`);
}

export async function status(deps = realDeps, env = process.env) {
  const grants = await readGrants(deps);
  const running = await appRunning(deps);
  const credentials = credentialsStatus({ env });
  const steps = [
    ...nextSteps({ grants, appRunning: running }, env),
    ...credentialsNextSteps(credentials, env),
  ];
  return {
    ok: true, source: 'preferences', app_running: running, grants,
    disabled: Object.keys(GRANTABLE).filter(group => !grants[group]),
    credentials,
    next_steps: steps,
  };
}

// `myman agents grant|revoke`. Grant is human-only; revoke only narrows access.
export async function change(action, names, { deps = realDeps, env = process.env, stdin = process.stdin, stdout = process.stdout, stderr = process.stderr, ask } = {}) {
  requireDarwin(deps, `myman agents ${action}`);
  const groups = parseGroups(names);
  if (action === 'revoke') return apply(groups, false, deps, env);
  const blocked = humanBlock({ env, stdin, stdout });
  if (blocked) fail('HUMAN_REQUIRED', `Only the person at this Mac can allow agent access, from an interactive Terminal (not from an agent): ${blocked}. Nothing changed.`, {
    hint: `Ask the person to run in Terminal: ${cli(env)} agents grant ${groups.join(' ')}. If this shell loaded ~/.config/myman/agent.env, clear agent vars first: env -u MYMAN_AGENT_TOKEN -u MYMAN_MACHINE_ID -u MYMAN_AGENT_ID ${cli(env)} agents grant ${groups.join(' ')}`,
    human_command: `${cli(env)} agents grant ${groups.join(' ')}`,
  });
  const expected = phrase(groups);
  const lines = [
    '', 'My Man agent access', '',
    `You are about to turn ON for macOS user "${userInfo().username}":`,
    ...groups.map(group => `  • ${group}: ${GRANTABLE[group].label} — agents can ${GRANTABLE[group].allows}`),
    '', 'Any program running as you on this Mac, including AI agents, can then use this access until you turn it off',
    `(${cli(env)} agents revoke ${groups.join(' ')}, or My Man → Settings → Agents). macOS Screen Recording and Accessibility permissions are not changed.`,
    '', `To confirm, type exactly: ${expected}`, '',
  ];
  stderr.write(lines.join('\n'));
  const answer = ask ? await ask('> ') : await prompt(stdin, stderr);
  if (answer.trim() !== expected) fail('CANCELLED', 'Confirmation did not match. Nothing changed.');
  return apply(groups, true, deps, env);
}
async function prompt(input, output) {
  const readline = await import('node:readline/promises');
  const rl = readline.createInterface({ input, output, terminal: true });
  try { return await rl.question('> '); } finally { rl.close(); }
}
async function apply(groups, on, deps, env) {
  const before = await readGrants(deps);
  const changed = [];
  for (const group of groups) {
    if (before[group] === on) continue;
    await deps.defaults(['write', BUNDLE_ID, GRANTABLE[group].key, '-bool', on ? 'true' : 'false']);
    changed.push(group);
  }
  const grants = await readGrants(deps);
  const wrong = groups.filter(group => grants[group] !== on);
  if (wrong.length) fail('SETTING_NOT_APPLIED', `The preference for ${wrong.join(', ')} did not change. Open Settings → Agents instead: ${cli(env)} agents open`);
  const running = await appRunning(deps);
  return {
    ok: true, [on ? 'granted' : 'revoked']: groups, changed, unchanged: groups.filter(group => !changed.includes(group)), grants, app_running: running,
    next: running ? `Verify with: ${cli(env)} doctor --json` : `My Man is not running. Start it with ${LAUNCH_COMMAND}, then verify with: ${cli(env)} doctor --json`,
  };
}

// Opens the real Settings → Agents pane. Opening a pane grants nothing.
export async function openSettings({ deps = realDeps, open } = {}) {
  requireDarwin(deps, 'myman agents open');
  const opener = open ?? (url => run('/usr/bin/open', [url]));
  await opener('myman://settings/agents');
  return { ok: true, opened: 'Settings → Agents', next: 'A person turns on the toggles they want; nothing is changed by opening the pane. Then run: ' + cli() + ' doctor --json' };
}

// Symlinks ~/.local/bin/myman to the bundled helper; never overwrites.
export function installCli({ env = process.env, home = homedir(), platform = process.platform } = {}) {
  if (platform !== 'darwin') fail('unsupported_on_platform', 'install-cli is for the macOS app. On Linux the installer places myman in ~/.local/bin.');
  const target = helperPath(env);
  try { accessSync(target, constants.X_OK); } catch { fail('HELPER_NOT_FOUND', `The My Man helper was not found at ${target}. Install My Man in /Applications and open it once.`); }
  const dir = path.join(home, '.local', 'bin'), link = path.join(dir, 'myman');
  let installed = false;
  let existing = null;
  try { existing = lstatSync(link); } catch {}
  if (existing) {
    let same = false;
    try { same = existing.isSymbolicLink() && realpathSync(link) === realpathSync(target); } catch {}
    if (!same) fail('CLI_PATH_CONFLICT', `${link} already exists and is not a link to ${target}. Nothing was changed. Choose another name, for example: ln -s ${quote(target)} ${quote(path.join(dir, 'myman-app'))}`);
  } else {
    mkdirSync(dir, { recursive: true, mode: 0o755 });
    symlinkSync(target, link);
    installed = true;
  }
  const pathEntries = (env.PATH || '').split(path.delimiter);
  const dirOnPath = pathEntries.includes(dir);
  return {
    ok: true, installed, already_installed: !installed, link, target, directory_on_path: dirOnPath,
    ...(dirOnPath ? {} : {
      next: `Add ${dir} to PATH. For zsh (also used by non-interactive SSH commands) run: echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv`,
      path_line: 'export PATH="$HOME/.local/bin:$PATH"',
    }),
  };
}

const groupsIn = message => {
  const found = /enable ([a-z_]+(?: and [a-z_]+|, [a-z_]+)*)/i.exec(message ?? '') ?? /grant ([a-z_]+) access/i.exec(message ?? '');
  return found ? found[1].toLowerCase().split(/ and |, /).map(value => value.trim()) : [];
};

// Linux has no grant command: the person edits their private agents.json by hand.
export function linuxNextSteps(permissions, file = '~/.config/myman/agents.json') {
  const wanted = ['capture', 'markup', 'recording', 'library'].filter(group => !permissions?.[group]);
  if (permissions?.enabled && !wanted.length) return [];
  const grants = ['"enabled": true', ...wanted.map(group => `"${group}": true`)].join(', ');
  return [{ id: 'edit_grants', for: 'person', summary: 'Allow the access you want in your private agents.json', file, edit: `{"version": 1, "grants": {${grants}}}`, note: 'Only a person edits this file (directory mode 700, file mode 600). Keep only the groups you want; an optional /etc/myman/agents.json ceiling must also allow them. There is no command that grants access on Linux.' }];
}

// Copy-pasteable human steps. `state` = { grants, appRunning, processRunning, unreachable, permissions }.
export function nextSteps(state, env = process.env) {
  const steps = [], command = cli(env);
  if (state.appRunning === false) steps.push({ id: 'launch_app', for: 'person_or_agent', summary: 'Launch My Man', run: LAUNCH_COMMAND, note: 'My Man is not running. Launch it, wait a few seconds, then re-run doctor.' });
  if (state.unreachable) steps.push({ id: 'restart_app', for: 'person', summary: 'Restart My Man (it is running but unreachable)', run: `osascript -e 'quit app "My Man"' && sleep 2 && ${LAUNCH_COMMAND}`, note: 'My Man is running but the CLI cannot reach its command socket. Restart the app; if that fails, update My Man.' });
  const grants = state.grants;
  if (grants) {
    if (grants.enabled === false) steps.push({ id: 'enable_commands', for: 'person', summary: 'Turn on "Allow local app commands"', run: `${command} agents open`, note: 'Turn on "Allow local app commands" in Settings → Agents. This master switch cannot be changed from the command line.' });
    for (const group of Object.keys(GRANTABLE)) if (!grants[group]) steps.push({
      id: `grant_${group}`, for: 'person', group, label: GRANTABLE[group].label, summary: `Allow agents to: ${GRANTABLE[group].label.charAt(0).toLowerCase()}${GRANTABLE[group].label.slice(1)} (${group})`,
      run: `${command} agents grant ${group}`, alternative: `${command} agents open (then turn on "${GRANTABLE[group].label}")`,
      note: 'Run in an interactive Terminal on this Mac as the logged-in person; it asks you to type a confirmation. Agents are refused.',
    });
  }
  if (state.permissions?.screen_recording === false) steps.push({ id: 'screen_recording', for: 'person', summary: 'Allow My Man to record the screen in macOS', run: 'open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"', note: 'Allow My Man under Privacy & Security → Screen & System Audio Recording.' });
  if (state.cli && !state.cli.on_path) steps.push({ id: 'install_cli', for: 'person_or_agent', summary: 'Optional: put myman on PATH', run: state.cli.install_command ?? cliInstall(env), note: 'Optional: link myman into ~/.local/bin. The exact path always works.' });
  return steps;
}

// Adds `hint` and friends to an error object without removing anything.
export function annotateError(error, { env = process.env, platform = process.platform } = {}) {
  if (!error || typeof error !== 'object' || error.hint) return error;
  const code = error.code, command = cli(env), extra = {};
  if (code === 'AGENT_DISABLED') {
    const message = String(error.message ?? '');
    const named = groupsIn(message);
    const grantable = named.filter(name => Object.hasOwn(GRANTABLE, name));
    if (platform !== 'darwin') {
      const file = /User file: (\S+?)\.?(?:\s|$)/.exec(message)?.[1] ?? /Check (\S+) and/.exec(message)?.[1] ?? '~/.config/myman/agents.json';
      return { ...error, hint: `Agents cannot enable this. The person at this computer must edit ${file} so "grants" includes "enabled": true and the needed group${named.length ? ` (${named.join(', ')}: true)` : ' (for example "capture": true)'}, then re-run: myman doctor --json. There is no command that grants access on Linux.`, agent_may_self_grant: false, ...(named.length ? { groups: named } : {}) };
    }
    if (/local app actions are disabled/i.test(message)) Object.assign(extra, { human_command: `${command} agents open`, hint: `Agents cannot enable this. A person must turn on "Allow local app commands" in My Man Settings → Agents (open it with: ${command} agents open), then re-run: ${command} doctor --json` });
    else if (grantable.length) {
      const list = grantable.join(' ');
      Object.assign(extra, { groups: grantable, human_command: `${command} agents grant ${list}`, settings_command: `${command} agents open`, hint: `Agents cannot enable this. A person must allow ${list} access: in Terminal on this Mac run \`${command} agents grant ${list}\` (asks for a typed confirmation), or run \`${command} agents open\` and turn on ${grantable.map(name => `"${GRANTABLE[name].label}"`).join(' and ')} in Settings → Agents. Then re-run: ${command} doctor --json` });
    } else Object.assign(extra, { ...(named.length ? { groups: named } : {}), settings_command: `${command} agents open`, hint: `Agents cannot enable this. A person must turn it on in My Man Settings → Agents (open it with: ${command} agents open)${named.length ? `: ${named.join(', ')}` : ''}. Then re-run: ${command} doctor --json` });
    return { ...error, ...extra, agent_may_self_grant: false };
  }
  if (platform !== 'darwin') return error;
  if (code === 'APP_NOT_RUNNING') return { ...error, hint: `My Man is not running (or its command socket is missing). Launch it with: ${LAUNCH_COMMAND} — wait a few seconds, then run: ${command} doctor --json`, launch_command: LAUNCH_COMMAND };
  if (['APP_UNAVAILABLE', 'CONNECTION_TIMEOUT', 'INCOMPLETE_REPLY'].includes(code)) return { ...error, hint: `The CLI could not reach the My Man app. If it is running, restart it (quit, then ${LAUNCH_COMMAND}) and check ${command} doctor --json. Make sure the app and CLI run as the same macOS user.`, launch_command: LAUNCH_COMMAND };
  if (code === 'INVALID_SOCKET') return { ...error, hint: `The My Man command socket has unexpected ownership or permissions, so the CLI refused to use it. Quit My Man and relaunch it with ${LAUNCH_COMMAND} as the same user that runs this CLI.`, launch_command: LAUNCH_COMMAND };
  if (code === 'IDENTITY_REQUIRED') {
    const file = envFilePath(env);
    return {
      ...error,
      hint: `Named agent credentials are required. This is not AGENT_DISABLED (grants). A person must: (1) add an agent in My Man Settings → Agents and copy MYMAN_AGENT_TOKEN / MYMAN_MACHINE_ID, (2) save them with \`${command} agents credentials save\` (writes ${file}, mode 600; asks to type: save credentials), or put the same exports in that file by hand, (3) re-run: ${command} doctor --plain. Agents must not paste tokens into chat. Loading credentials never turns on capture/markup.`,
      human_command: `${command} agents credentials save`,
      settings_command: `${command} agents open`,
      credentials_file: file,
      agent_may_self_grant: false,
    };
  }
  if (code === 'INVALID_CREDENTIAL') {
    const file = envFilePath(env);
    return {
      ...error,
      hint: `The MYMAN_AGENT_TOKEN in the environment or in ${file} is invalid or revoked. A person must issue a new credential in Settings → Agents, update the host env / agent.env (myman agents credentials save), then re-run: ${command} doctor --plain. This is not a grants problem.`,
      human_command: `${command} agents credentials save`,
      settings_command: `${command} agents open`,
      credentials_file: file,
      agent_may_self_grant: false,
    };
  }
  if (code === 'WRONG_MACHINE') {
    return {
      ...error,
      hint: `MYMAN_MACHINE_ID does not match this Mac. Set it to the ID shown in Settings → Agents (or in agent.env), or pass --machine with that ID. Re-run: ${command} machine current --json`,
      settings_command: `${command} agents open`,
      agent_may_self_grant: false,
    };
  }
  return error;
}

export function decorateReply(reply, options) {
  const error = reply?.job?.error;
  return error && typeof error === 'object' && !error.hint ? { ...reply, job: { ...reply.job, error: annotateError(error, options) } } : reply;
}

// Plain-text rendering of the doctor report for a person at a terminal.
export function renderDoctor(report) {
  const out = [], mark = ok => ok ? '✓' : '✗';
  out.push('My Man doctor');
  const version = report.app?.app_version ?? report.app?.version;
  out.push(`  App:        ${report.app?.ok ? 'running and reachable' : `not reachable — ${report.app?.error?.message ?? 'unknown error'}`}${version ? ` (${version})` : ''}`);
  out.push(`  CLI:        ${report.cli?.path}${report.cli?.on_path ? ' (on PATH)' : ' (not on PATH)'}`);
  const grants = report.agent_access?.grants;
  if (grants) {
    out.push(`  Agent access (${report.agent_access.source}):`);
    out.push(`    ${mark(grants.enabled !== false)} Allow local app commands`);
    for (const [group, { label }] of Object.entries(GRANTABLE)) out.push(`    ${mark(grants[group])} ${group.padEnd(9)} ${label}`);
  }
  if (report.app?.permissions) out.push(`  macOS:      screen recording ${mark(report.app.permissions.screen_recording)}, accessibility ${mark(report.app.permissions.accessibility)}`);
  out.push(`  Node:       ${report.node}`);
  const cred = report.credentials ?? report.agent_access?.credentials;
  if (cred) {
    const markKey = key => cred.keys?.[key] && cred.keys[key] !== 'missing' ? '✓' : '✗';
    out.push(`  Credentials:${cred.ready ? ' ready' : ' missing'}${cred.file_exists ? ` (file ${cred.path})` : ' (no agent.env yet)'}`);
    out.push(`    ${markKey('MYMAN_AGENT_TOKEN')} MYMAN_AGENT_TOKEN  ${cred.keys?.MYMAN_AGENT_TOKEN ?? 'missing'}`);
    out.push(`    ${markKey('MYMAN_MACHINE_ID')} MYMAN_MACHINE_ID   ${cred.keys?.MYMAN_MACHINE_ID ?? 'missing'}`);
    if (cred.file_exists && cred.file_mode_ok === false) out.push(`    ✗ file mode ${cred.file_mode} (want 600)`);
  }
  if (report.next_steps?.length) {
    out.push('', 'Next steps (a person runs the grant commands in Terminal; agents cannot turn on access):');
    report.next_steps.forEach((step, index) => {
      out.push(`  ${index + 1}. ${step.summary ?? step.id}`, `       ${step.run}`);
      if (step.alternative) out.push(`       or: ${step.alternative}`);
      if (step.note && !step.group) out.push(`       ${step.note}`);
    });
    if (report.agent_access?.human_command) out.push('', `  To allow everything above in one go (asks you to type a confirmation):`, `       ${report.agent_access.human_command}`);
  } else out.push('', 'Nothing to fix.');
  return out.join('\n');
}
