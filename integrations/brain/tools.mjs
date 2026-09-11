import { z } from 'zod/v4';
import { BrainError, kinds } from './brain.mjs';

const kind = z.enum(kinds).optional();
const limit = z.number().int().min(1).max(50).default(10);
const offset = z.number().int().min(0).max(2 * 1024 * 1024).default(0);

export const tools = {
  status: {
    description: 'Check this computer for the MyMan Brain folder, export counts, local timezone/current time, and scan warnings. Does not return document contents.',
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
  meetings: {
    description: 'Find calls by participant names, title/topic keywords, or start date. Participant filters match exported participant identities, not people merely mentioned in transcripts. Returns actual start/end times and candidates newest first within match strength. Resolve ambiguous calls before using meeting_screenshots; do not silently choose the latest unless requested.',
    schema: z.object({ query: z.string().trim().min(1).max(300).optional(),
      participants: z.array(z.string().trim().min(1).max(200)).max(20).default([]),
      started_after: z.iso.datetime({ offset: true }).optional(), started_before: z.iso.datetime({ offset: true }).optional(), limit, offset }).strict(),
  },
  collect: {
    description: 'Collect evidence across MyMan captures for summaries and theme analysis. Filter any combination of kinds, capture-time range [after,before), keywords or quoted phrases (match=all/any), saved theme name/ID, and pinning. For kinds=[meetings], participants selects actual exported identities; for kinds=[tasks], state selects open/done/all. Returns bounded excerpts and read offsets; follow ALL next_offset pages and read full documents before claiming comprehensive analysis. Theme synthesis belongs to the requesting agent; kinds=[themes] retrieves saved app Themes. No semantic or visual matching: translate descriptors to keywords/synonyms, and broaden retrieval when necessary.',
    schema: z.object({ kinds: z.array(z.enum(kinds)).min(1).max(kinds.length).optional(),
      query: z.string().trim().min(1).max(300).optional(), match: z.enum(['all', 'any']).default('all'),
      after: z.iso.datetime({ offset: true }).optional(), before: z.iso.datetime({ offset: true }).optional(),
      during: z.string().min(1).max(500).optional().describe('Resolved meeting export path; uses its actual start/end instead of after/before, for any capture kinds.'),
      date_field: z.enum(['captured', 'task_completed', 'task_due']).default('captured').describe('Date to filter: original capture/task creation by default, or task completion/due date with kinds=[tasks].'),
      participants: z.array(z.string().trim().min(1).max(200)).max(20).default([]),
      theme: z.string().trim().min(1).max(200).optional(), pinned_only: z.boolean().default(false),
      state: z.enum(['all', 'open', 'done']).default('all'), limit: limit.default(20), offset }).strict(),
  },
  meeting_screenshots: {
    description: 'Retrieve screenshots captured during one resolved call using its actual start (inclusive) and end (exclusive). Returns chronological screenshot export citations, capture times, and original image_path references. Follow every next_offset to retrieve all. No OCR keyword filter or arbitrary recent-item cutoff. Times establish proximity, not subject matter. Requires a completed meeting; never reads image bytes.',
    schema: z.object({ meeting_path: z.string().min(1).max(500), limit: limit.default(50), offset }).strict(),
  },
  read: {
    description: 'Read one MyMan markdown export by source-relative path. Character offsets paginate without losing long transcript lines. Returns file and line citations. Never follows media paths in the content.',
    schema: z.object({ path: z.string().min(1).max(500), offset, max_chars: z.number().int().min(1).max(20000).default(12000) }).strict(),
  },
  image: {
    description: 'Explicitly inspect one original MyMan screenshot for visual descriptors not present in OCR. Requires its source-relative screenshot export path and a current app catalog. Returns original PNG image content (up to 8 MiB), never follows markdown links or arbitrary file arguments. Image content is shared with the requesting model; collect metadata/OCR first and request images only as needed.',
    schema: z.object({ path: z.string().min(1).max(500) }).strict(),
  },
  tasks: {
    description: 'List open, done, or all tasks. With the app catalog, returns complete task exports including notes and dates via read; otherwise uses legacy tasks.md with capped history. This is an export snapshot. Follow next_offset for more.',
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
