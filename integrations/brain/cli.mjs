import { parseArgs } from 'node:util';
import { Brain, BrainError } from './brain.mjs';
import { execute, errorResult } from './tools.mjs';

try {
  const { values, positionals } = parseArgs({
    allowPositionals: true, strict: true,
    options: { root: { type: 'string' }, help: { type: 'boolean' }, meeting: { type: 'string' }, participant: { type: 'string', multiple: true }, after: { type: 'string' }, before: { type: 'string' }, app: { type: 'string' }, tag: { type: 'string', multiple: true }, 'exclude-tag': { type: 'string', multiple: true }, unique: { type: 'boolean' }, query: { type: 'string' }, limit: { type: 'string' }, offset: { type: 'string' } },
  });
  if (values.help) {
    console.log('Screenshots: screenshots --meeting "Jared demo" --exclude-tag slide-deck --unique | screenshots --after <ISO with offset> --before <ISO with offset> --app Chrome --tag web-app');
    console.log('Usage: node cli.mjs [--root /absolute/MyManBrain] <status|search|recent|collect|meetings|recordings|notes|dictations|themes|screenshots|meeting_screenshots|read|image|tasks> [JSON arguments]\nExamples: search \'{"query":"budget review"}\' | recent \'{"kind":"meetings"}\' | tasks');
  } else {
    if (positionals.length < 1 || positionals.length > 2) throw new BrainError('INVALID_COMMAND', 'Expected a command and optional JSON arguments; use --help.');
    const args = positionals.length === 2 ? JSON.parse(positionals[1]) : {};
    const flags = Object.fromEntries(Object.entries(values).filter(([key]) => !['root', 'help'].includes(key)).map(([key, value]) => [key === 'tag' ? 'tags' : key === 'exclude-tag' ? 'exclude_tags' : key === 'participant' ? 'participants' : key, ['limit', 'offset'].includes(key) ? Number(value) : value]));
    if (positionals[0] === 'meetings') {
      if (flags.after) { flags.started_after = flags.after; delete flags.after; }
      if (flags.before) { flags.started_before = flags.before; delete flags.before; }
    }
    if (Object.keys(flags).some(key => Object.hasOwn(args, key))) throw new BrainError('INVALID_COMMAND', 'Do not supply the same argument as both a flag and JSON.');
    const aliases = ['notes', 'recordings', 'dictations', 'themes'];
    const alias = aliases.includes(positionals[0]);
    if (alias && (Object.hasOwn(args, 'kinds') || Object.hasOwn(args, 'kind'))) throw new BrainError('INVALID_COMMAND', 'The command already selects the content type.');
    const result = await execute(new Brain(values.root), alias ? 'collect' : positionals[0], { ...args, ...flags, ...(alias ? { kinds: [positionals[0]] } : {}) });
    console.log(JSON.stringify(result));
  }
} catch (error) {
  const result = errorResult(error);
  if (error instanceof SyntaxError || error.code?.startsWith('ERR_PARSE_ARGS')) result.error = { code: 'INVALID_COMMAND', message: 'Check command syntax with --help; arguments must be valid JSON.' };
  console.error(JSON.stringify(result));
  process.exitCode = 1;
}
