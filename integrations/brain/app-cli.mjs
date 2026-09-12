import { parseArgs } from 'node:util';
import { readFile, stat } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { catalog, describe, invoke, request } from './actions.mjs';
import { Brain, BrainError } from './brain.mjs';
import { execute } from './tools.mjs';

const fail = message => { throw new BrainError('INVALID_ARGUMENTS', message); };
const strings = ['enabled','auto-record-meetings','app','root','mode','request-id','query','kind','id','session-id','title','body','body-file','file','path','ops','ops-file','display','window-id','region','coordinates','mic','system-audio','webcam','format','text','color','background','background-color','corner-radius','expected-updated-at','item-id','target-id','notes','due','name','to','key','value','state','after','before','meeting','theme','limit','offset','wait-timeout'];
const booleans = ['help','json','wait','wait-ready','no-wait','open-editor','save-only','save','clipboard','dry-run','confirm','text-only','image','captured-only','clear-due','unique','pinned-only'];
const options = Object.fromEntries([...strings.map(key=>[key,{type:'string'}]),...booleans.map(key=>[key,{type:'boolean'}]),...['tag','exclude-tag','participant'].map(key=>[key,{type:'string',multiple:true}])]);
for(const action of catalog.actions)for(const [key,schema]of Object.entries(action.inputSchema.properties)){
  const flag=key.replaceAll('_','-');if(!options[flag])options[flag]={type:schema.type==='boolean'?'boolean':'string'};
}
const common = ['json','root','wait','wait-ready','no-wait','request-id','wait-timeout','mode'];
const legacy = {open:'open',launcher:'open',screenshot:'screenshot',note:'note',dictation:'dictation',meeting:'meeting','cancel-meeting':'cancel-meeting',record:'record',settings:'settings'};
const pairs = {
  'note create':'note.create','note append':'note.append','note update':'note.update','note open':'item.open',
  'meeting start':'meeting.start','meeting stop':'meeting.stop','meeting cancel':'meeting.discard','meeting rename':'meeting.rename','meeting notes':'meeting.notes',
  'dictation start':'dictation.start','dictation stop':'dictation.stop','dictation cancel':'dictation.cancel',
  'record start':'recording.start','record stop':'recording.stop','record cancel':'recording.cancel','record microphone':'recording.microphone',
  'editor open':'item.open','editor save':'screenshot.edit','capture import':'screenshot.import','capture ocr':'screenshot.ocr','capture image':'screenshot.image','capture copy':'clipboard.write','capture remove-background':'screenshot.remove_background',
  'clipboard read':'clipboard.read','clipboard write':'clipboard.write',
  'library read':'item.read','library open':'item.open','library related':'item.related','library rename':'item.rename','library pin':'item.pin','library unpin':'item.pin','library hide':'item.exclude','library unhide':'item.exclude','library delete':'item.delete',
  'theme rename':'theme.rename','theme pin':'theme.pin','theme unpin':'theme.pin','theme dismiss':'theme.dismiss','theme merge':'theme.merge','theme add':'theme.assign','theme remove':'theme.assign',
  'task add':'task.create','task create':'task.create','task update':'task.update','task complete':'task.update','task reopen':'task.update','task delete':'task.delete',
  'font create':'font.create','font open':'font.open','font file':'font.file',
  'settings get':'settings.read','settings set':'settings.update','history clear':'history.clear',
  'screens list':'screens.list','windows list':'windows.list',
};
export const help = `My Man — local tools for humans and agents (Node 22+)
Usage: myman <resource> <action> [flags] --json

screenshot --mode agent --display main --region x,y,w,h --wait --json
annotate --id ID --ops-file ops.json [--dry-run] [--clipboard] --json
record start|status|stop|cancel  meeting start|status|stop|cancel|rename|notes
dictation start|status|stop|cancel  (stop/cancel require --session-id from start)
note create|append|update|open --body TEXT|--body-file FILE|- [--title TITLE]
library search|recent|read|open|related|rename|pin|unpin|hide|unhide|delete
theme list|rename|pin|unpin|dismiss|merge|add|remove  task list|add|update|complete|reopen|delete
capture import|ocr|image|copy|remove-background  editor open|save
font create|open|file  clipboard read|write  settings get|set  history clear
screens list  windows list  doctor  latest --kind screenshots
capture-markup --mode agent --region x,y,w,h --ops-file ops.json

Discovery: actions [action.name] (complete JSON schemas); invoke <action.name> [JSON]
Jobs: --no-wait returns a job ID; job UUID polls it. --request-id UUID deduplicates retries.
Deletion: enable library access in Settings → Agents AND pass --confirm.
Capture/markup/recording/library grants start off; the CLI cannot enable them.
Geometry: --display + --region uses display-local points, top-left. Region alone uses
AppKit global points, bottom-left. Markup uses original image pixels, top-left.
--window-id selects a real window; windows list discovers IDs. No pointer automation.
Legacy single commands open|screenshot|note|dictation|meeting|cancel-meeting|record|settings
open their existing UI. Geometry requires --mode agent; explicit start/stop imply agent mode.
Retrieval: status|search|recent|collect|meetings|screenshots|recordings|notes|dictations|themes|tasks|read|image [JSON]
--root selects only the exported Brain; app actions always control this Mac's running app.
JSON: one object on stdout, including errors. Exit 0 success, 2 OS permission, 3 cancelled,
4 agent disabled, 5 invalid args, 6 action/setup failure, 7 timeout. No automatic replay.
`;

