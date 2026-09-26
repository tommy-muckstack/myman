import { markupTheme } from './theme.mjs';
import { alternativeFor, closest } from './guide.mjs';
import { mkdir, mkdtemp, open, readdir, rm, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod/v4';
import { catalog } from '../brain/actions.mjs';
import { Brain } from '../brain/brain.mjs';
import { execute } from '../brain/tools.mjs';
import { annotate, capture, importImage, ocr, screens, validateMarkup } from './images.mjs';
import { captureEntry, saveCapture, saveNote } from './library.mjs';
import * as recording from './recording.mjs';
import * as video from './video.mjs';
import * as timers from './timers.mjs';
import * as identity from './identity.mjs';
import * as collab from './collab.mjs';
import * as comparison from './compare.mjs';
import { announce } from './indicator.mjs';
import * as items from './items.mjs';
import { clipboardRead, clipboardWrite, ocrRegions, windowRegion, windowsList } from './desktop.mjs';
import { processIdentity, workerAlive } from './process-identity.mjs';
import { systemGrants, systemPolicyPath } from './policy.mjs';
import { atomic, authorize, pngSize, configPath, dependencies, directory, fail, grants, readSafe, rootPath, statePath, unsupported } from './system.mjs';

export const version='0.13.0';
export const supported=new Set(['app.doctor','screens.list','screenshot.capture','screenshot.edit','note.create','screenshot.image','recording.start','recording.stop','recording.cancel','recording.status','screenshot.ocr','windows.list','clipboard.read','clipboard.write','item.read','capture.search','note.update','note.append','note.attach','item.rename','item.pin','item.exclude','item.delete','item.related','task.create','task.update','task.delete','screenshot.compare','screenshot.targets','screenshot.capture_markup','screenshot.import','recording.pause','recording.resume','recording.frames','recording.export','recording.polish','timer.start','timer.status','timer.pause','timer.resume','timer.cancel','timer.sound','reminder.create','reminder.list','reminder.cancel','reminder.sound',...collab.actions,'machine.current']);
const schemas=new Map(catalog.actions.map(a=>[a.name,z.fromJSONSchema(a.inputSchema)]));
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function errorData(error) { return {...(error.alternative?{alternative:error.alternative}:{}),...(error.details&&typeof error.details==='object'?{details:error.details}:{}),code:error.code || (error instanceof SyntaxError?'INVALID_ARGUMENTS':'INTERNAL_ERROR'),message:error.code?error.message:error instanceof SyntaxError?'Expected valid JSON.':'The local operation failed.'}; }
export async function capabilities(name, offline=false) {
  if (name && !schemas.has(name)) fail('UNKNOWN_ACTION','Unknown action name.');
  const actions=catalog.actions.filter(a=>!name || a.name===name).map(a=>({...a,supported:supported.has(a.name),platforms:supported.has(a.name)?['darwin','linux']:['darwin']}));
  const metadata={version,app_version:version,platform:'linux',source:offline?'bundled_cli':'linux_companion',live:!offline,verified_available:!offline,config_path:configPath(),limitations:['X11 capture (Wayland via grim)','Explicit pixel geometry; no Live Text targeting','Screen recording is video-only (no webcam or window capture); meetings record microphone and computer audio with myman meeting start','Windows: X11, Hyprland (Omarchy) or Sway; clipboard: xclip or wl-clipboard','No native UI or live meeting notes; meeting transcripts are made on this computer with Whisper; dictation is saved from Voxtype after myman dictation connect']};
  return name ? {...actions[0],...metadata,grants:await grants()} : {...metadata,permissions:await grants(),actions};
}
async function markupThemeInfo(){const t=await markupTheme();return {source:t.source,name:t.name,colors:t.colors};}
export async function doctor() {
  const deps=await dependencies();
  let desktop; try { desktop=await screens(); } catch(error) { desktop={ok:false,error:errorData(error)}; }
  return {platform:'linux',version,permissions:await grants(),system_policy:{path:systemPolicyPath,present:(await systemGrants())!==null},markup_theme:await markupThemeInfo(),config_path:configPath(),brain_root:rootPath(),dependencies:deps,desktop,ready:{capture:!!(desktop.displays && (desktop.session==='wayland'?deps.grim:(deps.scrot||deps.import||deps.ffmpeg)) && (deps.magick||deps.convert) && deps.git),markup:!!((deps.magick||deps.convert)&&deps.git),ocr:!!deps.tesseract,library:!!deps.git,recording:!!(desktop.displays && (desktop.session==='wayland'?deps['wf-recorder']:deps.ffmpeg) && deps.git)},note:'Owner grants are required independently of dependency readiness.'};
}
function validate(name,args) {
  if (!schemas.has(name)) { const near=closest(name,[...supported]); fail('UNKNOWN_ACTION', `Unknown action "${String(name).slice(0,80)}".${near.length?` Did you mean ${near.join(' or ')}?`:''} Run actions to list them.`); }
  if (!supported.has(name)) { const error=new Error(`${name} is not supported on Linux. ${alternativeFor(name)}`); error.code='unsupported_on_platform'; error.alternative=alternativeFor(name); throw error; }
  if (Buffer.byteLength(JSON.stringify(args))>1024*1024) fail('INVALID_ARGUMENTS','Arguments exceed 1 MiB.');
  const parsed=schemas.get(name).safeParse(args);
  if (!parsed.success) fail('INVALID_ARGUMENTS',parsed.error.issues.map(i=>`${i.path.join('.')}: ${i.message}`).join('; '));
  return parsed.data;
}
// Capture and recording always tell the person at the machine (see indicator.mjs).
const visible=new Set(['screenshot.capture','screenshot.capture_markup','recording.start','recording.pause','recording.resume','recording.stop','recording.cancel']);
export async function dispatch(name,args) {
  const result=await perform(name,args);
  if(visible.has(name)&&!args?.dry_run) await announce(name,result);
  return result;
}
// Every action runs as the credential in MYMAN_AGENT_TOKEN (or the local
// client). Grants and /etc policy come first; a credential only narrows them.
async function admit(name) {
  const permissions=catalog.actions.find(a=>a.name===name).permissions;
  await authorize(permissions);
  identity.validate(await identity.authenticate(),permissions);
}
const itemPrefixes=['item.','note.','task.','theme.'];
const sessionStarts=['recording.start'];
async function perform(name,args) {
  args=validate(name,args);
  if (name==='app.doctor') return doctor();
  await admit(name);
  if (collab.actions.includes(name)) return collab.execute(name,args);
  if (name==='machine.current') return identity.machine();
  // Leases and recording ownership, as AgentActions.executeCoordinated does.
  const mutating=catalog.actions.find(a=>a.name===name).readOnly===false, resources=[];
  if (mutating&&args.session_id&&!name.startsWith('timer.')) await collab.checkSession(args.session_id);
  if (name==='clipboard.write'||args.clipboard===true) resources.push('clipboard');
  if (mutating&&itemPrefixes.some(p=>name.startsWith(p))&&args.id) resources.push('item:'+args.id);
  if (resources.length||args.lease_id) await collab.begin(resources.sort(),args.lease_id);
  const {lease_id,...rest}=args;
  const result=await act(name,rest);
  if (sessionStarts.includes(name)&&result?.session_id) {
    try { await collab.ownSession(result.session_id); }
    catch { const error=new Error('Recording started but its owner could not be saved. Stop it with myman record stop; do not start it again.'); error.code='OWNERSHIP_NOT_PERSISTED'; error.details={session:result}; throw error; }
  }
  if (mutating&&identity.principal().named) { try { await collab.completed(name,result); } catch { return {...result,coordination_persisted:false}; } }
  return result;
}
async function act(name,args) {
  if (name==='screens.list') { const {displays,...desktop}=await screens(); return {result:displays,...desktop}; }
  if (name==='screenshot.image') return new Brain(rootPath()).image({path:(await captureEntry(args.id)).path});
  if (name==='note.create') return saveNote(args);
  const library={'item.read':items.read,'capture.search':items.search,'note.update':items.noteUpdate,'note.append':items.noteAppend,'note.attach':items.noteAttach,'item.rename':items.rename,'item.pin':items.pin,'item.exclude':items.exclude,'item.delete':items.remove,'item.related':items.related,'task.create':items.taskCreate,'task.update':items.taskUpdate,'task.delete':items.taskDelete,'screenshot.compare':comparison.compare,'screenshot.targets':comparison.targets};
  if (library[name]) return library[name](args);
  if (name==='recording.start') { const { hide_cursor, ...rest } = args; if (hide_cursor) await recording.requestHiddenCursor(); return recording.start(rest); }
  if (name==='recording.polish') { const studio = await import('./studio.mjs'); return studio.polish({ id: args.id, recipe: studio.recipeFromArgs(args), dryRun: args.dry_run === true }); }
  if (name==='recording.stop') return recording.stop(args);
  if (name==='recording.cancel') return recording.cancel(args);
  if (name==='recording.pause') return recording.pause(args);
  if (name==='recording.resume') return recording.resume(args);
  if (name==='recording.frames') return video.frames(args);
  if (name==='timer.start') return timers.timerStart(args);
  if (name==='timer.status') return timers.timerStatusAction();
  if (['timer.pause','timer.resume','timer.cancel','timer.sound'].includes(name)) return timers.timerChange(name,args);
  if (name==='reminder.create') return timers.reminderCreate(args);
  if (name==='reminder.list') return timers.reminderList();
  if (['reminder.cancel','reminder.sound'].includes(name)) return timers.reminderChange(name,args);
  if (name==='recording.export') return video.exportClip(args);
  if (name==='recording.status') return recording.status(args);
  if (name==='windows.list') return windowsList();
  if (name==='clipboard.read') return clipboardRead(args);
  if (name==='clipboard.write') return clipboardWrite(args,captureEntry);
  if (name==='screenshot.ocr') { const entry=await captureEntry(args.id), {width,height}=pngSize(await readSafe(entry.image_path,128*1024*1024)); return {id:args.id,width,height,...await ocrRegions(entry.image_path,width,height)}; }
  const dir=await directory(path.join(statePath(),'work'),true,true);
  const work=await mkdtemp(path.join(dir,'capture-'));
  try {
    if (name==='screenshot.capture' && args.window_id) {
      if (args.region || args.display) fail('INVALID_ARGUMENTS','Choose window_id or region/display.');
      const win=await windowRegion(args.window_id), {window_id,...rest}=args;
      return {...await saveCapture(await capture({...rest,region:win.region,coordinates:'global'},work),undefined,{window:{app:win.app,title:win.title}}),window_id:win.id,window:{app:win.app,title:win.title}};
    }
    if (name==='screenshot.capture') return await saveCapture(await capture(args,work),undefined,{display:args.display,region:args.region});
    if (name==='screenshot.capture_markup') {
      // Capture, mark up, and save only the finished image (as on the Mac).
      const {annotations,crop,color,background,corner_radius,background_color,open_editor,clipboard,lease_id,...where}=args;
      validateMarkup({annotations:[],background,corner_radius,background_color,open_editor,clipboard,lease_id},1,1);
      const shot=await capture(where,work), marked=await annotate(shot.file,{annotations,crop,color},work);
      const saved=await saveCapture({...marked,backend:shot.backend},undefined,{display:args.display,region:args.region,markup:(annotations??[]).map(a=>a.type)});
      return marked.theme?{...saved,theme:marked.theme}:saved;
    }
    if (name==='screenshot.import') return await saveCapture(await importImage(args.path,work),undefined,{imported:true});
    const entry=await captureEntry(args.id);
    const result=await annotate(entry.image_path,args,work);
    if (result.dry_run) return {id:args.id,...result};
    if (args.preview) {
      const previews=await directory(path.join(statePath(),'previews'),true,true);
      // Only remove our own regular PNG previews after their one-hour lifetime.
      for (const file of await readdir(previews)) if (/^[0-9a-f-]{36}\.png$/.test(file)) {
        const info=await stat(path.join(previews,file)); if (Date.now()-info.mtimeMs>3600_000) await rm(path.join(previews,file));
      }
      const file=path.join(previews,`${randomUUID()}.png`), data=await readSafe(result.file,128*1024*1024);
      await atomic(file,data);
      return {preview:true,source_id:args.id,path:file,image_path:file,width:result.width,height:result.height,expires_at:new Date(Date.now()+3600_000).toISOString(),attachment:{path:file,mime_type:'image/png',width:result.width,height:result.height,duration:null,file_size:data.length,preview_path:file}};
    }
    const saved=await saveCapture(result,args.id,{markup:(args.annotations??[]).map(a=>a.type),...(entry.app!==undefined?{window:{app:entry.app,title:entry.window_title}}:{})});
    return result.theme?{...saved,theme:result.theme}:saved;
  } finally { await rm(work,{recursive:true,force:true}); }
}
const receiptPath=id=>{ if(!uuid.test(id || ''))fail('INVALID_ARGUMENTS','Job/request IDs must be UUIDs.');return path.join(statePath(),'jobs',`${id.toLowerCase()}.json`); };
const interrupted=async receipt=>receipt.pid ? !(await workerAlive(receipt)) : Date.now()-Date.parse(receipt.created_at)>30_000;
async function readReceipt(file) {
  // Another process can see an exclusively claimed file before its initial
  // write finishes. Wait for that publication; never claim or replay it again.
  for (let attempt=0;attempt<20;attempt++) {
    try { return JSON.parse((await readSafe(file,2*1024*1024,true)).toString()); }
    catch(error) {
      if (!(error instanceof SyntaxError) && error.code!=='EXPORT_CHANGED') throw error;
      if (attempt===19) fail('INVALID_RECEIPT','The claimed receipt is incomplete. Inspect it before starting new work; this request cannot replay.');
      await new Promise(resolve=>setTimeout(resolve,25));
    }
  }
}

export async function job(id) {
  const file=receiptPath(id);
  let receipt; try { receipt=await readReceipt(file); }
  catch(error) { if(error.code==='ENOENT')fail('UNKNOWN_JOB','No receipt exists for that request ID.');throw error; }
  if (receipt.state==='running' && await interrupted(receipt)) {
    receipt=await readReceipt(file);
    if (receipt.state !== 'running' || !(await interrupted(receipt))) { const {arguments:args,fingerprint,pid,process_identity,...publicJob}=receipt; return {ok:true,job:publicJob,launch_id:receipt.launch_id,recovered:true}; }
    receipt={...receipt,state:'interrupted',error:{code:'JOB_INTERRUPTED',message:'Worker stopped. Inspect the Brain and receipt before starting new work; this request will never replay.'}};
    await atomic(file,JSON.stringify(receipt));
  }
  const {arguments:args,fingerprint,pid,process_identity,...publicJob}=receipt;
  return {ok:true,job:publicJob,launch_id:receipt.launch_id,recovered:true};
}
export async function jobs() {
  const dir=await directory(path.join(statePath(),'jobs'),true,true);
  const files=(await readdir(dir)).filter(f=>uuid.test(f.slice(0,-5))&&f.endsWith('.json'));
  const receipts=await Promise.all(files.map(f=>job(f.slice(0,-5))));
  return {ok:true,jobs:receipts.map(r=>r.job).sort((a,b)=>b.created_at.localeCompare(a.created_at)).slice(0,100)};
}
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
export async function invoke(name,args={},control={}) {
  args=validate(name,args);
  if (name!=='app.doctor') await admit(name);
  // Read-only calls have no side effects to deduplicate and need no worker.
  if (catalog.actions.find(a=>a.name===name).readOnly) return {job:{id:control.id||randomUUID(),state:'succeeded',result:await dispatch(name,args)},launch_id:'linux'};
  await directory(statePath(),true,true);
  await directory(path.join(statePath(),'jobs'),true,true);
  const id=control.id||randomUUID(), file=receiptPath(id);
  const fingerprint=createHash('sha256').update(JSON.stringify(canonical({name,args,root:rootPath()}))).digest('hex');
  const receipt={id:id.toLowerCase(),action:name,arguments:args,fingerprint,state:'running',created_at:new Date().toISOString(),launch_id:randomUUID(),pid:null};
  // Exclusive create claims the request before any mutation. Never replay a
  // claimed request, including a receipt left by a terminated worker.
  let handle;
  try { handle=await open(file,'wx',0o600); }
  catch(error) {
    if(error.code!=='EEXIST')throw error;
    const previous=await readReceipt(file);
    if(previous.fingerprint!==fingerprint)fail('ID_CONFLICT','This request ID belongs to different arguments.');
  }
  if(handle) {
    try { await handle.writeFile(JSON.stringify(receipt)); await handle.sync(); } finally { await handle.close(); }
    const worker=spawn(process.execPath,[fileURLToPath(new URL('./worker.mjs',import.meta.url)),id],{detached:true,stdio:'ignore',env:process.env});
    worker.unref();
    worker.on('error',async()=>{await atomic(file,JSON.stringify({...receipt,state:'failed',error:{code:'WORKER_UNAVAILABLE',message:'Could not start the Linux worker.'}})).catch(()=>{});});
  }
  const deadline=Date.now()+(control.waitMs??300_000);
  let reply;
  do { reply=await job(id); if(reply.job.state!=='running'||control.wait===false||Date.now()>=deadline)return reply;await new Promise(r=>setTimeout(r,100)); } while(true);
}
export async function work(id) {
  const file=receiptPath(id), receipt=await readReceipt(file);
  if(receipt.state!=='running'||receipt.pid)return;
  // Only the parent that exclusively created the receipt starts a worker.
  try {
    receipt.process_identity=await processIdentity(process.pid);
    if (!receipt.process_identity) fail('PROCESS_IDENTITY_UNAVAILABLE','Cannot establish the worker identity.');
    receipt.pid=process.pid;
    await atomic(file,JSON.stringify(receipt));
    receipt.result=await dispatch(receipt.action,receipt.arguments);receipt.state='succeeded';
  }
  catch(error) { receipt.state='failed';receipt.error=errorData(error); }
  delete receipt.arguments; // Retain the fingerprint, not a second copy of a large note body.
  receipt.finished_at=new Date().toISOString();
  await atomic(file,JSON.stringify(receipt));
}
