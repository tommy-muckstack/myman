import { ensureAgentEnv } from './agent-credentials.mjs';
ensureAgentEnv();
import { z } from 'zod/v4';
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { invoke } from './actions.mjs';
import { unwrap } from './app-cli.mjs';
import { errorResult } from './tools.mjs';

// The server a Paper doc calls to record a walkthrough. It only forwards to the running app's
// narration actions, so the app's grants and in-app approval apply to every call.
// Narration files are readable only in chunks, and only for takes stopped in this session.
const server = new McpServer({ name: 'myman', version: '1.0.0' }, {
  instructions: 'Records a narration (camera and microphone) for a walkthrough. Call narration_start, poll narration_status, call narration_stop, then read the file with narration_chunk. The app shows a control panel and approval prompts; the person can stop from there too.',
});

const readOnly = { readOnlyHint: true, destructiveHint: false, openWorldHint: false };
const writes = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

function result(data) {
  return { content: [{ type: 'text', text: JSON.stringify(data) }], structuredContent: data };
}

const safe = fn => async args => {
  try { return result(await fn(args)); }
  catch (error) { return { isError: true, content: [{ type: 'text', text: JSON.stringify(errorResult(error)) }] }; }
};

server.registerTool('narration_start', {
  description: 'Start a narration take. Counts down 3-2-1 in the app, then records. Returns id and startedAtEpochMs.',
  inputSchema: z.object({ label: z.string().max(80).regex(/^[A-Za-z0-9._-]{1,80}$/).optional().describe('Doc section id this take belongs to.') }).strict(),
  annotations: writes,
}, safe(async args => unwrap(await invoke('narration.start', args, { waitMs: 60000 }))));

server.registerTool('narration_status', {
  description: 'State (idle, countingDown, recording, paused, finishing), elapsedMs and startedAtEpochMs of the current take.',
  inputSchema: z.object({}).strict(),
  annotations: readOnly,
}, safe(async () => unwrap(await invoke('narration.status', {}, { waitMs: 10000 }))));

server.registerTool('narration_stop', {
  description: 'Stop and save the take. Returns id, durationMs, startedAtEpochMs, bytes, mimeType, chunkCount, chunkBytes and sha256.',
  inputSchema: z.object({}).strict(),
  annotations: writes,
}, safe(async () => unwrap(await invoke('narration.stop', {}, { waitMs: 120000 }))));

server.registerTool('narration_chunk', {
  description: 'Read one 256 KB piece of a stopped take, base64 encoded. Use index from 0 to chunkCount minus 1 and join the pieces in order.',
  inputSchema: z.object({ id: z.string().uuid(), index: z.number().int().min(0) }).strict(),
  annotations: readOnly,
}, safe(async args => unwrap(await invoke('narration.chunk', args, { waitMs: 15000 }))));

server.registerTool('narration_discard', {
  description: 'Delete a take that was stopped in this session.',
  inputSchema: z.object({ id: z.string().uuid() }).strict(),
  annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
}, safe(async args => unwrap(await invoke('narration.discard', args, { waitMs: 15000 }))));

await server.connect(new StdioServerTransport());
