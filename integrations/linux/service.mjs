import { mkdir, mkdtemp, readdir, rm, stat } from 'node:fs/promises';
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
import { atomic, authorize, configPath, dependencies, directory, fail, grants, readSafe, rootPath, statePath, unsupported } from './system.mjs';

export const version='0.13.0';
export const supported=new Set(['app.doctor','screens.list','screenshot.capture','screenshot.edit','note.create','screenshot.image']);
const schemas=new Map(catalog.actions.map(a=>[a.name,z.fromJSONSchema(a.inputSchema)]));
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function errorData(error) { return {code:error.code || (error instanceof SyntaxError?'INVALID_ARGUMENTS':'INTERNAL_ERROR'),message:error.code?error.message:error instanceof SyntaxError?'Expected valid JSON.':'The local operation failed.'}; }
export async function capabilities(name, offline=false) {
  if (name && !schemas.has(name)) fail('UNKNOWN_ACTION','Unknown action name.');
  const actions=catalog.actions.filter(a=>!name || a.name===name).map(a=>({...a,supported:supported.has(a.name),platforms:supported.has(a.name)?['darwin','linux']:['darwin']}));
  const metadata={version,app_version:version,platform:'linux',source:offline?'bundled_cli':'linux_companion',live:!offline,verified_available:!offline,config_path:configPath(),limitations:['X11 capture only','Explicit pixel geometry; no Live Text targeting','No native UI, meetings, dictation, recording or clipboard']};
  return name ? {...actions[0],...metadata,grants:await grants()} : {...metadata,permissions:await grants(),actions};
}
export async function doctor() {
  const deps=await dependencies();
  let desktop; try { desktop=await screens(); } catch(error) { desktop={ok:false,error:errorData(error)}; }
  return {platform:'linux',version,permissions:await grants(),config_path:configPath(),brain_root:rootPath(),dependencies:deps,desktop,ready:{capture:!!(desktop.displays && (deps.scrot||deps.import||deps.ffmpeg) && (deps.magick||deps.convert) && deps.git),markup:!!((deps.magick||deps.convert)&&deps.git),ocr:!!deps.tesseract,library:!!deps.git},note:'Owner grants are required independently of dependency readiness.'};
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
  const dir=await directory(path.join(statePath(),'work'),true,true);
  const work=await mkdtemp(path.join(dir,'capture-'));
  try {
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
    return await saveCapture(result,args.id);
  } finally { await rm(work,{recursive:true,force:true}); }
}
const receiptPath=id=>{ if(!uuid.test(id || ''))fail('INVALID_ARGUMENTS','Job/request IDs must be UUIDs.');return path.join(statePath(),'jobs',`${id.toLowerCase()}.json`); };
const alive=pid=>{ try { process.kill(pid,0); return true; } catch(error) { return error.code==='EPERM'; } };
export async function job(id) {
  const file=receiptPath(id);
  let receipt; try { receipt=JSON.parse((await readSafe(file,2*1024*1024,true)).toString()); }
  catch(error) { if(error.code==='ENOENT')fail('UNKNOWN_JOB','No receipt exists for that request ID.');throw error; }
  if (receipt.state==='running' && ((receipt.pid && !alive(receipt.pid)) || (!receipt.pid && Date.now()-Date.parse(receipt.created_at)>30_000))) {
    receipt=JSON.parse((await readSafe(file,2*1024*1024,true)).toString());
    if (receipt.state !== 'running') { const {arguments:args,fingerprint,pid,...publicJob}=receipt; return {ok:true,job:publicJob,launch_id:receipt.launch_id,recovered:true}; }
    receipt={...receipt,state:'interrupted',error:{code:'JOB_INTERRUPTED',message:'Worker stopped. Inspect the Brain and receipt before starting new work; this request will never replay.'}};
    await atomic(file,JSON.stringify(receipt));
  }
  const {arguments:args,fingerprint,pid,...publicJob}=receipt;
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
  const {open}=await import('node:fs/promises');
  let handle;
  try { handle=await open(file,'wx',0o600); }
  catch(error) {
    if(error.code!=='EEXIST')throw error;
    const previous=JSON.parse((await readSafe(file,2*1024*1024,true)).toString());
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
  const file=receiptPath(id), receipt=JSON.parse((await readSafe(file,2*1024*1024,true)).toString());
  if(receipt.state!=='running'||receipt.pid)return;
  // Only the parent that exclusively created the receipt starts a worker.
  receipt.pid=process.pid;
  await atomic(file,JSON.stringify(receipt));
  try { receipt.result=await dispatch(receipt.action,receipt.arguments);receipt.state='succeeded'; }
  catch(error) { receipt.state='failed';receipt.error=errorData(error); }
  receipt.finished_at=new Date().toISOString();
  await atomic(file,JSON.stringify(receipt));
}