async function input(file) {
  if (file !== '-') { const info=await stat(file); if(!info.isFile() || info.size>1024*1024) fail('Input must be a file up to 1 MiB.'); return readFile(file,'utf8'); }
  let chunks=[],size=0; for await(const chunk of process.stdin){size+=chunk.length;if(size>1024*1024)fail('stdin exceeds 1 MiB.');chunks.push(chunk);} return Buffer.concat(chunks).toString('utf8');
}
const number = value => { const n=Number(value); if(!value?.trim() || !Number.isFinite(n))fail('Expected a finite number.');return n; };
const onOff = value => { if(!['on','off'].includes(value))fail('Use on or off.');return value==='on'; };
function json(value) { try { return JSON.parse(value); } catch { fail('Expected valid JSON.'); } }
function allowed(values, keys) { for(const key of Object.keys(values))if(![...common,...keys].includes(key))fail(`--${key} is not supported by this command.`); }

// Pure command routing apart from bounded input-file reads, so it can be tested
// without opening an app or reading personal captures.
export async function plan(argv) {
  const {values:v,positionals:p}=parseArgs({args:argv,options,allowPositionals:true,strict:true});
  if(v.help || !p.length)return {type:'help'};
  if(v.mode && !['interactive','agent'].includes(v.mode))fail('Mode must be interactive or agent.');
  if(v['no-wait'] && (v.wait || v['wait-ready']))fail('Choose wait or no-wait.');
  const waitMs=v['wait-timeout']===undefined?300000:number(v['wait-timeout'])*1000;
  if(waitMs<0 || waitMs>600000)fail('Wait timeout must be 0–600 seconds.');
  const control={id:v['request-id'],wait:!v['no-wait'],waitMs};
  if(p[0]==='actions'){allowed(v,[]);if(p.length>2)fail('Use actions [name].');return {type:'value',value:describe(p[1])};}
  if(p[0]==='job'){allowed(v,[]);if(p.length!==2)fail('Use job UUID.');return {type:'job',id:p[1]};}
  if(p[0]==='invoke') {allowed(v,[]);if(p.length<2||p.length>3)fail('Use invoke action.name [JSON].');describe(p[1]);return {type:'action',name:p[1],args:p[2]?json(p[2]):{},control,raw:true};}
  if(p.length===1 && legacy[p[0]] && (!v.mode || v.mode==='interactive') && !Object.keys(v).some(k=>!['json','mode'].includes(k)))return {type:'interactive',host:legacy[p[0]]};
  if(v.mode==='interactive')fail('Use the legacy single command for interactive UI, or --mode agent.');
  if(p[0]==='doctor'){allowed(v,[]);if(p.length!==1)fail('Use doctor.');return {type:'doctor',root:v.root,control};}
  if(p[0]==='meeting'&&p[1]==='config'){
    if(p.length!==3||!['get','set'].includes(p[2]))fail('Use meeting config get|set.');
    allowed(v,p[2]==='set'?['auto-record-meetings']:[]);
    if(p[2]==='set'&&v['auto-record-meetings']===undefined)fail('Use --auto-record-meetings on|off.');
    return {type:'action',name:p[2]==='get'?'meeting.config.read':'meeting.config.update',args:p[2]==='get'?{}:{auto_record_meetings:onOff(v['auto-record-meetings'])},control};
  }
  const pair=p.slice(0,2).join(' ');
  let name=pairs[pair], args={}, consumed=2;
  if(['meeting status','record status','dictation status'].includes(pair)){allowed(v,[]);if(p.length!==2)fail('Unexpected arguments.');return {type:'action',name:'app.status',args:{},control,select:p[0]==='record'?'screen_recording':p[0]};}
  if(['screenshot','capture-markup'].includes(p[0])){if(v.mode!=='agent')fail('Geometry capture requires --mode agent.');name=p[0]==='screenshot'?'screenshot.capture':'screenshot.capture_markup';consumed=1;}
  if(p[0]==='annotate'){name='screenshot.edit';consumed=1;}
  if(name){
    if(p.length!==consumed)fail('Unexpected positional arguments.');
    const schema=describe(name).inputSchema;
    const special=[...(schema.properties.body?['body-file','file']:[]),...(schema.properties.annotations?['ops','ops-file','save']:[]),...(schema.properties.open_editor?['save-only','open-editor']:[]),...(schema.properties.microphone?['mic']:[]),...(pair==='capture copy'?['text-only','image']:[]),...(pair==='settings set'?['key','value']:[])];
    allowed(v,[...Object.keys(schema.properties).map(k=>k.replaceAll('_','-')),...special]);
    for(const [key,val] of Object.entries(v)) {
      const target=key.replaceAll('-','_');if(!Object.hasOwn(schema.properties,target))continue;
      args[target]=schema.properties[target].type==='boolean'&&typeof val==='string'?onOff(val):schema.properties[target].type==='number'?number(val):schema.properties[target].type==='array'?(target==='region'||target==='crop'?String(val).split(',').map(number):json(val)):val;
    }
    if(v.region)args.region=v.region.split(',').map(number);
    if(v['body-file']!==undefined || v.file!==undefined){if(v.body!==undefined || (v['body-file']!==undefined&&v.file!==undefined))fail('Choose one body input.');if(!Object.hasOwn(schema.properties,'body'))fail('Body input is not supported.');args.body=await input(v['body-file']??v.file);}
    if(v.ops!==undefined || v['ops-file']!==undefined){
      if(!Object.hasOwn(schema.properties,'annotations'))fail('This command does not accept markup.');
      if(v.ops!==undefined&&v['ops-file']!==undefined)fail('Choose ops or ops-file.');
      const ops=json(v.ops??await input(v['ops-file'])); if(!Array.isArray(ops)||ops.length>100)fail('Expected at most 100 operations.');
      args.annotations=[];
      for(const op of ops){if(!op || typeof op!=='object'||Array.isArray(op))fail('Each operation must be an object.');const {op:type,at,...rest}=op;
        if(type==='crop'){if(args.crop || Object.keys(rest).some(k=>k!=='rect')||at)fail('Use one crop with rect.');args.crop=rest.rect;continue;}
        if(at!==undefined){if(type!=='text'||!Array.isArray(at)||at.length!==2||rest.rect)fail('at requires text and two coordinates.');rest.rect=[...at,1,1];}
        args.annotations.push({...rest,type:type??rest.type});
      }
    }
    if(v['open-editor']&&v['save-only'])fail('Choose open-editor or save-only.');
    if(v['open-editor']){if(!Object.hasOwn(schema.properties,'open_editor'))fail('This action does not open an editor.');args.open_editor=true;}
    for(const [flag,key] of [['mic','microphone'],['system-audio','system_audio'],['webcam','webcam']])if(v[flag]!==undefined){if(!Object.hasOwn(schema.properties,key))fail(`--${flag} is not supported.`);args[key]=onOff(v[flag]);}
    if(['library pin','theme pin'].includes(pair))args.pinned=true;
    if(['library unpin','theme unpin'].includes(pair))args.pinned=false;
    if(pair==='library hide')args.excluded=true;if(pair==='library unhide')args.excluded=false;
    if(pair==='theme remove')args.remove=true;
    if(pair==='task complete')args.done=true;if(pair==='task reopen')args.done=false;
    if(pair==='capture copy' && v['text-only'])args.format='text';
    if(v.image && v['text-only'])fail('Choose text-only or image.');
    if(v.image && pair==='capture copy')args.format='image';
    if(pair==='settings set'){if(!v.key || v.value===undefined)fail('settings set requires --key and --value JSON.');args={[v.key]:json(v.value)};}
    if(name==='screenshot.edit'&&args.dry_run&&(args.clipboard||args.open_editor))fail('dry-run cannot copy or open an editor.');
    return {type:'action',name,args,control};
  }
  let command=p[0], raw={}, aliases=['notes','recordings','dictations','themes'];
  if(['library search','library recent','theme list','task list'].includes(pair)){command=pair==='library search'?'search':pair==='library recent'?'recent':pair==='theme list'?'themes':'tasks';if(p.length!==2)fail('Unexpected arguments.');}
  else if(command==='latest'){if(p.length!==1)fail('Unexpected arguments.');command='recent';raw.limit=1;}
  else {if(p.length>2)fail('Expected optional JSON arguments.');if(p[1])raw=json(p[1]);}
  allowed(v,['query','kind','state','after','before','meeting','theme','app','tag','exclude-tag','participant','unique','pinned-only','limit','offset']);
  for(const [key,value]of Object.entries(v)){if(common.includes(key))continue;const k=({'tag':'tags','exclude-tag':'exclude_tags','participant':'participants'})[key]??key.replaceAll('-','_');if(Object.hasOwn(raw,k))fail(`Duplicate ${key} argument.`);raw[k]=['limit','offset'].includes(key)?number(value):value;}
  if(command==='meetings'){if(raw.after){raw.started_after=raw.after;delete raw.after;}if(raw.before){raw.started_before=raw.before;delete raw.before;}}
  if(aliases.includes(command)){if(raw.kind||raw.kinds)fail('Kind is already selected.');raw.kinds=[command];command='collect';}
  return {type:'read',name:command,args:raw,root:v.root};
}

