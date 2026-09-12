import { constants } from 'node:fs';
import { lstat, realpath, open, opendir } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

export const folders = ['meetings', 'notes', 'recordings', 'screenshots', 'dictations', 'task-items', 'themes'];
export const singletons = ['tasks.md', 'people.md', 'vocabulary.md'];
export const kinds = [...folders.filter(f => f !== 'task-items'), 'tasks', 'people', 'vocabulary'];
export const limits = { fileBytes: 2 * 1024 * 1024, catalogBytes: 8 * 1024 * 1024, scanBytes: 64 * 1024 * 1024, entries: 10000 };

export class BrainError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function allowed(relative) {
  if (typeof relative !== 'string' || /[\\\x00-\x1f]/.test(relative)) return false;
  const parts = relative.split('/');
  if (parts.some(p => !p || p === '.' || p === '..' || p.startsWith('.'))) return false;
  return singletons.includes(relative) || (parts.length === 2 && folders.includes(parts[0]) && parts[1].endsWith('.md'));
}

function kindForPath(relative) { return relative.startsWith('task-items/') ? 'tasks' : relative.includes('/') ? relative.split('/')[0] : relative.replace('.md', ''); }

function metadata(text, relative, stat) {
  const lines = text.split('\n');
  const fields = {};
  const participants = [];
  // Read only MyMan's scalar fields, not arbitrary YAML tags or file references.
  if (lines[0] === '---') {
    const end = lines.indexOf('---', 1);
    let inParticipants = false;
    if (end > 0) for (const line of lines.slice(1, end)) {
      if (/^participants:\s*$/.test(line)) { inParticipants = true; continue; }
      if (inParticipants && /^  - /.test(line)) { participants.push(line.slice(4).trim().slice(0, 300)); continue; }
      if (/^\S/.test(line)) inParticipants = false;
      const match = /^(id|started|created|updated|captured|ended|completed|due|low_content|file):\s*(.*)$/.exec(line);
      if (match) fields[match[1]] = match[2].slice(0, match[1] === 'file' ? 4096 : 200);
    }
  }
  const candidate = fields.started || fields.created || fields.captured;
  const timestamp = instant(candidate);
  return {
    path: relative, id: fields.id || null,
    kind: kindForPath(relative),
    title: (lines.find(line => line.startsWith('# '))?.slice(2) || path.basename(relative, '.md')).slice(0, 300),
    timestamp, exported_at: stat.mtime.toISOString(),
    low_content: fields.low_content === 'true',
    ...(relative.startsWith('task-items/') ? { completed_at: instant(fields.completed), due_at: instant(fields.due) } : {}),
    ...(relative.startsWith('meetings/') ? { started_at: instant(fields.started), ended_at: instant(fields.ended), participants } : {}),
    // Metadata only. Never open, resolve, or execute a path supplied by an export.
    ...(relative.startsWith('screenshots/') ? { captured_at: instant(fields.captured), image_path: fields.file || null } : {}),
  };
}

