import { constants } from 'node:fs';
import { lstat, realpath, open, opendir } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const folders = ['meetings', 'notes', 'recordings', 'screenshots'];
export const singletons = ['tasks.md', 'people.md', 'vocabulary.md'];
export const kinds = [...folders, 'tasks', 'people', 'vocabulary'];
export const limits = { fileBytes: 2 * 1024 * 1024, scanBytes: 64 * 1024 * 1024, entries: 10000 };

export class BrainError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function allowed(relative) {
  if (typeof relative !== 'string' || /[\\\x00-\x1f]/.test(relative)) return false;
  const parts = relative.split('/');
  if (parts.some(p => !p || p === '.' || p === '..' || p.startsWith('.'))) return false;
  return singletons.includes(relative) || (parts.length === 2 && folders.includes(parts[0]) && parts[1].endsWith('.md'));
}

function metadata(text, relative, stat) {
  const lines = text.split('\n');
  const fields = {};
  // Read only MyMan's scalar fields, not arbitrary YAML tags or file references.
  if (lines[0] === '---') {
    const end = lines.indexOf('---', 1);
    if (end > 0 && end < 100) for (const line of lines.slice(1, end)) {
      const match = /^(id|started|created|updated|captured|ended|low_content):\s*(.*)$/.exec(line);
      if (match) fields[match[1]] = match[2].slice(0, 200);
    }
  }
  const candidate = fields.started || fields.created || fields.captured;
  const timestamp = candidate && Number.isFinite(Date.parse(candidate)) ? new Date(candidate).toISOString() : null;
  return {
    path: relative,
    kind: relative.includes('/') ? relative.split('/')[0] : relative.replace('.md', ''),
    title: (lines.find(line => line.startsWith('# '))?.slice(2) || path.basename(relative, '.md')).slice(0, 300),
    timestamp, exported_at: stat.mtime.toISOString(),
    low_content: fields.low_content === 'true',
  };
}

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

  async load(relative) {
    if (!allowed(relative)) throw new BrainError('INVALID_PATH', 'Use a source-relative markdown path returned by search or recent.');
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
      if (stat.size > limits.fileBytes) throw new BrainError('FILE_TOO_LARGE', 'Export exceeds the 2 MiB document limit.');
      // Cap the read even if the file grows after stat(). O_NOFOLLOW protects the
      // final component; canonical parent checks reject linked export folders.
      const buffer = Buffer.alloc(Math.min(stat.size + 1, limits.fileBytes + 1));
      let length = 0;
      while (length < buffer.length) {
        const { bytesRead } = await handle.read(buffer, length, buffer.length - length, null);
        if (!bytesRead) break;
        length += bytesRead;
      }
      if (length > limits.fileBytes) throw new BrainError('FILE_TOO_LARGE', 'Export exceeds the 2 MiB document limit.');
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

  async scan() {
    const root = await this.root();
    const paths = [...singletons];
    const warnings = [];
    let inspected = 0;
    for (const folder of folders) {
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
      try {
        const doc = await this.load(relative);
        bytes += doc.bytes;
        if (bytes > limits.scanBytes) { warnings.push({ code: 'SCAN_BYTE_LIMIT' }); break; }
        documents.push(doc);
      } catch (error) {
        if (error.code !== 'DOCUMENT_NOT_FOUND' || !singletons.includes(relative)) warnings.push({ path: relative, code: error.code });
      }
    }
    return { documents, warnings: warnings.slice(0, 100), warning_count: warnings.length, partial: warnings.length > 0 };
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
    return { root: await this.root(), read_only: true, counts, ...scan, limits };
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
}
