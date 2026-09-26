import { lstat, mkdir, readFile, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Brain, folders } from '../brain/brain.mjs';
import { atomic, command, directory, fail, imageCommand, pngSize, readSafe, rootPath, run } from './system.mjs';
import { ocr } from './images.mjs';

export async function initBrain() {
  const root = await directory(rootPath());
  for (const folder of [...folders,'assets','assets/captures','assets/capture-thumbnails','assets/recordings','assets/recording-thumbnails']) await directory(path.join(root, folder));
  return root;
}
export async function lockedWrite(fn) {
  const root = await initBrain(), lock = path.join(root, '.myman-linux-write.lock');
  try { await mkdir(lock, { mode: 0o700 }); }
  catch (error) {
    if (error.code === 'EEXIST') fail('LIBRARY_BUSY', 'A Brain writer is active or interrupted. Inspect .myman-linux-write.lock/owner.json; remove the lock only after its owner has stopped.');
    throw error;
  }
  try { await atomic(path.join(lock,'owner.json'), JSON.stringify({pid:process.pid,created_at:new Date().toISOString()})); return await fn(root); }
  finally { await rm(lock, { recursive: true, force: true }); }
}
export async function catalogForWrite(root) {
  const brain = new Brain(root);
  const existing = await brain.catalog();
  // Hidden (excluded) items stay recoverable but outside exports, so every
  // reader and search omits them.
  if (existing) return { version: 1, generated_at: existing.generated_at, exports: existing.exports, ...(Array.isArray(existing.excluded)&&existing.excluded.length?{ excluded: existing.excluded }:{}) };
  // Preserve a legacy Brain's documents when introducing its first catalog.
  const scan = await brain.scan();
  if (scan.partial) fail('EXPORT_CHANGED', 'Existing legacy exports could not be read completely; no catalog was written.');
  return { version: 1, exports: scan.documents.filter(doc=>doc.path.includes('/')).map(doc=>({ item_id: `${doc.kind==='screenshots'?'shot':'note'}-${doc.id || randomUUID()}`, revision:1, path:doc.path, kind:doc.kind, title:doc.title, timestamp:doc.timestamp, ...(doc.image_path?{image_path:doc.image_path}:{}), themes:[], pinned:false })) };
}
export async function gitSave(root, files, message = 'MyMan Linux: save local capture') {
  const git = await command('git');
  if (!git) fail('DEPENDENCY_MISSING', 'Install git before saving to MyManBrain.');
  try {
    // Never discover or commit to a repository above MyManBrain. Reject linked
    // gitdirs, and disable hooks and signing for companion-created commits.
    try { const info = await lstat(path.join(root,'.git')); if (!info.isDirectory() || info.isSymbolicLink()) fail('UNSAFE_PATH','Brain .git must be an ordinary directory.'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; await run(git, ['-C',root,'init','--quiet']); }
    await run(git, ['-C',root,'-c','core.hooksPath=/dev/null','add','-A','--',...files]);
    await run(git, ['-C',root,'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','user.name=MyMan','-c','user.email=myman@localhost','commit','--quiet','--only','-m',message,'--',...files]);
    return { committed: true };
  } catch (error) {
    // A file already saved must still return its ID if git fails; retrying the
    // mutation to fix git would create a duplicate. No push or remote is used.
    return { committed: false, error: { code: error.code, message: error.message } };
  }
}
export const titleLine = value => value.replace(/[\r\n\x00-\x1f]/g, ' ').trim().slice(0,1000);
export async function saveNote(args) {
  if (!await command('git')) fail('DEPENDENCY_MISSING', 'Install git before saving notes.');
  return lockedWrite(async root => {
    const id = randomUUID(), created_at = new Date().toISOString();
    const title = titleLine(args.title || args.body.split('\n').find(l=>l.trim())?.replace(/^#+\s*/,'') || 'Note');
    const brain_path = `notes/${created_at.slice(0,10)}-${id.slice(0,8)}.md`;
    const catalog = await catalogForWrite(root);
    await atomic(path.join(root,brain_path), `---\nid: ${id}\ncreated: ${created_at}\nupdated: ${created_at}\n---\n\n# ${title}\n\n${args.body}\n`);
    catalog.exports.push({ item_id:`note-${id}`, revision:1, path:brain_path, kind:'notes', title, timestamp:created_at, themes:[], pinned:false });
    catalog.generated_at = created_at;
    await atomic(path.join(root,'catalog.json'), JSON.stringify(catalog,null,2)+'\n');
    const git = await gitSave(root,[brain_path,'catalog.json']);
    return { id:`note-${id}`, kind:'note', title, body:args.body, path:path.join(root,brain_path), brain_path, created_at, updated_at:created_at, git };
  });
}
// Readable by people and agents: every capture note says what it shows in
// plain words (also used as image alt text), embeds the image, and states
// the text-recognition outcome instead of leaving an empty section.
const yaml = value => JSON.stringify(String(value));
const oneLine = (value, max) => String(value ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
export function describeCapture({ width, height, window, display, region, source_id, markup }) {
  const app = oneLine(window?.app, 80), title = oneLine(window?.title, 160);
  const what = window ? `the ${app || 'unnamed'} window${title ? ` "${title}"` : ''}`
    : region ? `a ${width}x${height} region of ${display ? `display ${oneLine(display, 40)}` : 'the desktop'}`
    : display ? `display ${oneLine(display, 40)}` : 'the desktop';
  const marks = markup?.length ? ` with ${summarizeMarks(markup)}` : '';
  const alt = source_id ? `Marked-up copy of screenshot ${source_id}${marks}, ${width}x${height} pixels`
    : `Screenshot of ${what}, ${width}x${height} pixels`;
  const heading = source_id ? `Marked-up screenshot${title ? `: ${title}` : ''}` : window ? `Screenshot: ${title || app || 'window'}${title && app ? ` (${app})` : ''}` : `Screenshot of ${what}`;
  return { alt_text: alt, heading: oneLine(heading, 160) };
}
function summarizeMarks(types) {
  const counts = {}; for (const t of types) counts[t] = (counts[t] ?? 0) + 1;
  const words = Object.entries(counts).map(([t, n]) => `${n} ${t}${n > 1 ? (t === 'box' ? 'es' : 's') : ''}`);
  return words.length > 1 ? `${words.slice(0, -1).join(', ')} and ${words.at(-1)}` : words[0];
}
export function recognitionSection(recognition) {
  if (recognition.status === 'ready' && recognition.text) return recognition.text;
  if (recognition.status === 'ready') return '_No text was found in this image._';
  if (recognition.status === 'unavailable') return '_Text recognition is unavailable. Install tesseract to make screenshot text searchable._';
  return '_Text recognition failed for this image._';
}
export async function saveCapture(result, source_id, meta = {}) {
  if (!await command('git')) fail('DEPENDENCY_MISSING', 'Install git before saving screenshots.');
  const recognition = await ocr(result.file);
  return lockedWrite(async root => {
    const id=randomUUID(), created_at=new Date().toISOString();
    const timezone=Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
    const brain_path=`screenshots/${created_at.slice(0,10)}-${id.slice(0,8)}.md`, imageRelative=`assets/captures/${id}.png`, thumbnailRelative=`assets/capture-thumbnails/${id}.png`;
    const image_path=path.join(root,imageRelative), thumbnail_path=path.join(root,thumbnailRelative);
    const catalog=await catalogForWrite(root);
    const png=await readSafe(result.file,128*1024*1024), size=pngSize(png);
    await atomic(image_path,png);
    await run(await imageCommand(),[image_path,'-thumbnail','400x400>','-strip',thumbnail_path]);
    const { alt_text, heading } = describeCapture({ ...size, ...meta, source_id });
    const text = recognition.status === 'ready' ? recognition.text : '';
    const text_found = text.length > 0;
    const local = new Date(created_at).toLocaleString('en-US', { timeZone: timezone, dateStyle: 'medium', timeStyle: 'short' });
    const app = meta.window ? oneLine(meta.window.app, 80) : null, window_title = meta.window ? oneLine(meta.window.title, 160) : null;
    const front = [`id: ${id}`, 'kind: screenshot', `created: ${created_at}`, `captured: ${created_at}`, `file: ${image_path}`, `width: ${size.width}`, `height: ${size.height}`,
      `alt: ${yaml(alt_text)}`, ...(app !== null ? [`app: ${yaml(app)}`, `window_title: ${yaml(window_title)}`] : []), ...(source_id ? [`source_id: ${source_id}`] : []), `ocr_status: ${recognition.status}`, `text_found: ${text_found}`];
    await atomic(path.join(root,brain_path),`---\n${front.join('\n')}\n---\n\n# ${heading}\n\n![${alt_text.replace(/[\[\]]/g,'')}](../${imageRelative})\n\n${alt_text}. Captured ${local} (${timezone}).\n\n${source_id?`Source: ${source_id}\n\n`:''}## Text on screen\n\n${recognitionSection(recognition)}\n`);
    const title=heading;
    catalog.exports.push({ item_id:`shot-${id}`, revision:1, path:brain_path, kind:'screenshots', title, timestamp:created_at, image_path, thumbnail_path, captured_local:created_at, timezone, timezone_source:'capture', themes:[], tags:[], meetings:[], pinned:false, ocr_status:recognition.status, alt_text, text_found, ...(app!==null?{app,window_title}:{}), ...(source_id?{source_id}:{}) });
    catalog.generated_at=created_at;
    await atomic(path.join(root,'catalog.json'),JSON.stringify(catalog,null,2)+'\n');
    const git=await gitSave(root,[brain_path,imageRelative,thumbnailRelative,'catalog.json']);
    return { id:`shot-${id}`,kind:'screenshot',title,alt_text,path:image_path,image_path,brain_path,...size,scale:1,created_at,timezone,ocr_status:recognition.status,text_found,text_excerpt:oneLine(text,280),...(result.backend?{backend:result.backend}:{}),...(source_id?{source_id}:{}),attachment:{path:image_path,mime_type:'image/png',...size,duration:null,file_size:png.length,preview_path:thumbnail_path,alt_text},git };
  });
}
export async function captureEntry(id) {
  const brain = new Brain(rootPath()), catalog = await brain.catalog();
  const entry = catalog?.exports.find(e=>e.kind==='screenshots' && (e.item_id===id || e.item_id===`shot-${id}`));
  if (!entry) fail('UNKNOWN_ITEM','No screenshot with that ID exists in this Brain.');
  await brain.load(entry.path);
  if (!path.isAbsolute(entry.image_path || '') || path.extname(entry.image_path) !== '.png') fail('INVALID_IMAGE','Screenshot has no PNG reference.');
  pngSize(await readSafe(entry.image_path,128*1024*1024));
  return entry;
}
export async function recordingEntry(id) {
  const brain = new Brain(rootPath()), catalog = await brain.catalog();
  const entry = catalog?.exports.find(e=>e.kind==='recordings' && (e.item_id===id || e.item_id===`rec-${id}`));
  if (!entry) fail('UNKNOWN_ITEM','No recording with that ID exists in this Brain.');
  await brain.load(entry.path);
  if (!path.isAbsolute(entry.video_path || '') || path.extname(entry.video_path) !== '.mp4') fail('INVALID_VIDEO','Recording has no MP4 file.');
  const info = await stat(entry.video_path).catch(() => null);
  if (!info?.isFile()) fail('INVALID_VIDEO','The recording file is missing from this computer.');
  return entry;
}
export async function saveRecording(rec) {
  if (!await command('git')) fail('DEPENDENCY_MISSING', 'Install git before saving recordings.');
  return lockedWrite(async root => {
    const id=randomUUID(), created_at=new Date().toISOString();
    const timezone=Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
    const brain_path=`recordings/${created_at.slice(0,10)}-${id.slice(0,8)}.md`, videoRelative=`assets/recordings/${id}.mp4`, thumbnailRelative=`assets/recording-thumbnails/${id}.png`;
    const video_path=path.join(root,videoRelative), thumbnail_path=path.join(root,thumbnailRelative);
    const catalog=await catalogForWrite(root);
    await atomic(video_path, await readSafe(rec.file, 1024*1024*1024));
    const ffmpeg = await command('ffmpeg');
    let thumb=false;
    if (ffmpeg) { try { await run(ffmpeg,['-nostdin','-loglevel','error','-ss',String(Math.min(1,rec.duration/2)),'-i',video_path,'-frames:v','1','-vf','scale=400:-2','-y',thumbnail_path]); thumb=true; } catch {} }
    const title=`Recording ${created_at}`, duration=+rec.duration.toFixed(2), size=(await stat(video_path)).size;
    const alt_text=`Screen recording, ${duration} seconds, ${rec.width}x${rec.height} pixels, video only (no audio)`;
    await atomic(path.join(root,brain_path),`---\nid: ${id}\nkind: recording\ncreated: ${created_at}\nrecorded: ${rec.started_at}\nduration: ${duration}\nwidth: ${rec.width}\nheight: ${rec.height}\naudio: false\n${rec.source_id?`source_id: ${rec.source_id}\n`:''}file: ${video_path}\nalt: ${yaml(alt_text)}\n---\n\n# ${title}\n\n${thumb?`![First frame: ${alt_text}](../${thumbnailRelative})\n\n`:''}${alt_text}, ${rec.source_id?`exported from ${rec.source_id}`:`captured with ${rec.backend}`}. The video file is kept locally at \`${video_path}\` and is not stored in Git.\n`);
    catalog.exports.push({ item_id:`rec-${id}`, revision:1, path:brain_path, kind:'recordings', title, timestamp:created_at, video_path, ...(thumb?{thumbnail_path}:{}), duration, width:rec.width, height:rec.height, captured_local:rec.started_at, timezone, themes:[], tags:[], meetings:[], pinned:false, alt_text, ...(rec.source_id?{source_id:rec.source_id}:{}) });
    catalog.generated_at=created_at;
    await atomic(path.join(root,'catalog.json'),JSON.stringify(catalog,null,2)+'\n');
    // Videos stay on disk but out of Git history so the Brain repo never bloats.
    const ignore=path.join(root,'.gitignore'); let rules='';
    try { rules=(await readSafe(ignore,1024*1024)).toString(); } catch (error) { if (error.code!=='ENOENT') throw error; }
    const ignoreChanged=!rules.split('\n').includes('assets/recordings/');
    if (ignoreChanged) await atomic(ignore,rules+(rules&&!rules.endsWith('\n')?'\n':'')+'# MyMan: large media is kept locally, not in Git\nassets/recordings/\n');
    const git=await gitSave(root,[brain_path,...(thumb?[thumbnailRelative]:[]),'catalog.json',...(ignoreChanged?['.gitignore']:[])]);
    return { id:`rec-${id}`, kind:'recording', title, alt_text, path:video_path, video_path, brain_path, width:rec.width, height:rec.height, duration, created_at, timezone, backend:rec.backend, ...(rec.source_id?{source_id:rec.source_id}:{}), attachment:{path:video_path,mime_type:'video/mp4',width:rec.width,height:rec.height,duration,file_size:size,preview_path:thumb?thumbnail_path:null}, git };
  });
}
