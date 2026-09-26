// Helps people and agents recover from mistakes: suggests the command or flag
// they probably meant, names the Linux alternative for Mac-only actions, and
// renders plain text for a person at a terminal (JSON stays the default for
// pipes and whenever --json is passed).
export const commands = [
  'doctor', 'actions', 'jobs', 'job', 'invoke', 'screenshot', 'annotate', 'search', 'recent', 'latest', 'collect', 'read', 'image', 'status', 'meetings', 'screenshots', 'tasks',
  'screens list', 'windows list', 'capture ocr', 'capture image', 'capture copy', 'clipboard read', 'clipboard write',
  'record start', 'record stop', 'record cancel', 'record status', 'record result',
  'note create', 'note append', 'note update', 'note attach',
  'library search', 'library recent', 'library read', 'library related', 'library rename', 'library pin', 'library unpin', 'library hide', 'library unhide', 'library delete',
  'task list', 'task add', 'task update', 'task complete', 'task reopen', 'task delete',
];
export const flags = ['json', 'help', 'id', 'query', 'kind', 'limit', 'offset', 'after', 'before', 'title', 'body', 'body-file', 'file', 'display', 'region', 'window-id', 'coordinates', 'ops', 'ops-file',
  'dry-run', 'preview', 'request-id', 'no-wait', 'wait-timeout', 'root', 'offline', 'format', 'text', 'session-id', 'max-duration', 'expected-updated-at', 'expected-revision', 'expected-version',
  'source-id', 'path', 'alt', 'confirm', 'pinned-only', 'lexical-only', 'semantic', 'notes', 'due', 'clear-due', 'state', 'mode'];

function distance(a, b) {
  const row = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let prev = row[0]; row[0] = i;
    for (let j = 1; j <= b.length; j++) { const cur = row[j]; row[j] = Math.min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1)); prev = cur; }
  }
  return row[b.length];
}
export function closest(input, choices, max = 3) {
  const limit = Math.max(1, Math.min(3, Math.floor(input.length / 3)));
  return choices.map(c => [c, distance(input, c)]).filter(([, d]) => d <= limit).sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0])).slice(0, max).map(([c]) => c);
}
const positionals = argv => { const out = []; for (let i = 0; i < argv.length; i++) { if (argv[i].startsWith('-')) { if (!argv[i].includes('=') && argv[i + 1] && !argv[i + 1].startsWith('-') && !['--json', '--help', '--dry-run', '--preview', '--no-wait', '--offline', '--confirm', '--pinned-only', '--lexical-only', '--semantic', '--clear-due'].includes(argv[i])) i++; continue; } out.push(argv[i]); } return out; };
// Returns a suggestion only when the words typed are not a known command.
export function suggestCommand(argv) {
  const p = positionals(argv);
  if (!p.length) return null;
  const pair = p.slice(0, 2).join(' ');
  if (commands.includes(pair) || commands.includes(p[0]) && !commands.some(c => c.startsWith(p[0] + ' '))) return null;
  const typed = commands.some(c => c.startsWith(p[0] + ' ')) ? pair : p[0];
  const pool = typed.includes(' ') ? commands.filter(c => c.includes(' ')) : [...new Set(commands.map(c => c.split(' ')[0]))];
  let hits = closest(typed, pool);
  if (!hits.length && typed.includes(' ')) hits = commands.filter(c => c.startsWith(p[0] + ' ')).slice(0, 6);
  return { typed, suggestions: hits };
}
export function suggestFlag(message) {
  const m = /Unknown option '--([^']+)'/.exec(message || '');
  if (!m) return null;
  return { typed: `--${m[1]}`, suggestions: closest(m[1], flags).map(f => `--${f}`) };
}
// Mac-only actions, and what to do instead on Linux.
const alternatives = [
  [/^item\.open|^note open|^library open|^editor/, 'Read it with myman library read --id ID --json, or open the returned path with your own viewer.'],
  [/^theme/, 'Themes are Mac-only. Search by words with myman library search --query TEXT --json.'],
  [/^recording\.(pause|resume)|^record (pause|resume)/, 'Stop this recording and start another; each take is saved separately.'],
  [/^recording\.(frames|export)|^record (frames|export)/, 'Not on Linux yet. The recording result includes the MP4 path, which ffmpeg can trim or sample.'],
  [/^screenshot\.compare|^capture compare/, 'Not on Linux yet. Capture both images, then compare the returned PNG paths.'],
  [/^screenshot\.targets|^capture targets/, 'Use myman capture ocr --id SHOT-ID --json for line text with pixel boxes.'],
  [/^(meeting|dictation|live-?text)/, 'Meetings, dictation and Live Text are Mac-only. Record video with myman record start, or capture a screenshot and read its text.'],
  [/^(bundle|handoff|lease|agent|collaboration|machine|session)/, 'Named agents and multi-agent sharing are Mac-only. Use notes (myman note create) to hand work to another agent on this machine.'],
  [/^(timer|reminder)/, 'Timers are Mac-only. Use a systemd user timer or your agent host\'s scheduler.'],
  [/^(font|settings|history|app\.open|open)/, 'This is a Mac app feature with no Linux equivalent. See myman actions --json for what Linux supports.'],
];
export function alternativeFor(text) {
  const hit = alternatives.find(([re]) => re.test(text || ''));
  return hit ? hit[1] : 'Run myman actions --json to see what Linux supports (look for "supported": true).';
}

