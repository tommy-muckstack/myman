import { z } from 'zod/v4';
import { BrainError, kinds } from './brain.mjs';

const kind = z.enum(kinds).optional();
const limit = z.number().int().min(1).max(50).default(10);
const offset = z.number().int().min(0).max(2 * 1024 * 1024).default(0);

export const tools = {
  status: {
    description: 'Check this computer for the MyMan Brain folder, export counts, and scan warnings. Does not return document contents.',
    schema: z.object({}).strict(),
  },
  search: {
    description: 'Search local MyMan markdown exports using case-insensitive keywords; all terms must occur. Returns bounded excerpts and source citations. Use read for full evidence; this is not semantic search.',
    schema: z.object({ query: z.string().trim().min(1).max(300), kind, limit }).strict(),
  },
  recent: {
    description: 'List recent MyMan exports by capture timestamp, falling back to export modification time when absent. Filter kind=meetings for recent meetings; follow next_offset for more.',
    schema: z.object({ kind, limit, offset }).strict(),
  },
  read: {
    description: 'Read one MyMan markdown export by source-relative path. Character offsets paginate without losing long transcript lines. Returns file and line citations. Never follows media paths in the content.',
    schema: z.object({ path: z.string().min(1).max(500), offset, max_chars: z.number().int().min(1).max(20000).default(12000) }).strict(),
  },
  tasks: {
    description: 'List open, done, or all tasks from MyMan’s exported tasks.md. This is a snapshot, not live database access. Missing export is an error; no tasks is an empty list. Follow next_offset for more.',
    schema: z.object({ state: z.enum(['open', 'done', 'all']).default('open'), limit: limit.default(30), offset }).strict(),
  },
};

export async function execute(brain, name, args = {}) {
  if (!Object.hasOwn(tools, name)) throw new BrainError('UNKNOWN_TOOL', 'Unknown MyMan Brain command.');
  const parsed = tools[name].schema.safeParse(args);
  if (!parsed.success) throw new BrainError('INVALID_ARGUMENTS', parsed.error.issues.map(issue => `${issue.path.join('.') || 'arguments'}: ${issue.message}`).join('; '));
  return brain[name](parsed.data);
}

export function errorResult(error) {
  return error instanceof BrainError
    ? { error: { code: error.code, message: error.message } }
    : { error: { code: 'INTERNAL_ERROR', message: 'The Brain request failed. Check local setup and retry.' } };
}
