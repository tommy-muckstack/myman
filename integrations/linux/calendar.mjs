import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { configPath, directory, readSafe } from './system.mjs';
import { calendarError, calendarRange } from './calendar-range.mjs';

export const calendarConfigPath = () => path.join(path.dirname(configPath()), 'calendar.json');
export async function configuration() {
  let value;
  try {
    await directory(path.dirname(calendarConfigPath()), false, true);
    value = JSON.parse((await readSafe(calendarConfigPath(), 16_384, true)).toString());
  } catch (error) {
    if (error.code === 'ENOENT') throw calendarError('unsupported_on_platform','No local ICS calendar is configured. The owner can configure calendar.json; no online calendar backend is used.');
    throw calendarError('INVALID_CALENDAR_CONFIG','The owner must provide a private, unlinked calendar.json containing valid JSON.');
  }
  if (!value || value.version !== 1 || Object.keys(value).some(k=>!['version','ics_path','time_zone','owner_email'].includes(k)) ||
      typeof value.ics_path !== 'string' || !path.isAbsolute(value.ics_path) || /[\x00-\x1f]/.test(value.ics_path) ||
      typeof value.time_zone !== 'string' || !value.time_zone ||
      (value.owner_email !== undefined && (typeof value.owner_email !== 'string' || !/^[^\s@]+@[^\s@]+$/.test(value.owner_email) || value.owner_email.length>320))) {
    throw calendarError('INVALID_CALENDAR_CONFIG','Use version 1, an absolute local ics_path, an IANA time_zone, and optionally owner_email in calendar.json.');
  }
  try { new Intl.DateTimeFormat('en-US',{timeZone:value.time_zone}).format(0); }
  catch { throw calendarError('INVALID_CALENDAR_CONFIG','calendar.json time_zone must be an IANA time-zone identifier.'); }
  return value;
}
export async function status() {
  try { const config = await configuration(); return {configured:true,source:'local_ics',time_zone:config.time_zone,live_sync:false}; }
  catch (error) { return {configured:false,source:'local_ics',code:error.code}; }
}
export async function freeBusy(args) {
  const range = calendarRange(args), config = await configuration();
  let bytes;
  try { bytes = await readSafe(config.ics_path,8*1024*1024,true); }
  catch { throw calendarError('CALENDAR_UNAVAILABLE','Cannot read the configured ICS as an owned, private, unlinked regular file up to 8 MiB. No free/busy result was returned.'); }
  let text;
  try { text = new TextDecoder('utf-8',{fatal:true}).decode(bytes); }
  catch { throw calendarError('INVALID_ICS','The configured calendar must contain UTF-8 ICS text.'); }
  // ICS recurrence expansion is untrusted CPU work. A separate, bounded worker
  // keeps malformed rules from blocking CLI/MCP; it never accesses the network.
  return new Promise((resolve,reject)=>{
    const worker = new Worker(new URL('./calendar-worker.mjs',import.meta.url), {
      workerData:{text,range,zone:config.time_zone,ownerEmail:config.owner_email},
      resourceLimits:{maxOldGenerationSizeMb:96,stackSizeMb:4},execArgv:[],
    });
    let done = false;
    const finish = (error,result) => {
      if(done) return; done=true; clearTimeout(timer); void worker.terminate();
      error ? reject(error) : resolve(result);
    };
    const timer = setTimeout(()=>finish(calendarError('CALENDAR_LIMIT_EXCEEDED','ICS expansion exceeded three seconds. Use a smaller calendar snapshot; no partial result was returned.')),3000);
    worker.once('message',message=>message.error ? finish(calendarError(message.error.code,message.error.message)) : finish(null,message.result));
    worker.once('error',()=>finish(calendarError('INVALID_ICS','Could not safely parse the configured ICS; no partial result was returned.')));
    worker.once('exit',()=>{if(!done) finish(calendarError('INVALID_ICS','ICS worker stopped without a complete result.'));});
  });
}