// Plain-text rendering for a person at a terminal.
const scalar = v => v === null || ['string', 'number', 'boolean'].includes(typeof v);
function line(item) {
  const label = item.title || item.name || item.path || item.id || JSON.stringify(item).slice(0, 80);
  const bits = [item.kind, item.id && item.id !== label ? item.id : null, item.created_at || item.timestamp].filter(Boolean).join(', ');
  const why = Array.isArray(item.reasons) && item.reasons.length ? `\n    why: ${item.reasons.join('; ')}` : '';
  const excerpt = typeof item.excerpt === 'string' && item.excerpt ? `\n    ${item.excerpt.replace(/\s+/g, ' ').slice(0, 160)}` : '';
  return `- ${label}${bits ? ` (${bits})` : ''}${why}${excerpt}`;
}
export function human(result) {
  if (result.ok === false || result.error) {
    const e = result.error || {};
    return `Error: ${e.message || 'The command failed.'}\n${e.suggestions?.length ? `Did you mean: ${e.suggestions.join(', ')}?\n` : ''}${e.alternative ? `Instead: ${e.alternative}\n` : ''}(code ${e.code || 'UNKNOWN'}; add --json for the full result)\n`;
  }
  const out = [], skip = new Set(['ok', 'job_id', 'launch_id', 'git', 'attachment', 'source', 'applied', 'body']);
  const list = ['results', 'jobs', 'actions', 'windows', 'displays'].find(k => Array.isArray(result[k]));
  if (result.title) out.push(result.title);
  if (typeof result.alt_text === 'string' && result.alt_text !== result.title) out.push(result.alt_text);
  for (const [k, v] of Object.entries(result)) if (!skip.has(k) && k !== list && k !== 'title' && k !== 'alt_text' && scalar(v) && v !== '') out.push(`${k.replaceAll('_', ' ')}: ${v}`);
  if (typeof result.body === 'string') out.push('', result.body);
  if (list) { out.push('', `${result[list].length} ${list}${result.total > result[list].length ? ` of ${result.total}` : ''}:`); for (const item of result[list].slice(0, 50)) out.push(scalar(item) ? `- ${item}` : line(item)); }
  if (Array.isArray(result.warnings)) for (const w of result.warnings) out.push(`Warning: ${w.message || w.code}`);
  if (result.git?.committed === false) out.push('Warning: saved, but the Git commit failed.');
  return out.join('\n') + '\n';
}
