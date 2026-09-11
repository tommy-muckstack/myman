import { parseArgs } from 'node:util';
import { Brain, BrainError } from './brain.mjs';
import { execute, errorResult } from './tools.mjs';

try {
  const { values, positionals } = parseArgs({
    allowPositionals: true, strict: true,
    options: { root: { type: 'string' }, help: { type: 'boolean' } },
  });
  if (values.help) {
    console.log('Usage: node cli.mjs [--root /absolute/MyManBrain] <status|search|recent|collect|meetings|meeting_screenshots|read|image|tasks> [JSON arguments]\nExamples: search \'{"query":"budget review"}\' | recent \'{"kind":"meetings"}\' | tasks');
  } else {
    if (positionals.length < 1 || positionals.length > 2) throw new BrainError('INVALID_COMMAND', 'Expected a command and optional JSON arguments; use --help.');
    const args = positionals.length === 2 ? JSON.parse(positionals[1]) : {};
    const result = await execute(new Brain(values.root), positionals[0], args);
    console.log(JSON.stringify(result));
  }
} catch (error) {
  const result = errorResult(error);
  if (error instanceof SyntaxError || error.code?.startsWith('ERR_PARSE_ARGS')) result.error = { code: 'INVALID_COMMAND', message: 'Check command syntax with --help; arguments must be valid JSON.' };
  console.error(JSON.stringify(result));
  process.exitCode = 1;
}