function instant(value) {
  // A date without an offset depends on the agent computer's timezone. Never
  // use it, a filename, or export mtime to associate captures with a call.
  if (!value || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
  const date = new Date(value);
  const day = new Date(value.slice(0, 10) + 'T00:00:00Z');
  return Number.isFinite(date.getTime()) && Number.isFinite(day.getTime()) && day.toISOString().startsWith(value.slice(0, 10)) ? date.toISOString() : null;
}

function words(value) { return value.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().match(/[\p{L}\p{N}]+/gu) || []; }
function hasName(label, name) { return (' ' + words(label).join(' ') + ' ').includes(' ' + words(name).join(' ') + ' '); }

export class Brain {
  constructor(root = process.env.MYMAN_BRAIN_ROOT || path.join(homedir(), 'MyManBrain')) {
    if (!path.isAbsolute(root)) throw new BrainError('INVALID_ROOT', 'Brain root must be an absolute path.');
    this.configuredRoot = root;
  }

  async root() {
    try {
      const stat = await lstat(this.configuredRoot);
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new BrainError('INVALID_ROOT', 'Brain root must be a real directory, not a symlink.');
      return await realpath(this.configuredRoot);
    } catch (error) {
      if (error.code === 'ENOENT') throw new BrainError('BRAIN_NOT_FOUND', 'MyManBrain is missing on this computer. Run MyMan on the Mac, or configure MYMAN_BRAIN_ROOT.');
      if (error instanceof BrainError) throw error;
      throw new BrainError('ROOT_UNREADABLE', 'Cannot access the configured Brain folder.');
    }
  }

  async loadFile(relative) {
    if (!allowed(relative) && relative !== 'catalog.json') throw new BrainError('INVALID_PATH', 'Use a source-relative markdown path returned by search or collect.');
    const root = await this.root();
    const absolute = path.join(root, relative);
    let handle;
    try {
      const parent = path.dirname(absolute);
      if ((await realpath(parent)) !== parent || (await lstat(parent)).isSymbolicLink()) {
        throw new BrainError('UNSAFE_PATH', 'Linked export directories are not readable.');
      }
      handle = await open(absolute, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1) throw new BrainError('UNSAFE_PATH', 'Only regular, unlinked export files are readable.');
      const maxBytes = relative === 'catalog.json' ? limits.catalogBytes : limits.fileBytes;
      if (stat.size > maxBytes) throw new BrainError('FILE_TOO_LARGE', 'Export exceeds the document or catalog size limit.');
      // Cap the read even if the file grows after stat(). O_NOFOLLOW protects the
      // final component; canonical parent checks reject linked export folders.
      const buffer = Buffer.alloc(Math.min(stat.size + 1, maxBytes + 1));
      let length = 0;
      while (length < buffer.length) {
        const { bytesRead } = await handle.read(buffer, length, buffer.length - length, null);
        if (!bytesRead) break;
        length += bytesRead;
      }
      if (length > maxBytes) throw new BrainError('FILE_TOO_LARGE', 'Export exceeds the document or catalog size limit.');
      const after = await handle.stat();
      const current = await lstat(absolute);
      if (await realpath(parent) !== parent || current.isSymbolicLink() || current.ino !== stat.ino || current.dev !== stat.dev || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) {
        throw new BrainError('EXPORT_CHANGED', 'Export changed while reading; retry the request.');
      }
      let text;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, length)).replace(/\r\n/g, '\n'); }
      catch { throw new BrainError('INVALID_TEXT', 'Export is not valid UTF-8.'); }
      if (text.includes('\0')) throw new BrainError('INVALID_TEXT', 'Export contains binary content.');
      return { ...metadata(text, relative, stat), text, bytes: length, absolute };
    } catch (error) {
      if (error instanceof BrainError) throw error;
      const code = error.code === 'ENOENT' ? 'DOCUMENT_NOT_FOUND' : error.code === 'ELOOP' ? 'UNSAFE_PATH' : 'DOCUMENT_UNREADABLE';
      throw new BrainError(code, 'Cannot read this Brain export. It may be absent, linked, or inaccessible.');
    } finally { await handle?.close(); }
  }

  async catalog() {
    let doc;
    try { doc = await this.loadFile('catalog.json'); }
    catch (error) { if (error.code === 'DOCUMENT_NOT_FOUND') return null; throw error; }
    let data;
    try { data = JSON.parse(doc.text); } catch { throw new BrainError('INVALID_CATALOG', 'The app catalog is invalid. Reopen MyMan to refresh it.'); }
    if (data?.version !== 1 || !Array.isArray(data.exports) || data.exports.some(e => !e || !allowed(e.path) || e.kind !== kindForPath(e.path)) || new Set(data.exports.map(e => e.path)).size !== data.exports.length) {
      throw new BrainError('INVALID_CATALOG', 'The app catalog format is unsupported. Update MyMan and the companion.');
    }
    return { ...data, revision: createHash('sha256').update(doc.text).digest('hex') };
  }

  async load(relative) {
    if (!allowed(relative)) throw new BrainError('INVALID_PATH', 'Use a source-relative markdown path returned by search or collect.');
    const catalog = await this.catalog();
    const entry = catalog?.exports.find(e => e.path === relative);
    if (catalog && !singletons.includes(relative) && !entry) throw new BrainError('DOCUMENT_NOT_FOUND', 'This item is absent or excluded from the current app catalog.');
    const doc = await this.loadFile(relative);
    if ((await this.catalog())?.revision !== catalog?.revision) throw new BrainError('EXPORT_CHANGED', 'App catalog changed while reading; retry.');
    return this.enrich(doc, entry);
  }

  enrich(doc, entry) {
    if (!entry) return doc;
    return { ...doc, title: typeof entry.title === 'string' ? entry.title.slice(0, 300) : doc.title,
      timestamp: instant(entry.timestamp) || doc.timestamp, pinned: entry.pinned === true,
      themes: Array.isArray(entry.themes) ? entry.themes.filter(t => typeof t.id === 'string' && typeof t.title === 'string') : [],
      ...(doc.kind === 'screenshots' && typeof entry.image_path === 'string' ? { image_path: entry.image_path } : {}),
      ...(doc.kind === 'tasks' ? { done: entry.done === true } : {}),
      ...Object.fromEntries(['captured_local', 'timezone', 'timezone_source', 'app', 'bundle_id', 'window_title', 'url', 'summary', 'thumbnail_path', 'contains_pii', 'contains_confidential', 'similar_to', 'sequence_id'].filter(key => typeof entry[key] === 'string').map(key => [key, entry[key]])),
      meetings: Array.isArray(entry.meetings) ? entry.meetings.filter(m => m && typeof m.id === 'string' && typeof m.path === 'string' && allowed(m.path)) : [],
      screenshots: Array.isArray(entry.screenshots) ? entry.screenshots.filter(p => typeof p === 'string' && p.startsWith('screenshots/') && allowed(p)) : [],
      tags: Array.isArray(entry.tags) ? entry.tags.filter(t => t && typeof t.name === 'string' && typeof t.confidence === 'number' && t.confidence >= 0 && t.confidence <= 1) : [],
    };
  }

  async scan(selectedKinds = kinds, catalogFilter = () => true) {
    const root = await this.root();
    const catalog = await this.catalog();
    const entries = new Map(catalog?.exports.map(e => [e.path, e]) || []);
    const paths = singletons.filter(file => selectedKinds.includes(file.replace('.md', '')) && !(catalog && file === 'tasks.md'));
    if (catalog) paths.push(...catalog.exports.filter(e => selectedKinds.includes(e.kind) && catalogFilter(e)).map(e => e.path));
    const warnings = [];
    let inspected = 0;
    for (const folder of (catalog ? [] : folders.filter(folder => selectedKinds.includes(folder === 'task-items' ? 'tasks' : folder)))) {
      const absolute = path.join(root, folder);
      try {
        const stat = await lstat(absolute);
        if (!stat.isDirectory() || stat.isSymbolicLink() || await realpath(absolute) !== absolute) {
          warnings.push({ path: folder, code: 'UNSAFE_PATH' }); continue;
        }
        for await (const entry of await opendir(absolute)) {
          if (++inspected > limits.entries) break;
          if (entry.name.startsWith('.') || !entry.name.endsWith('.md')) continue;
          if (!entry.isFile()) { warnings.push({ path: folder + '/' + entry.name, code: 'UNSAFE_PATH' }); continue; }
          paths.push(folder + '/' + entry.name);
        }
      } catch (error) {
        if (error.code !== 'ENOENT') warnings.push({ path: folder, code: 'DIRECTORY_UNREADABLE' });
      }
      if (inspected > limits.entries) { warnings.push({ code: 'SCAN_ENTRY_LIMIT' }); break; }
    }
    const documents = [];
    let bytes = 0;
    for (const relative of paths.sort()) {
      if (documents.length >= limits.entries) { warnings.push({ code: 'SCAN_ENTRY_LIMIT' }); break; }
      try {
        const doc = this.enrich(await this.loadFile(relative), entries.get(relative));
        bytes += doc.bytes;
        if (bytes > limits.scanBytes) { warnings.push({ code: 'SCAN_BYTE_LIMIT' }); break; }
        documents.push(doc);
      } catch (error) {
        if (error.code !== 'DOCUMENT_NOT_FOUND' || !singletons.includes(relative)) warnings.push({ path: relative, code: error.code });
      }
    }
    if ((await this.catalog())?.revision !== catalog?.revision) throw new BrainError('EXPORT_CHANGED', 'App catalog changed during the scan; retry from the first page.');
    return { documents, warnings: warnings.slice(0, 100), warning_count: warnings.length, partial: warnings.length > 0,
      snapshot: catalog?.revision || null,
      catalog_available: !!catalog, catalog_updated_at: catalog?.generated_at || null };
  }

  source(doc, startLine = 1, endLine = startLine) {
    return { path: doc.path, uri: pathToFileURL(doc.absolute).href, start_line: startLine, end_line: endLine };
  }

  summary(doc) {
    const { text, bytes, absolute, ...summary } = doc;
    return { ...summary, source: this.source(doc) };
  }

  async status() {
    const { documents, ...scan } = await this.scan();
    const counts = Object.fromEntries(kinds.map(kind => [kind, documents.filter(d => d.kind === kind).length]));
    return { companion_version: '0.6.0', root: await this.root(), read_only: true, counts, ...scan, limits,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, current_time: new Date().toISOString() };
  }

  async search({ query, kind, limit = 10 }) {
    const terms = [...new Set(query.toLowerCase().match(/[\p{L}\p{N}]+/gu) || [])];
    if (!terms.length || terms.length > 20) throw new BrainError('INVALID_QUERY', 'Use between 1 and 20 search terms.');
    const { documents, ...scan } = await this.scan();
    const results = [];
    for (const doc of documents) {
      if (kind && doc.kind !== kind) continue;
      const text = doc.text.toLowerCase();
      if (!terms.every(term => text.includes(term))) continue;
      const score = terms.reduce((sum, term) => sum + (doc.title.toLowerCase().includes(term) ? 10 : 1), 0);
      // Case folding can change string length (e.g. İ). Find the matching
      // original line so excerpt offsets still address the unmodified text.
      const lines = doc.text.split('\n');
      const lineIndex = lines.findIndex(line => line.toLowerCase().includes(terms[0]));
      const offset = lines.slice(0, lineIndex).reduce((sum, line) => sum + line.length + 1, 0);
      const line = lineIndex + 1;
      results.push({ ...this.summary(doc), score, excerpt: doc.text.slice(offset, offset + 500), read_offset: offset,
        source: this.source(doc, line, line + doc.text.slice(offset, offset + 500).split('\n').length - 1) });
    }
    const priority = { meetings: 4, notes: 3, recordings: 2, screenshots: 1 };
    results.sort((a, b) => b.score - a.score || (priority[b.kind] || 0) - (priority[a.kind] || 0) || (b.timestamp || '').localeCompare(a.timestamp || '') || a.path.localeCompare(b.path));
    return { results: results.slice(0, limit), total_matches: results.length, truncated: results.length > limit, ...scan };
  }

  async recent({ kind, limit = 10, offset = 0 }) {
    const { documents, ...scan } = await this.scan();
    const matches = documents.filter(d => !kind || d.kind === kind).sort((a, b) => (b.timestamp || b.exported_at).localeCompare(a.timestamp || a.exported_at) || a.path.localeCompare(b.path));
    return { results: matches.slice(offset, offset + limit).map(d => this.summary(d)), total: matches.length,
      next_offset: offset + limit < matches.length ? offset + limit : null, ...scan };
  }

  async collect({ kinds: selectedKinds = kinds, query, match = 'all', after, before, during, date_field = 'captured', participants = [], theme, pinned_only = false, state = 'all', app, tags = [], exclude_tags = [], unique = false, limit = 20, offset = 0 }) {
    if (date_field !== 'captured' && (selectedKinds.length !== 1 || selectedKinds[0] !== 'tasks' || during)) throw new BrainError('INVALID_ARGUMENTS', 'Task date fields require kinds=["tasks"] and explicit date bounds rather than during.');
    let anchor;
    if (during) {
      if (after || before) throw new BrainError('INVALID_ARGUMENTS', 'Use either during or explicit after/before bounds.');
      anchor = await this.load(during);
      if (anchor.kind !== 'meetings' || !anchor.started_at || !anchor.ended_at || anchor.ended_at <= anchor.started_at) throw new BrainError('MEETING_INTERVAL_UNAVAILABLE', 'during requires a completed meeting with a valid start/end interval.');
      after = anchor.started_at; before = anchor.ended_at;
    }
    if (after && before && Date.parse(after) >= Date.parse(before)) throw new BrainError('INVALID_RANGE', 'after must precede before.');
    const clauses = query ? [...query.matchAll(/"([^"]+)"|([^\s"]+)/gu)].map(m => words(m[1] || m[2]).join(' ')).filter(Boolean) : [];
    if ((query && !clauses.length) || clauses.length > 20 || participants.some(name => !words(name).length) || (theme && !words(theme).length)) throw new BrainError('INVALID_QUERY', 'Use names and between 1 and 20 keywords or quoted phrases.');
    if (participants.length && (selectedKinds.length !== 1 || selectedKinds[0] !== 'meetings')) throw new BrainError('INVALID_ARGUMENTS', 'Participant filters apply to kinds=["meetings"]. Resolve the meeting first to retrieve other captures during it.');
    if (state !== 'all' && (selectedKinds.length !== 1 || selectedKinds[0] !== 'tasks')) throw new BrainError('INVALID_ARGUMENTS', 'Task state requires kinds=["tasks"].');
    // The catalog can discard out-of-period documents before reading lengthy
    // transcripts. Missing dates are retained so coverage remains explicit.
    const { documents, ...scan } = await this.scan(selectedKinds, entry => {
      const time = date_field === 'captured' ? instant(entry.timestamp) : null;
      return !time || ((!after || Date.parse(time) >= Date.parse(after)) && (!before || Date.parse(time) < Date.parse(before)));
    });
    if ((theme || pinned_only || state !== 'all') && !scan.catalog_available) throw new BrainError('CATALOG_REQUIRED', 'Open the updated MyMan app to export themes, pinning, and complete task metadata.');
    let undated = 0, missingMetadata = 0;
    const results = [];
    for (const doc of documents) {
      if (app && !doc.app && !doc.bundle_id) { missingMetadata++; continue; }
      if (app && !hasName((doc.app || '') + ' ' + (doc.bundle_id || ''), app)) continue;
      if (!tags.every(tag => doc.tags?.some(t => t.name === tag))) continue;
      if (exclude_tags.some(tag => doc.tags?.some(t => t.name === tag))) continue;
      if (!participants.every(name => doc.participants?.some(label => hasName(label, name)))) continue;
      if (theme && !doc.themes?.some(t => t.id === theme || hasName(t.title, theme))) continue;
      if (pinned_only && !doc.pinned) continue;
      if (state !== 'all' && doc.done !== (state === 'done')) continue;
      const date = date_field === 'captured' ? doc.timestamp : date_field === 'task_completed' ? doc.completed_at : doc.due_at;
      if ((after || before) && !date) { undated++; continue; }
      if (after && Date.parse(date) < Date.parse(after)) continue;
      if (before && Date.parse(date) >= Date.parse(before)) continue;
      const normalized = ' ' + words(doc.title + '\n' + doc.text).join(' ') + ' ';
      const matches = clauses.map(term => normalized.includes(' ' + term + ' '));
      if (clauses.length && !(match === 'all' ? matches.every(Boolean) : matches.some(Boolean))) continue;
      const lines = doc.text.split('\n');
      let lineIndex = clauses.length ? lines.findIndex(line => clauses.some(term => (' ' + words(line).join(' ') + ' ').includes(' ' + term + ' '))) : -1;
      if (lineIndex < 0) lineIndex = Math.max(0, lines.findIndex(line => line.startsWith('# ')) + 1);
      const read_offset = lines.slice(0, lineIndex).reduce((sum, line) => sum + line.length + 1, 0);
      const excerpt = doc.text.slice(read_offset, read_offset + 600);
      results.push({ ...this.summary(doc), excerpt, read_offset,
        source: this.source(doc, lineIndex + 1, lineIndex + excerpt.split('\n').length) });
    }
    results.sort((a, b) => (b.timestamp || '').localeCompare(a.timestamp || '') || a.path.localeCompare(b.path));
    if (unique) {
      const seen = new Set();
      for (let i = 0; i < results.length;) {
        const key = results[i].sequence_id || results[i].path;
        if (seen.has(key)) results.splice(i, 1); else { seen.add(key); i++; }
      }
    }
    if (anchor && (await this.load(during)).text !== anchor.text) throw new BrainError('EXPORT_CHANGED', 'Meeting changed during collection; retry.');
    return { results: results.slice(offset, offset + limit), total: results.length,
      next_offset: offset + limit < results.length ? offset + limit : null, ...scan,
      partial: scan.partial || undated > 0 || missingMetadata > 0, items_without_capture_time: undated, items_without_app_metadata: missingMetadata,
      date_bounds: '[after, before)', date_field, ...(anchor ? { during: this.summary(anchor), relationship: 'captured_during_meeting' } : {}),
      coverage: scan.catalog_available ? 'Current app catalog; excluded captures omitted.' : 'Legacy exports only; dictations, saved Themes, and complete task history may be unavailable. Open the updated app to export them.' };
  }

  async meetings({ query, participants = [], started_after, started_before, limit = 10, offset = 0 }) {
    const terms = query ? [...new Set(words(query))] : [];
    if ((query && !terms.length) || terms.length > 20 || participants.some(name => !words(name).length)) {
      throw new BrainError('INVALID_QUERY', 'Use names and between 1 and 20 topic keywords.');
    }
    if (started_after && started_before && Date.parse(started_after) >= Date.parse(started_before)) {
      throw new BrainError('INVALID_RANGE', 'started_after must precede started_before.');
    }
    const { documents, ...scan } = await this.scan(['meetings']);
    const matches = [];
    for (const doc of documents) {
      // A name mentioned in the transcript is not proof of attendance.
      if (!participants.every(name => doc.participants.some(label => hasName(label, name)))) continue;
      if ((started_after || started_before) && !doc.started_at) continue;
      if (started_after && Date.parse(doc.started_at) < Date.parse(started_after)) continue;
      if (started_before && Date.parse(doc.started_at) >= Date.parse(started_before)) continue;
      const identity = words(doc.title + '\n' + doc.participants.join('\n'));
      const all = new Set(words(doc.text));
      if (!terms.every(term => all.has(term))) continue;
      const identityMatch = terms.length > 0 && terms.every(term => identity.includes(term));
      matches.push({ ...this.summary(doc), matched_in: terms.length ? (identityMatch ? 'title_or_participants' : 'meeting_content') : 'participants_or_date',
        interval_available: !!(doc.started_at && doc.ended_at && doc.ended_at > doc.started_at) });
    }
    matches.sort((a, b) => Number(b.matched_in === 'title_or_participants') - Number(a.matched_in === 'title_or_participants') ||
      (b.started_at || '').localeCompare(a.started_at || '') || a.path.localeCompare(b.path));
    return { results: matches.slice(offset, offset + limit), total: matches.length,
      next_offset: offset + limit < matches.length ? offset + limit : null, ...scan };
  }

  async screenshots({ meeting, after, before, app, tags = [], exclude_tags = [], unique = false, query, limit = 50, offset = 0 }) {
    if (meeting && (after || before)) throw new BrainError('INVALID_ARGUMENTS', 'Use either meeting or an explicit after/before range.');
    let anchor;
    if (meeting) {
      if (meeting.startsWith('meetings/')) anchor = this.summary(await this.load(meeting));
      else {
        const exact = await this.scan(['meetings']);
        const byID = exact.documents.filter(doc => doc.id === meeting);
        if (byID.length === 1 && !exact.partial) anchor = this.summary(byID[0]);
        else {
          const candidates = await this.meetings({ query: meeting, limit: 50 });
          if (candidates.total !== 1 || candidates.partial) return { needs_disambiguation: true, meetings: candidates.results, matching_meetings: candidates.total, next_offset: candidates.next_offset, partial: candidates.partial, warnings: candidates.warnings, results: [], message: 'Choose a meeting ID or path from these candidates; no call was chosen automatically.' };
          anchor = candidates.results[0];
        }
      }
    }
    const collection = await this.collect({ kinds: ['screenshots'], during: anchor?.path, after, before, app, tags, exclude_tags, unique, query, limit, offset });
    return { ...collection, needs_disambiguation: false, ...(anchor ? { meeting: anchor } : {}),
      note: 'Meeting links/time overlap do not establish subject matter. Tags and sensitivity hints are heuristic; not_detected does not mean safe to reuse.' };
  }

  async meeting_screenshots({ meeting_path, limit = 50, offset = 0 }) {
    if (!meeting_path.startsWith('meetings/')) throw new BrainError('INVALID_PATH', 'Choose a meeting path returned by meetings.');
    const meeting = await this.load(meeting_path);
    if (!meeting.started_at || !meeting.ended_at || meeting.ended_at <= meeting.started_at) {
      throw new BrainError('MEETING_INTERVAL_UNAVAILABLE', 'This meeting has no valid completed start/end interval. It may still be recording or have incomplete export metadata.');
    }
    const { documents, ...scan } = await this.scan(['screenshots']);
    const unknown = documents.filter(doc => !doc.captured_at);
    const matches = documents.filter(doc => doc.captured_at && doc.captured_at >= meeting.started_at && doc.captured_at < meeting.ended_at)
      .sort((a, b) => a.captured_at.localeCompare(b.captured_at) || a.path.localeCompare(b.path));
    // Recheck the selected interval after the scan, so an edit/deletion cannot
    // quietly yield a result for a meeting that no longer exists as selected.
    const current = await this.load(meeting_path);
    if (current.text !== meeting.text) throw new BrainError('EXPORT_CHANGED', 'Meeting changed while retrieving screenshots; select it again.');
    return { meeting: this.summary(meeting), interval: { start: meeting.started_at, end: meeting.ended_at, bounds: '[start, end)' },
      relationship: 'captured_during_meeting',
      note: 'Time association only; screenshots may show unrelated work. image_path is an unverified local export reference; the companion does not open images.',
      results: matches.slice(offset, offset + limit).map(doc => ({ ...this.summary(doc),
        seconds_into_meeting: (Date.parse(doc.captured_at) - Date.parse(meeting.started_at)) / 1000 })),
      total: matches.length, next_offset: offset + limit < matches.length ? offset + limit : null,
      ...scan, partial: scan.partial || unknown.length > 0, screenshots_without_capture_time: unknown.length };
  }

  async read({ path: relative, offset = 0, max_chars = 12000 }) {
    const doc = await this.load(relative);
    if (offset > doc.text.length) throw new BrainError('INVALID_OFFSET', 'Offset exceeds the document length.');
    const content = doc.text.slice(offset, offset + max_chars);
    const line = doc.text.slice(0, offset).split('\n').length;
    return { ...this.summary(doc), content, offset, total_chars: doc.text.length,
      next_offset: offset + content.length < doc.text.length ? offset + content.length : null,
      source: this.source(doc, line, line + content.split('\n').length - 1) };
  }

  async tasks({ state = 'open', limit = 30, offset = 0 }) {
    if (await this.catalog()) return this.collect({ kinds: ['tasks'], state, limit, offset });
    const doc = await this.load('tasks.md');
    const results = [];
    doc.text.split('\n').forEach((line, index) => {
      const match = /^\s*- \[([ xX])\] (.+)$/.exec(line);
      if (!match) return;
      const done = match[1].toLowerCase() === 'x';
      if (state !== 'all' && done !== (state === 'done')) return;
      const title = match[2].replace(/\s*<!--.*?-->\s*$/, '');
      results.push({ title: title.slice(0, 2000), title_truncated: title.length > 2000, done, source: this.source(doc, index + 1) });
    });
    return { results: results.slice(offset, offset + limit), total: results.length,
      next_offset: offset + limit < results.length ? offset + limit : null, exported_at: doc.exported_at,
      note: 'Export snapshot: app-to-Brain sync is one-way; completed task history may be capped by MyMan.' };
  }

  async image({ path: relative, size = 'original' }) {
    const doc = await this.load(relative);
    if (doc.kind !== 'screenshots') throw new BrainError('INVALID_PATH', 'Choose a screenshot export returned by collect.');
    const catalog = await this.catalog();
    if (!catalog) throw new BrainError('CATALOG_REQUIRED', 'Open the updated app to export trusted screenshot references. Legacy markdown image paths are not opened.');
    const file = catalog.exports.find(e => e.path === relative)?.[size === 'thumbnail' ? 'thumbnail_path' : 'image_path'];
    if (size === 'thumbnail' && (typeof file !== 'string' || path.dirname(file) !== path.join(await this.root(), 'assets', 'capture-thumbnails'))) throw new BrainError('THUMBNAIL_UNAVAILABLE', 'No current app-generated thumbnail is available for this screenshot.');
    if (typeof file !== 'string' || !path.isAbsolute(file) || /[\x00-\x1f]/.test(file) || path.extname(file).toLowerCase() !== '.png') {
      throw new BrainError('IMAGE_UNAVAILABLE', 'This screenshot has no supported original PNG reference in the app catalog.');
    }
    let handle;
    try {
      const parent = path.dirname(file);
      if (await realpath(parent) !== parent) throw new BrainError('UNSAFE_PATH', 'Linked image folders are not readable.');
      handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1) throw new BrainError('UNSAFE_PATH', 'Only regular, unlinked screenshot files are readable.');
      if (stat.size > (size === 'thumbnail' ? 1024 * 1024 : 8 * 1024 * 1024)) throw new BrainError('IMAGE_TOO_LARGE', 'Original exceeds the 8 MiB image limit. Use the returned local image_path with a local image viewer.');
      const data = Buffer.alloc(stat.size + 1);
      let length = 0;
      while (length < data.length) {
        const { bytesRead } = await handle.read(data, length, data.length - length, null);
        if (!bytesRead) break;
        length += bytesRead;
      }
      const after = await handle.stat(), current = await lstat(file);
      if (length !== stat.size || after.mtimeMs !== stat.mtimeMs || current.isSymbolicLink() || current.ino !== stat.ino || current.dev !== stat.dev || await realpath(parent) !== parent) {
        throw new BrainError('EXPORT_CHANGED', 'Screenshot changed during reading; retry.');
      }
      const png = data.subarray(0, length);
      if (length < 33 || !png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) || png.toString('ascii', 12, 16) !== 'IHDR') {
        throw new BrainError('INVALID_IMAGE', 'The referenced file is not a PNG screenshot.');
      }
      const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
      if (!width || !height || width * height > 100_000_000 || (size === 'thumbnail' && Math.max(width, height) > 400)) throw new BrainError('IMAGE_TOO_LARGE', 'Screenshot dimensions exceed the supported limit.');
      if ((await this.catalog())?.revision !== catalog.revision) throw new BrainError('EXPORT_CHANGED', 'App catalog changed while reading the image; retry.');
      return { ...this.summary(doc), size, width, height, image: { mimeType: 'image/png', data: png.toString('base64') } };
    } catch (error) {
      if (error instanceof BrainError) throw error;
      throw new BrainError(error.code === 'ELOOP' ? 'UNSAFE_PATH' : 'IMAGE_UNAVAILABLE', 'The original screenshot is missing, linked, or inaccessible on this computer.');
    } finally { await handle?.close(); }
  }
}