export function exitCode(code){
  if(/PERMISSION/.test(code))return 2;
  if(/CANCELLED|CANCELED/.test(code))return 3;
  if(['DISABLED','AGENT_DISABLED'].includes(code))return 4;
  if(/INVALID|UNKNOWN|CONFIRMATION_REQUIRED|ID_CONFLICT|SESSION_MISMATCH|EDIT_CONFLICT/.test(code))return 5;
  if(/TIMEOUT/.test(code))return 7;
  return 6;
}
export function unwrap(reply, selection){
  const job=reply.job;
  if(job?.state==='failed')return {ok:false,job_id:job.id,error:job.error,launch_id:reply.launch_id};
  if(job?.state==='running')return {ok:true,pending:true,job_id:job.id,launch_id:reply.launch_id};
  const result=selection?job?.result?.[selection]:job?.result;
  return {ok:true,...(result&&typeof result==='object'&&!Array.isArray(result)?result:{result}),job_id:job?.id,launch_id:reply.launch_id};
}
export async function run(argv, deps={}){
  const task=await plan(argv), call=deps.invoke??invoke;
  if(task.type==='help')return {help};
  if(task.type==='value')return task.value;
  if(task.type==='interactive'){await (deps.open??((host)=>promisify(execFile)('/usr/bin/open',['-g',`myman://${host}`])))(task.host);return {ok:true,interactive:true,dispatched:task.host};}
  if(task.type==='job')return (deps.request??request)({method:'job',id:task.id});
  if(task.type==='read')return execute(new Brain(task.root),task.name,task.args);
  if(task.type==='doctor'){
    let brain,app;try{brain=await execute(new Brain(task.root),'status',{});}catch(error){brain={ok:false,error:{code:error.code??'BRAIN_UNAVAILABLE',message:error.message}};}
    try{app=unwrap(await call('app.doctor',{},task.control));}catch(error){app={ok:false,error:{code:error.code??'APP_UNAVAILABLE',message:error.message}};}
    return {ok:app.ok && brain.ok!==false,app,brain,node:process.versions.node,...(!app.ok?{error:app.error}:brain.ok===false?{error:brain.error}:{})};
  }
  const reply=await call(task.name,task.args,task.control);
  if(reply.job?.state==='running'&&task.control.wait)return {ok:false,pending:true,job_id:reply.job.id,error:{code:'PROCESSING_TIMEOUT',message:'Job continues in My Man. Poll this job_id; do not repeat the action.'}};
  return task.raw?reply:unwrap(reply,task.select);
}
