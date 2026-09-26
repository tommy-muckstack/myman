// Library items on Linux: read, search, edit, append, attach, rename, pin,
// hide and delete notes, screenshots and recordings in MyManBrain.
// Every mutation goes through the catalog and git (never a silent rewrite),
// checks revisions so agents cannot overwrite each other or a human, and keeps
// notes readable: plain Markdown, a title heading, and alt text on images.
import { lstat, readFile, rename as move, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Brain } from '../brain/brain.mjs';
import { atomic, directory, fail, imageCommand, pngSize, readSafe, rootPath, run, unsupported } from './system.mjs';
import { catalogForWrite, gitSave, lockedWrite, titleLine } from './library.mjs';

const prefixes = { notes: 'note', screenshots: 'shot', recordings: 'rec', tasks: 'task', meetings: 'meeting', dictations: 'dictation' };
const singular = { screenshots: 'screenshot', notes: 'note', recordings: 'recording', meetings: 'meeting', dictations: 'dictation', tasks: 'task' };
const kindAlias = { screenshot: 'screenshots', note: 'notes', recording: 'recordings', meeting: 'meetings', dictation: 'dictations' };
const oneLine = (value, max) => String(value ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);

function noLease(args) {
  // Leases belong to named Mac agents. Refuse rather than pretend to hold one.
  if (args.lease_id) unsupported('Leases need named agents, which are unavailable on Linux. Omit --lease-id; revision checks still prevent overwrites.');
}
function matches(entry, id) {
  const bare = id.replace(/^(note|shot|rec|task|meeting|dictation)-/, '');
  return entry.item_id === id || entry.item_id === `${prefixes[entry.kind]}-${bare}`;
}
function locate(catalog, id) {
  const entry = catalog?.exports.find(e => matches(e, id));
  if (entry) return { entry, hidden: false };
  const hidden = catalog?.excluded?.find(e => e && matches(e, id));
  if (hidden) return { entry: hidden, hidden: true };
  fail('UNKNOWN_ITEM', `No library item with ID ${oneLine(id, 120)} exists in this Brain. Find IDs with: myman library search --query TEXT --json`);
}
const revisionOf = entry => Number.isInteger(entry.revision) ? entry.revision : 1;
function checkRevision(entry, expected) {
  if (expected !== undefined && expected !== revisionOf(entry)) fail('EDIT_CONFLICT', `The item changed (revision ${revisionOf(entry)}, you expected ${expected}). Run myman library read --id ${entry.item_id} --json and retry with the new revision.`);
}
function frontMatter(text) {
  const m = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!m) return { fields: {}, rest: text };
  const fields = {};
  for (const line of m[1].split('\n')) { const i = line.indexOf(':'); if (i > 0) fields[line.slice(0, i).trim()] = line.slice(i + 1).trim(); }
  return { fields, rest: text.slice(m[0].length) };
}
// The note body is everything after the title heading, so reads and writes
// round-trip exactly what the agent or person wrote.
function noteBody(rest) {
  const trimmed = rest.replace(/^\n+/, '');
  const m = /^# [^\n]*\n\n?/.exec(trimmed);
  return (m ? trimmed.slice(m[0].length) : trimmed).replace(/\n$/, '');
}
const updatedAt = (entry, fields) => entry.updated_at || fields.updated || entry.timestamp;
function publicItem(entry, root, extra = {}) {
  const { item_id, kind, title, path: brain_path, timestamp, pinned, themes, tags, meetings, revision, ...rest } = entry;
  const keep = ['alt_text', 'app', 'window_title', 'image_path', 'thumbnail_path', 'video_path', 'duration', 'width', 'height', 'ocr_status', 'text_found', 'source_id', 'timezone', 'done', 'due'];
  return { id: item_id, kind: singular[kind] || kind, title, revision: revisionOf(entry), pinned: pinned === true, hidden: false,
    created_at: timestamp, updated_at: entry.updated_at || timestamp, brain_path, path: path.join(root, brain_path),
    ...Object.fromEntries(keep.filter(k => rest[k] !== undefined).map(k => [k, rest[k]])), ...extra };
}

