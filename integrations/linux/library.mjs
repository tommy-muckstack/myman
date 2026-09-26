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
async function catalogForWrite(root) {
  const brain = new Brain(root);
  const existing = await brain.catalog();
  if (existing) return { version: 1, generated_at: existing.generated_at, exports: existing.exports };
  // Preserve a legacy Brain's documents when introducing its first catalog.
  const scan = await brain.scan();
  if (scan.partial) fail('EXPORT_CHANGED', 'Existing legacy exports could not be read completely; no catalog was written.');
  return { version: 1, exports: scan.documents.filter(doc=>doc.path.includes('/')).map(doc=>({ item_id: `${doc.kind==='screenshots'?'shot':'note'}-${doc.id || randomUUID()}`, revision:1, path:doc.path, kind:doc.kind, title:doc.title, timestamp:doc.timestamp, ...(doc.image_path?{image_path:doc.image_path}:{}), themes:[], pinned:false })) };
}
async function gitSave(root, files) {
  const git = await command('git');
  if (!git) fail('DEPENDENCY_MISSING', 'Install git before saving to MyManBrain.');
  try {
    // Never discover or commit to a repository above MyManBrain. Reject linked
    // gitdirs, and disable hooks and signing for companion-created commits.
    try { const info = await lstat(path.join(root,'.git')); if (!info.isDirectory() || info.isSymbolicLink()) fail('UNSAFE_PATH','Brain .git must be an ordinary directory.'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; await run(git, ['-C',root,'init','--quiet']); }
    await run(git, ['-C',root,'-c','core.hooksPath=/dev/null','add','--',...files]);
    await run(git, ['-C',root,'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','user.name=MyMan','-c','user.email=myman@localhost','commit','--quiet','--only','-m','MyMan Linux: save local capture','--',...files]);
    return { committed: true };
  } catch (error) {
    // A file already saved must still return its ID if git fails; retrying the
    // mutation to fix git would create a duplicate. No push or remote is used.
    return { committed: false, error: { code: error.code, message: error.message } };
  }
}
const titleLine = value => value.replace(/[\r\n\x00-\x1f]/g, ' ').trim().slice(0,1000);
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
export async function saveCapture(result, source_id) {
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
    const title=`Screenshot ${created_at}`;
    await atomic(path.join(root,brain_path),`---\nid: ${id}\ncreated: ${created_at}\ncaptured: ${created_at}\nfile: ${image_path}\n---\n\n# ${title}\n\n${source_id?`Source: ${source_id}\n\n`:''}## OCR\n\n${recognition.text}\n`);
    catalog.exports.push({ item_id:`shot-${id}`, revision:1, path:brain_path, kind:'screenshots', title, timestamp:created_at, image_path, thumbnail_path, captured_local:created_at, timezone, timezone_source:'capture', themes:[], tags:[], meetings:[], pinned:false, ocr_status:recognition.status, ...(source_id?{source_id}:{}) });
    catalog.generated_at=created_at;
    await atomic(path.join(root,'catalog.json'),JSON.stringify(catalog,null,2)+'\n');
    const git=await gitSave(root,[brain_path,imageRelative,thumbnailRelative,'catalog.json']);
    return { id:`shot-${id}`,kind:'screenshot',path:image_path,image_path,brain_path,...size,scale:1,created_at,timezone,ocr_status:recognition.status,...(result.backend?{backend:result.backend}:{}),...(source_id?{source_id}:{}),attachment:{path:image_path,mime_type:'image/png',...size,duration:null,file_size:png.length,preview_path:thumbnail_path},git };
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
    await atomic(path.join(root,brain_path),`---\nid: ${id}\ncreated: ${created_at}\nrecorded: ${rec.started_at}\nduration: ${duration}\nfile: ${video_path}\n---\n\n# ${title}\n\nScreen recording, ${duration}s, ${rec.width}x${rec.height}, captured with ${rec.backend}.\n`);
    catalog.exports.push({ item_id:`rec-${id}`, revision:1, path:brain_path, kind:'recordings', title, timestamp:created_at, video_path, ...(thumb?{thumbnail_path}:{}), duration, width:rec.width, height:rec.height, captured_local:rec.started_at, timezone, themes:[], tags:[], meetings:[], pinned:false });
    catalog.generated_at=created_at;
    await atomic(path.join(root,'catalog.json'),JSON.stringify(catalog,null,2)+'\n');
    const git=await gitSave(root,[brain_path,videoRelative,...(thumb?[thumbnailRelative]:[]),'catalog.json']);
    return { id:`rec-${id}`, kind:'recording', path:video_path, video_path, brain_path, width:rec.width, height:rec.height, duration, created_at, timezone, backend:rec.backend, attachment:{path:video_path,mime_type:'video/mp4',width:rec.width,height:rec.height,duration,file_size:size,preview_path:thumb?thumbnail_path:null}, git };
  });
}
