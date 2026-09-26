import { markupTheme } from './theme.mjs';
import { mkdir, mkdtemp, open, readdir, rm, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod/v4';
import { catalog } from '../brain/actions.mjs';
import { Brain } from '../brain/brain.mjs';
import { execute } from '../brain/tools.mjs';
import { annotate, capture, ocr, screens } from './images.mjs';
import { captureEntry, saveCapture, saveNote } from './library.mjs';
import * as recording from './recording.mjs';
import { clipboardRead, clipboardWrite, ocrRegions, windowRegion, windowsList } from './desktop.mjs';
import { processIdentity, workerAlive } from './process-identity.mjs';
import { systemGrants, systemPolicyPath } from './policy.mjs';
import { atomic, authorize, pngSize, configPath, dependencies, directory, fail, grants, readSafe, rootPath, statePath, unsupported } from './system.mjs';

export const version='0.13.0';
export const supported=new Set(['app.doctor','screens.list','screenshot.capture','screenshot.edit','note.create','screenshot.image','recording.start','recording.stop','recording.cancel','recording.status','screenshot.ocr','windows.list','clipboard.read','clipboard.write']);
const schemas=new Map(catalog.actions.map(a=>[a.name,z.fromJSONSchema(a.inputSchema)]));
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function errorData(error) { return {code:error.code || (error instanceof SyntaxError?'INVALID_ARGUMENTS':'INTERNAL_ERROR'),message:error.code?error.message:error instanceof SyntaxError?'Expected valid JSON.':'The local operation failed.'}; }
export async function capabilities(name, offline=false) {
  if (name && !schemas.has(name)) fail('UNKNOWN_ACTION','Unknown action name.');
  const actions=catalog.actions.filter(a=>!name || a.name===name).map(a=>({...a,supported:supported.has(a.name),platforms:supported.has(a.name)?['darwin','linux']:['darwin']}));
  const metadata={version,app_version:version,platform:'linux',source:offline?'bundled_cli':'linux_companion',live:!offline,verified_available:!offline,config_path:configPath(),limitations:['X11 capture (Wayland via grim)','Explicit pixel geometry; no Live Text targeting','Video-only recording (no microphone, system audio, webcam or window capture)','Windows: X11, Hyprland (Omarchy) or Sway; clipboard: xclip or wl-clipboard','No native UI, meetings or dictation']};
  return name ? {...actions[0],...metadata,grants:await grants()} : {...metadata,permissions:await grants(),actions};
}
async function markupThemeInfo(){const t=await markupTheme();return {source:t.source,name:t.name,colors:t.colors};}
export async function doctor() {
  const deps=await dependencies();
  let desktop; try { desktop=await screens(); } catch(error) { desktop={ok:false,error:errorData(error)}; }
  return {platform:'linux',version,permissions:await grants(),system_policy:{path:systemPolicyPath,present:(await systemGrants())!==null},markup_theme:await markupThemeInfo(),config_path:configPath(),brain_root:rootPath(),dependencies:deps,desktop,ready:{capture:!!(desktop.displays && (desktop.session==='wayland'?deps.grim:(deps.scrot||deps.import||deps.ffmpeg)) && (deps.magick||deps.convert) && deps.git),markup:!!((deps.magick||deps.convert)&&deps.git),ocr:!!deps.tesseract,library:!!deps.git,recording:!!(desktop.displays && (desktop.session==='wayland'?deps['wf-recorder']:deps.ffmpeg) && deps.git)},note:'Owner grants are required independently of dependency readiness.'};
}
function validate(name,args) {
  if (!schemas.has(name)) fail('UNKNOWN_ACTION', 'Use actions to discover supported action names.');
  if (!supported.has(name)) unsupported(`${name} is not supported on Linux. Use actions to inspect platform support.`);
  if (Buffer.byteLength(JSON.stringify(args))>1024*1024) fail('INVALID_ARGUMENTS','Arguments exceed 1 MiB.');
  const parsed=schemas.get(name).safeParse(args);
  if (!parsed.success) fail('INVALID_ARGUMENTS',parsed.error.issues.map(i=>`${i.path.join('.')}: ${i.message}`).join('; '));
  return parsed.data;
}
export async function dispatch(name,args) {
  args=validate(name,args);
  if (name==='app.doctor') return doctor();
  await authorize(catalog.actions.find(a=>a.name===name).permissions);
  if (name==='screens.list') { const {displays,...desktop}=await screens(); return {result:displays,...desktop}; }
  if (name==='screenshot.image') return new Brain(rootPath()).image({path:(await captureEntry(args.id)).path});
  if (name==='note.create') return saveNote(args);
  if (name==='recording.start') return recording.start(args);
  if (name==='recording.stop') return recording.stop(args);
  if (name==='recording.cancel') return recording.cancel(args);
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
      return {...await saveCapture(await capture({...rest,region:win.region,coordinates:'global'},work)),window_id:win.id,window:{app:win.app,title:win.title}};
    }
    if (name==='screenshot.capture') return await saveCapture(await capture(args,work));
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
    const saved=await saveCapture(result,args.id);
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
  if (name!=='app.doctor') await authorize(catalog.actions.find(a=>a.name===name).permissions);
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