export async function read({ id }) {
  const brain = new Brain(rootPath()), root = await brain.root(), catalog = await brain.catalog();
  const { entry, hidden } = locate(catalog, id);
  if (hidden) return { ...publicItem(entry, root), hidden: true, body: null, note: 'This item is hidden from search and readers. Unhide it with myman library unhide --id ' + entry.item_id + ' --json to read its contents.' };
  const doc = await brain.load(entry.path);
  const { fields, rest } = frontMatter(doc.text);
  const body = ['notes', 'tasks'].includes(entry.kind) ? noteBody(rest) : doc.text;
  return publicItem(entry, root, { updated_at: updatedAt(entry, fields), body, characters: body.length, ...(entry.kind === 'tasks' ? { version: String(revisionOf(entry)), completed_at: entry.completed_at ?? null } : {}), source: brain.source(doc) });
}

// Mutations share one path: lock, reload the catalog, apply, write, commit.
async function mutate(id, apply, message) {
  return lockedWrite(async root => {
    const catalog = await catalogForWrite(root);
    const found = locate(catalog, id);
    const now = new Date().toISOString();
    const out = await apply({ root, catalog, ...found, now });
    catalog.generated_at = now;
    await atomic(path.join(root, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n');
    const git = await gitSave(root, [...new Set([...(out.files ?? []), 'catalog.json'])], message);
    return { ...out.result, git };
  });
}
const bump = (entry, now) => { entry.revision = revisionOf(entry) + 1; entry.updated_at = now; };
function requireVisibleNote(entry, hidden) {
  if (hidden) fail('UNKNOWN_ITEM', 'This note is hidden. Unhide it before editing.');
  if (entry.kind !== 'notes') fail('INVALID_ARGUMENTS', `${entry.item_id} is a ${singular[entry.kind] || entry.kind}, not a note. Only notes have editable bodies.`);
}
async function writeNote(root, entry, body, now) {
  const file = path.join(root, entry.path);
  const { fields } = frontMatter(await readFile(file, 'utf8'));
  const id = fields.id || entry.item_id.replace(/^note-/, ''), created = fields.created || entry.timestamp;
  await atomic(file, `---\nid: ${id}\ncreated: ${created}\nupdated: ${now}\n---\n\n# ${entry.title}\n\n${body}\n`);
}
async function currentNote(root, entry) {
  const { fields, rest } = frontMatter(await readFile(path.join(root, entry.path), 'utf8'));
  return { body: noteBody(rest), updated: updatedAt(entry, fields) };
}
function checkUpdated(entry, current, expected) {
  if (expected !== undefined && Date.parse(expected) !== Date.parse(current)) fail('EDIT_CONFLICT', `The note changed at ${current}, after the ${expected} you read. Read it again with myman library read --id ${entry.item_id} --json, merge, and retry.`);
}

export function noteUpdate(args) {
  noLease(args);
  return mutate(args.id, async ({ root, entry, hidden, now }) => {
    requireVisibleNote(entry, hidden);
    const cur = await currentNote(root, entry);
    checkUpdated(entry, cur.updated, args.expected_updated_at);
    await writeNote(root, entry, args.body, now); bump(entry, now);
    return { files: [entry.path], result: { id: entry.item_id, kind: 'note', title: entry.title, revision: entry.revision, updated_at: now, previous_updated_at: cur.updated, characters: args.body.length, brain_path: entry.path, path: path.join(root, entry.path) } };
  }, 'MyMan Linux: update note');
}
export function noteAppend(args) {
  noLease(args);
  return mutate(args.id, async ({ root, entry, hidden, now }) => {
    requireVisibleNote(entry, hidden);
    const cur = await currentNote(root, entry);
    checkUpdated(entry, cur.updated, args.expected_updated_at);
    const body = cur.body.trim() ? `${cur.body.replace(/\s+$/, '')}\n\n${args.body}` : args.body;
    await writeNote(root, entry, body, now); bump(entry, now);
    return { files: [entry.path], result: { id: entry.item_id, kind: 'note', title: entry.title, revision: entry.revision, updated_at: now, appended_characters: args.body.length, characters: body.length, brain_path: entry.path, path: path.join(root, entry.path) } };
  }, 'MyMan Linux: append to note');
}
export function noteAttach(args) {
  noLease(args);
  if (!!args.source_id === !!args.path) fail('INVALID_ARGUMENTS', 'Pass exactly one of --source-id SHOT-ID or --path /absolute/image.png.');
  if (args.path && !path.isAbsolute(args.path)) fail('INVALID_ARGUMENTS', 'Image paths must be absolute.');
  return mutate(args.id, async ({ root, catalog, entry, hidden, now }) => {
    requireVisibleNote(entry, hidden);
    const cur = await currentNote(root, entry);
    checkUpdated(entry, cur.updated, args.expected_updated_at);
    let sourceFile, defaultAlt, warnings = [];
    if (args.source_id) {
      const { entry: shot, hidden: shotHidden } = locate(catalog, args.source_id);
      if (shotHidden || shot.kind !== 'screenshots') fail('INVALID_ARGUMENTS', 'source_id must be a visible screenshot. Use --path for other images.');
      sourceFile = shot.image_path; defaultAlt = shot.alt_text || shot.title;
    } else {
      const info = await lstat(args.path);
      if (!info.isFile() || info.isSymbolicLink()) fail('UNSAFE_PATH', 'The image must be a regular file, not a link or folder.');
      sourceFile = args.path;
    }
    // Owned copy: deleting or editing the source never breaks the note.
    const noteId = entry.item_id.replace(/^note-/, ''), imageId = randomUUID();
    const relative = `assets/note-images/${noteId}/${imageId}.png`, target = path.join(root, relative);
    await directory(path.dirname(target));
    const temp = path.join(path.dirname(target), `.myman-${imageId}.tmp.png`);
    try { await run(await imageCommand(), [sourceFile + '[0]', '-strip', 'png:' + temp]); await move(temp, target); }
    catch (error) { await rm(temp, { force: true }); if (error.code === 'ENOENT' || error.code === 'EACCES') throw error; fail('INVALID_IMAGE', 'That file could not be read as an image.'); }
    const size = pngSize(await readSafe(target, 128 * 1024 * 1024));
    let alt = oneLine(args.alt, 300);
    if (!alt) {
      alt = oneLine(defaultAlt, 300) || `Image ${path.basename(sourceFile)}, ${size.width}x${size.height} pixels`;
      if (!defaultAlt) warnings.push({ code: 'ALT_TEXT_MISSING', message: 'Pass --alt with a short description so people using screen readers and other agents know what the image shows.' });
    }
    // Name the source screenshot under the image so people and agents can trace it.
    const body = `${cur.body.replace(/\s+$/, '')}\n\n![${alt.replace(/[\[\]]/g, '')}](../${relative})${args.source_id ? `\n\n_Source: ${locate(catalog, args.source_id).entry.item_id}_` : ''}`;
    await writeNote(root, entry, body.replace(/^\n+/, ''), now); bump(entry, now);
    return { files: [entry.path, relative], result: { id: entry.item_id, kind: 'note', title: entry.title, revision: entry.revision, updated_at: now, brain_path: entry.path,
      attachment: { path: target, mime_type: 'image/png', ...size, duration: null, file_size: (await lstat(target)).size, preview_path: null, alt_text: alt }, ...(args.source_id ? { source_id: args.source_id } : {}), ...(warnings.length ? { warnings } : {}) } };
  }, 'MyMan Linux: attach image to note');
}
export function rename(args) {
  noLease(args);
  const title = titleLine(args.title);
  if (!title) fail('INVALID_ARGUMENTS', 'The new title is empty.');
  return mutate(args.id, async ({ root, entry, hidden, now }) => {
    checkRevision(entry, args.expected_revision);
    const previous = entry.title; entry.title = title; bump(entry, now);
    const files = [];
    // Keep the note file's own heading in step so the Markdown reads correctly.
    if (entry.kind === 'notes' && !hidden) { await writeNote(root, entry, (await currentNote(root, entry)).body, now); files.push(entry.path); }
    return { files, result: { id: entry.item_id, kind: singular[entry.kind], title, previous_title: previous, revision: entry.revision, updated_at: now } };
  }, 'MyMan Linux: rename item');
}
export function pin(args) {
  noLease(args);
  return mutate(args.id, async ({ entry, now }) => {
    checkRevision(entry, args.expected_revision);
    const changed = (entry.pinned === true) !== args.pinned;
    if (changed) { entry.pinned = args.pinned; bump(entry, now); }
    return { result: { id: entry.item_id, kind: singular[entry.kind], title: entry.title, pinned: args.pinned, changed, revision: revisionOf(entry) } };
  }, 'MyMan Linux: pin item');
}
export function exclude(args) {
  noLease(args);
  return mutate(args.id, async ({ catalog, entry, hidden, now }) => {
    checkRevision(entry, args.expected_revision);
    const changed = hidden !== args.excluded;
    if (changed) {
      bump(entry, now);
      if (args.excluded) { catalog.exports = catalog.exports.filter(e => e !== entry); (catalog.excluded ??= []).push(entry); }
      else { catalog.excluded = catalog.excluded.filter(e => e !== entry); if (!catalog.excluded.length) delete catalog.excluded; catalog.exports.push(entry); }
    }
    return { result: { id: entry.item_id, kind: singular[entry.kind], title: entry.title, hidden: args.excluded, changed, revision: revisionOf(entry),
      note: args.excluded ? 'Hidden from search, collect, recent and read. The files stay in the Brain; unhide to restore.' : 'Visible again in search and readers.' } };
  }, 'MyMan Linux: hide item');
}
export function remove(args) {
  noLease(args);
  if (args.confirm !== true) fail('CONFIRMATION_REQUIRED', 'Deleting removes the item and its owned media from the Brain. Re-run with --confirm to proceed.');
  return mutate(args.id, async ({ root, catalog, entry, hidden, now }) => {
    checkRevision(entry, args.expected_revision);
    const inside = file => typeof file === 'string' && path.isAbsolute(file) && file.startsWith(root + path.sep + 'assets' + path.sep) && !file.includes(`${path.sep}..${path.sep}`);
    const owned = [entry.image_path, entry.thumbnail_path, entry.video_path].filter(inside);
    const files = [entry.path, ...owned.map(f => path.relative(root, f))];
    if (entry.kind === 'notes') files.push(`assets/note-images/${entry.item_id.replace(/^note-/, '')}`);
    for (const f of files) await rm(path.join(root, f), { recursive: true, force: true });
    if (hidden) { catalog.excluded = catalog.excluded.filter(e => e !== entry); if (!catalog.excluded.length) delete catalog.excluded; }
    else catalog.exports = catalog.exports.filter(e => e !== entry);
    return { files, result: { id: entry.item_id, kind: singular[entry.kind], title: entry.title, deleted: true, removed: files, note: 'Git history still holds earlier versions of committed files. Recordings were never committed.' } };
  }, 'MyMan Linux: delete item');
}

// Search: exact phrase, then all words, then near spellings (one typo in
// words of five letters or more). Semantic search is not available on Linux
// and is refused instead of silently degraded.
const words = value => value.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().match(/[\p{L}\p{N}]+/gu) || [];
function oneEdit(a, b) {
  if (a === b) return true;
  if (Math.abs(a.length - b.length) > 1) return false;
  let i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (++edits > 1) return false;
    if (a.length > b.length) i++; else if (b.length > a.length) j++; else { i++; j++; }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}
function day(value, name) {
  if (value === undefined) return undefined;
  const t = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(value) ? value + 'T00:00:00' : value);
  if (!Number.isFinite(t)) fail('INVALID_ARGUMENTS', `${name} must be an ISO date or time, such as 2026-09-26 or 2026-09-26T14:00:00-04:00.`);
  return t;
}
export async function search(args) {
  if (args.semantic) unsupported('Semantic search is not available on Linux. Drop --semantic to get exact, keyword and near-spelling matches.');
  if (args.theme) unsupported('Themes are not available on Linux yet. Search by words instead.');
  const kind = args.kind && args.kind !== 'all' ? (kindAlias[args.kind] || args.kind) : undefined;
  const after = day(args.after, 'after'), before = day(args.before, 'before');
  const limit = args.limit ?? 20, offset = args.offset ?? 0;
  const brain = new Brain(rootPath()), root = await brain.root(), catalog = await brain.catalog();
  const phrase = words(args.query).join(' '), terms = [...new Set(words(args.query))];
  if (!terms.length) fail('INVALID_ARGUMENTS', 'The query needs at least one letter or number.');
  const { documents, ...scan } = await brain.scan(kind ? [kind] : undefined);
  const entries = new Map(catalog?.exports.map(e => [e.path, e]) ?? []);
  const hits = [];
  for (const doc of documents) {
    const entry = entries.get(doc.path);
    if (!entry) continue;
    if (args.pinned_only && entry.pinned !== true) continue;
    const at = Date.parse(entry.timestamp);
    if (after !== undefined && !(at >= after)) continue;
    if (before !== undefined && !(at < before)) continue;
    const titleWords = words(entry.title || ''), bodyWords = words(doc.text), haystack = [...titleWords, ...bodyWords];
    const joined = ` ${haystack.join(' ')} `, reasons = [];
    let score = 0;
    if (joined.includes(` ${phrase} `)) { reasons.push('exact phrase'); score += 100; }
    const exact = terms.filter(t => haystack.includes(t) || joined.includes(` ${t}`));
    if (exact.length === terms.length) { if (!reasons.length) reasons.push('all words'); score += 50; }
    else if (!args.lexical_only) {
      const near = terms.filter(t => !exact.includes(t) && t.length >= 5 && haystack.some(w => w.length >= 4 && oneEdit(t, w)));
      if (exact.length + near.length < terms.length) continue;
      reasons.push(`near spelling of ${near.map(t => `"${t}"`).join(', ')}`); score += 20;
    } else continue;
    if (terms.some(t => titleWords.includes(t))) { reasons.push('title match'); score += 10; }
    const lines = doc.text.split('\n'), first = exact[0] ?? terms[0];
    const line = Math.max(0, lines.findIndex(l => words(l).some(w => w === first || w.startsWith(first) || oneEdit(first, w))));
    hits.push({ ...publicItem(entry, root), score, reasons, excerpt: oneLine(lines.slice(line, line + 3).join(' '), 300), source: brain.source(doc, line + 1) });
  }
  hits.sort((a, b) => b.score - a.score || (b.created_at || '').localeCompare(a.created_at || ''));
  const page = hits.slice(offset, offset + limit);
  return { query: args.query, results: page, total: hits.length, next_offset: offset + limit < hits.length ? offset + limit : null,
    applied: { kind: kind ?? 'all', after: args.after ?? null, before: args.before ?? null, pinned_only: !!args.pinned_only, lexical_only: !!args.lexical_only, semantic: false },
    hidden_items_omitted: catalog?.excluded?.length ?? 0, partial: scan.partial, ...(scan.warning_count ? { warnings: scan.warnings } : {}) };
}

// Tasks use the Mac export format (task-items/ID.md, kind "tasks"), so the
// unchanged Brain readers (task list, collect) see them. version is the
// revision as a string, matching the Mac's expected_version contract.
function dueInstant(value) {
  const t = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(value) ? value + 'T00:00:00' : value);
  if (!Number.isFinite(t)) fail('INVALID_ARGUMENTS', 'due must be an ISO date or time, such as 2026-10-01 or 2026-10-01T17:00:00-04:00.');
  return new Date(t).toISOString();
}
function taskFile(task, notes) {
  const fields = [`id: ${task.item_id.replace(/^task-/, '')}`, `created: ${task.timestamp}`, `updated: ${task.updated_at || task.timestamp}`, 'source: agent', `done: ${task.done === true}`,
    ...(task.due ? [`due: ${task.due}`] : []), ...(task.completed_at ? [`completed: ${task.completed_at}`] : [])];
  return `---\n${fields.join('\n')}\n---\n\n# ${task.title}\n\n${notes}\n`;
}
function taskResult(task, root, notes) {
  return { id: task.item_id, kind: 'task', title: task.title, done: task.done === true, due: task.due ?? null, completed_at: task.completed_at ?? null,
    notes, version: String(revisionOf(task)), created_at: task.timestamp, updated_at: task.updated_at || task.timestamp, brain_path: task.path, path: path.join(root, task.path) };
}
function checkVersion(task, expected) {
  if (expected !== undefined && expected !== String(revisionOf(task))) fail('EDIT_CONFLICT', `The task changed (version ${revisionOf(task)}, you expected ${expected}). Run myman library read --id ${task.item_id} --json and retry with the new version.`);
}
export function taskCreate(args) {
  const title = titleLine(args.title);
  if (!title) fail('INVALID_ARGUMENTS', 'The task title is empty.');
  return lockedWrite(async root => {
    const id = randomUUID(), now = new Date().toISOString(), catalog = await catalogForWrite(root);
    const task = { item_id: `task-${id}`, revision: 1, path: `task-items/${id}.md`, kind: 'tasks', title, timestamp: now, updated_at: now, done: false, themes: [], pinned: false, ...(args.due ? { due: dueInstant(args.due) } : {}) };
    const notes = args.notes ?? '';
    await atomic(path.join(root, task.path), taskFile(task, notes));
    catalog.exports.push(task); catalog.generated_at = now;
    await atomic(path.join(root, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n');
    return { ...taskResult(task, root, notes), git: await gitSave(root, [task.path, 'catalog.json'], 'MyMan Linux: add task') };
  });
}
async function taskNotes(root, task) { return noteBody(frontMatter(await readFile(path.join(root, task.path), 'utf8')).rest); }
export function taskUpdate(args) {
  noLease(args);
  if (args.due && args.clear_due) fail('INVALID_ARGUMENTS', 'Pass --due or --clear-due, not both.');
  if (!['title', 'notes', 'done', 'due', 'clear_due'].some(k => args[k] !== undefined)) fail('INVALID_ARGUMENTS', 'Nothing to change. Pass --title, --notes, --due, --clear-due, or use task complete / task reopen.');
  return mutate(args.id, async ({ root, entry: task, hidden, now }) => {
    if (task.kind !== 'tasks') fail('INVALID_ARGUMENTS', `${task.item_id} is not a task.`);
    if (hidden) fail('UNKNOWN_ITEM', 'This task is hidden. Unhide it before editing.');
    checkVersion(task, args.expected_version);
    const notes = args.notes ?? await taskNotes(root, task), changed = [];
    if (args.title !== undefined) { const t = titleLine(args.title); if (!t) fail('INVALID_ARGUMENTS', 'The task title is empty.'); if (t !== task.title) { task.title = t; changed.push('title'); } }
    if (args.notes !== undefined) changed.push('notes');
    if (args.due) { task.due = dueInstant(args.due); changed.push('due'); }
    if (args.clear_due && task.due) { delete task.due; changed.push('due'); }
    if (args.done !== undefined && args.done !== (task.done === true)) { task.done = args.done; if (args.done) task.completed_at = now; else delete task.completed_at; changed.push('done'); }
    if (changed.length) { bump(task, now); await atomic(path.join(root, task.path), taskFile(task, notes)); }
    return { files: [task.path], result: { ...taskResult(task, root, notes), changed } };
  }, 'MyMan Linux: update task');
}
export function taskDelete(args) {
  noLease(args);
  if (args.confirm !== true) fail('CONFIRMATION_REQUIRED', 'Deleting a task cannot be undone from MyMan. Re-run with --confirm to proceed.');
  return mutate(args.id, async ({ root, catalog, entry: task, hidden }) => {
    if (task.kind !== 'tasks') fail('INVALID_ARGUMENTS', `${task.item_id} is not a task. Use library delete for other items.`);
    checkVersion(task, args.expected_version);
    await rm(path.join(root, task.path), { force: true });
    if (hidden) catalog.excluded = catalog.excluded.filter(e => e !== task); else catalog.exports = catalog.exports.filter(e => e !== task);
    return { files: [task.path], result: { id: task.item_id, kind: 'task', title: task.title, deleted: true } };
  }, 'MyMan Linux: delete task');
}

// Related items, with a plain reason for every match: direct links (a
// marked-up copy and its source, a note that embeds a screenshot), the same
// window, captured close together, and shared title words.
const stop = new Set(['the', 'and', 'for', 'with', 'from', 'this', 'that', 'screenshot', 'recording', 'note', 'window', 'marked', 'copy', 'pixels']);
const titleTerms = value => new Set(words(value || '').filter(w => w.length >= 3 && !stop.has(w) && !/^\d+x?\d*$/.test(w)));
export async function related({ id }) {
  const brain = new Brain(rootPath()), root = await brain.root(), catalog = await brain.catalog();
  const { entry: self, hidden } = locate(catalog, id);
  if (hidden) fail('UNKNOWN_ITEM', 'This item is hidden. Unhide it to find related items.');
  const bare = e => e.item_id.replace(/^[a-z]+-/, '');
  const text = async e => { try { return (await brain.load(e.path)).text; } catch { return ''; } };
  const selfText = await text(self), selfTerms = titleTerms(self.title), selfAt = Date.parse(self.timestamp);
  const out = [];
  for (const other of catalog.exports) {
    if (other === self) continue;
    const reasons = []; let score = 0;
    if (other.source_id && matches(self, other.source_id)) { reasons.push('marked-up copy of this item'); score += 0.9; }
    if (self.source_id && matches(other, self.source_id)) { reasons.push('source of this marked-up copy'); score += 0.9; }
    if (other.kind === 'notes' || self.kind === 'notes') {
      const [note, item] = other.kind === 'notes' ? [other, self] : [self, other];
      const body = note === self ? selfText : await text(note);
      if (item.kind === 'screenshots' && body.includes(bare(item))) { reasons.push(note === self ? 'embedded in this note' : 'note that embeds this item'); score += 0.8; }
    }
    if (self.app && other.app && self.app === other.app && self.window_title && self.window_title === other.window_title) { reasons.push(`same window (${self.app})`); score += 0.3; }
    const minutes = Math.abs(Date.parse(other.timestamp) - selfAt) / 60000;
    if (Number.isFinite(minutes) && minutes <= 10) { reasons.push(`captured ${minutes < 1 ? 'within a minute' : `${Math.round(minutes)} min apart`}`); score += 0.2 * (1 - minutes / 10); }
    const shared = [...titleTerms(other.title)].filter(w => selfTerms.has(w));
    if (shared.length) { reasons.push(`shared title words: ${shared.slice(0, 5).join(', ')}`); score += Math.min(0.4, 0.15 * shared.length); }
    if (reasons.length) out.push({ ...publicItem(other, root), score: Math.round(Math.min(1, score) * 100) / 100, reasons });
  }
  out.sort((a, b) => b.score - a.score || (b.created_at || '').localeCompare(a.created_at || ''));
  return { id: self.item_id, title: self.title, results: out.slice(0, 20), total: out.length, method: 'Links, same window, capture time and title words. No visual or semantic similarity on Linux.' };
}
