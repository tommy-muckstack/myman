import { parseArgs } from 'node:util';
import { readFile, stat } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { catalog, describe, discover, invoke, request } from './actions.mjs';
import { checkWorkflow } from './workflows.mjs';
import { Brain, BrainError } from './brain.mjs';
import { execute } from './tools.mjs';

const fail = message => { throw new BrainError('INVALID_ARGUMENTS', message); };
const strings = ['machine','enabled','auto-record-meetings','app','root','mode','request-id','query','kind','id','session-id','title','body','body-file','file','path','ops','ops-file','display','window-id','region','coordinates','mic','system-audio','webcam','format','text','color','background','background-color','corner-radius','expected-updated-at','item-id','target-id','notes','due','name','to','key','value','state','after','before','meeting','theme','limit','offset','wait-timeout'];
const booleans = ['help','json','offline','wait','wait-ready','no-wait','open-editor','save-only','save','clipboard','dry-run','preview','confirm','text-only','image','captured-only','clear-due','unique','pinned-only'];
const options = Object.fromEntries([...strings.map(key=>[key,{type:'string'}]),...booleans.map(key=>[key,{type:'boolean'}]),...['tag','exclude-tag','participant'].map(key=>[key,{type:'string',multiple:true}])]);
for(const action of catalog.actions)for(const [key,schema]of Object.entries(action.inputSchema.properties)){
  const flag=key.replaceAll('_','-');if(!options[flag])options[flag]={type:schema.type==='boolean'?'boolean':'string'};
}
const common = ['machine','json','root','wait','wait-ready','no-wait','request-id','wait-timeout','mode'];
const legacy = {open:'open',launcher:'open',screenshot:'screenshot',note:'note',dictation:'dictation',meeting:'meeting','cancel-meeting':'cancel-meeting',record:'record',settings:'settings'};
const pairs = {
  'tool evaluate':'tool.evaluate', 'timer start':'timer.start', 'timer status':'timer.status',
  'timer pause':'timer.pause', 'timer resume':'timer.resume', 'timer cancel':'timer.cancel',
  'reminder create':'reminder.create', 'reminder list':'reminder.list', 'reminder cancel':'reminder.cancel',
  'calendar list':'calendar.list',
  'workflow templates':'workflow.templates',
  'dictation history':'dictation.history',
  'dictation correction':'dictation.correction',
  'dictation style':'dictation.style',
  'share publish':'share.publish',
  'share list':'share.list',
  'share revoke':'share.revoke',
  'workflow context':'workflow.context',
  'workflow cancel':'workflow.cancel',
  'meeting speaker':'meeting.speaker',
  'workflow handshake':'workflow.handshake',
  'workflow open':'workflow.open',
  'decision list':'decision.list',
  'decision create':'decision.create',
  'decision followup':'decision.followup',
  'capture float':'capture.float',
  'capture scroll start':'capture.scroll.start',
  'capture scroll status':'capture.scroll.status',
  'capture scroll stop':'capture.scroll.stop',
  'capture scroll cancel':'capture.scroll.cancel',
  'brief create':'brief.create','brief open':'brief.open',
  'brief list':'brief.list',
  'brief read':'brief.read',
  'brief handoff':'brief.handoff',
  'brief refresh':'brief.refresh',
  'brief submit':'brief.submit',
  'brief review':'brief.review',
  'brief delete':'brief.delete',
  'brief export':'brief.export',

  'machine current':'machine.current','agent whoami':'agent.whoami','agent list':'agent.list','resource version':'resource.version',
  'bundle create':'bundle.create','bundle list':'bundle.list','bundle read':'bundle.read','bundle update':'bundle.update','bundle delete':'bundle.delete',
  'handoff create':'handoff.create','handoff list':'handoff.list','handoff read':'handoff.read','handoff update':'handoff.update',
  'collaboration events':'collaboration.events','lease acquire':'lease.acquire','lease release':'lease.release','session transfer':'session.transfer',
  'note create':'note.create','note append':'note.append','note update':'note.update','note open':'item.open',
  'meeting start':'meeting.start','meeting stop':'meeting.stop','meeting cancel':'meeting.discard','meeting rename':'meeting.rename','meeting notes':'meeting.notes',
  'dictation start':'dictation.start','dictation stop':'dictation.stop','dictation cancel':'dictation.cancel',
  'record status':'recording.status','record result':'recording.status','record pause':'recording.pause','record resume':'recording.resume','record frames':'recording.frames','record export':'recording.export','record start':'recording.start','record stop':'recording.stop','record cancel':'recording.cancel','record microphone':'recording.microphone',
  'editor open':'item.open','editor save':'screenshot.edit','capture import':'screenshot.import','capture compare':'screenshot.compare','capture targets':'screenshot.targets','capture ocr':'screenshot.ocr','capture image':'screenshot.image','capture copy':'clipboard.write','capture remove-background':'screenshot.remove_background',
  'clipboard read':'clipboard.read','clipboard write':'clipboard.write',
  'library read':'item.read','library open':'item.open','library related':'item.related','library rename':'item.rename','library pin':'item.pin','library unpin':'item.pin','library hide':'item.exclude','library unhide':'item.exclude','library delete':'item.delete',
  'theme rename':'theme.rename','theme pin':'theme.pin','theme unpin':'theme.pin','theme dismiss':'theme.dismiss','theme merge':'theme.merge','theme add':'theme.assign','theme remove':'theme.assign',
  'task add':'task.create','task create':'task.create','task update':'task.update','task complete':'task.update','task reopen':'task.update','task delete':'task.delete',
  'font create':'font.create','font open':'font.open','font file':'font.file','font quality':'font.quality','font match':'font.match','font preview':'font.preview',
  'note attach':'note.attach','library search':'capture.search',
  'settings get':'settings.read','settings set':'settings.update','history clear':'history.clear',
  'screens list':'screens.list','windows list':'windows.list',
};
export const help = `My Man — local tools for humans and agents (Node 22+)
Usage: myman <resource> <action> [flags] --json

timer start --seconds 600; timer status|pause|resume|cancel (--session-id for controls)
reminder create --seconds 600 --message "Take pizza out"; reminder list|cancel
tool evaluate --input "8am in Iceland"; calendar list --after ISO --before ISO
screenshot --mode agent --display main --region x,y,w,h --wait --json
annotate --id ID --ops-file ops.json [--preview|--dry-run] [--clipboard] --json
record start|status|result|pause|resume|stop|cancel|frames|export  meeting start|status|stop|cancel|rename|notes
dictation start|status|stop|cancel  (stop/cancel require --session-id from start)
note create|append|update|open --body TEXT|--body-file FILE|- [--title TITLE]
note attach --id NOTE-ID --source-id SHOT-ID|--path FILE [--alt TEXT]
library search|recent|read|open|related|rename|pin|unpin|hide|unhide|delete
theme list|rename|pin|unpin|dismiss|merge|add|remove  task list|add|update|complete|reopen|delete
capture import|compare|targets|ocr|image|copy|remove-background  editor open|save
font match|create|preview|quality|open|file  clipboard read|write  settings get|set  history clear
screens list  windows list  doctor  workflow check|templates  latest --kind screenshots
brief create|list|read|open|handoff|refresh|submit|review|delete|export
brief read --id ID --include-context returns timestamped frames and untimed transcript text.
capture-markup --mode agent --region x,y,w,h --ops-file ops.json

Collaboration: agent whoami|list; machine current; --machine ID verifies the selected Mac.
Set MYMAN_AGENT_TOKEN and MYMAN_MACHINE_ID in the host environment; never put tokens in prompts.
bundle create|list|read|update|delete; handoff create|list|read|update; collaboration events
lease acquire|release; session transfer; resource version --kind task|theme|item --id ID
Bundles share references and revisions, handoffs never launch agents or send messages.
Named agents need revision guards on in-place edits. Recording sessions belong to their creator.

Wait: wait --id ID --stage ocr|indexed|transcript|notes|file|export --timeout 120
Or wait --job-id UUID / --session-id ID. No action is started or replayed.
Compare: capture compare --before-id ID --after-id ID [--ignore-rects JSON]
Video: record export --id ID --edits JSON (caption/step/title/zoom/redact).
Media: record start --window-id ID --max-duration 30; record result --session-id ID
record frames --id ID --times 0,2,5; record export --id ID --start 1 --end 10 --max-bytes 20000000
Markup: capture targets --id ID --query TEXT; ops accept target_text or target_region.
Ambiguous targets return candidates without saving. Preview paths expire after an hour.
Discovery: actions [action.name] queries the running app; --offline reads bundled schemas.
Check live/verified_available before acting. invoke <action.name> [JSON] checks app support.
Search: library search --query TEXT uses native fuzzy/semantic search; --offline uses Brain keywords.
Fonts: font match --id SHOT-ID; font create --id SHOT-ID --name NAME; font preview --id NOTE-ID.
Matching compares bundled styles, not an exact font identity. Saved results include .otf and specimen paths.
Jobs: --no-wait returns a job ID; job UUID polls it; jobs lists recent durable receipts.
--request-id UUID deduplicates retries. After interruption inspect receipts; never replay unknown work.
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
  if(p[0]==='actions'){allowed(v,['offline']);if(p.length>2)fail('Use actions [name].');return {type:'discovery',name:p[1],offline:!!v.offline};}
  if(p[0]==='wait'){allowed(v,['id','job-id','session-id','stage','timeout']);if(p.length!==1)fail('Use wait with a resource ID.');const args={};for(const k of ['id','job-id','session-id','stage','timeout'])if(v[k]!==undefined)args[k.replaceAll('-','_')]=k==='timeout'?number(v[k]):v[k];return {type:'action',name:'app.wait',args,control};}
  if(p[0]==='jobs'){allowed(v,[]);if(p.length!==1)fail('Use jobs.');return {type:'jobs'};}
  if(p[0]==='job'){allowed(v,[]);if(p.length!==2)fail('Use job UUID.');return {type:'job',id:p[1]};}
  if(p[0]==='invoke') {allowed(v,[]);if(p.length<2||p.length>3)fail('Use invoke action.name [JSON].');return {type:'action',name:p[1],args:p[2]?json(p[2]):{},control,raw:true};}
  if(p.length===1 && legacy[p[0]] && (!v.mode || v.mode==='interactive') && !Object.keys(v).some(k=>!['json','mode'].includes(k)))return {type:'interactive',host:legacy[p[0]]};
  if(v.mode==='interactive')fail('Use the legacy single command for interactive UI, or --mode agent.');
  if(p[0]==='workflow'&&p[1]==='check'){allowed(v,[]);if(p.length!==2)fail('Use workflow check.');return {type:'workflow-check',control};}
  if(p[0]==='doctor'){allowed(v,[]);if(p.length!==1)fail('Use doctor.');return {type:'doctor',root:v.root,control};}
  if(p[0]==='meeting'&&p[1]==='config'){
    if(p.length!==3||!['get','set'].includes(p[2]))fail('Use meeting config get|set.');
    allowed(v,p[2]==='set'?['auto-record-meetings']:[]);
    if(p[2]==='set'&&v['auto-record-meetings']===undefined)fail('Use --auto-record-meetings on|off.');
    return {type:'action',name:p[2]==='get'?'meeting.config.read':'meeting.config.update',args:p[2]==='get'?{}:{auto_record_meetings:onOff(v['auto-record-meetings'])},control};
  }
  const pair=p.slice(0,2).join(' ');
  if(pair==='library search' && v.offline){allowed(v,['offline','query','kind','limit']);if(p.length!==2||!v.query)fail('Use library search --query TEXT --offline.');return {type:'read',name:'search',args:{query:v.query,...(v.kind?{kind:v.kind}:{}),...(v.limit?{limit:number(v.limit)}:{})},root:v.root};}
  if(pair==='library search' && v.root)fail('Native search uses this app’s library; use --offline with --root for a Brain export.');
  const triple=p.length>=3?p.slice(0,3).join(' '):'';
  let name=pairs[triple]??pairs[pair], args={}, consumed=pairs[triple]?3:2;
  if(['meeting status','dictation status'].includes(pair)){allowed(v,[]);if(p.length!==2)fail('Unexpected arguments.');return {type:'action',name:'app.status',args:{},control,select:p[0]==='record'?'screen_recording':p[0]};}
  if(['screenshot','capture-markup'].includes(p[0])){if(v.mode!=='agent')fail('Geometry capture requires --mode agent.');name=p[0]==='screenshot'?'screenshot.capture':'screenshot.capture_markup';consumed=1;}
  if(p[0]==='annotate'){name='screenshot.edit';consumed=1;}
  if(name){
    if(p.length!==consumed)fail('Unexpected positional arguments.');
    const schema=describe(name).inputSchema;
    const special=[...(schema.properties.body?['body-file','file']:[]),...(schema.properties.annotations?['ops','ops-file','save']:[]),...(schema.properties.open_editor?['save-only','open-editor']:[]),...(schema.properties.microphone?['mic']:[]),...(pair==='capture copy'?['text-only','image']:[]),...(pair==='settings set'?['key','value']:[])];
    allowed(v,[...Object.keys(schema.properties).map(k=>k.replaceAll('_','-')),...special]);
    for(const [key,val] of Object.entries(v)) {
      const target=key.replaceAll('-','_');if(!Object.hasOwn(schema.properties,target))continue;
      const type=schema.properties[target].type;
      if(type==='boolean')args[target]=typeof val==='string'?onOff(val):val;
      else if(type==='number'||type==='integer')args[target]=number(val);
      else if(type==='object')args[target]=json(val);
      else if(type==='array')args[target]=['region','crop','times'].includes(target)?String(val).split(',').map(number):json(val);
      else args[target]=val;
    }
    if(v.region)args.region=schema.properties.region?.type==='object'?json(v.region):v.region.split(',').map(number);
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
    if(name==='screenshot.edit'&&(args.dry_run||args.preview)&&(args.clipboard||args.open_editor))fail('dry-run/preview cannot copy or open an editor.');
    if(args.preview&&args.dry_run)fail('Choose preview or dry-run.');
    if(pair==='record result'&&!args.session_id)fail('record result requires --session-id.');
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
  if(/INVALID|UNKNOWN|CONFIRMATION_REQUIRED|ID_CONFLICT|SESSION_MISMATCH|EDIT_CONFLICT|AMBIGUOUS_TARGET|TARGET_NOT_FOUND/.test(code))return 5;
  if(/TIMEOUT/.test(code))return 7;
  return 6;
}
export function unwrap(reply, selection){
  const job=reply.job;
  if(['failed','interrupted'].includes(job?.state))return {ok:false,job_id:job.id,error:job.error,launch_id:reply.launch_id,recovered:reply.recovered??false};
  if(job?.state==='running')return {ok:true,pending:true,job_id:job.id,launch_id:reply.launch_id};
  const result=selection?job?.result?.[selection]:job?.result;
  return {ok:true,...(result&&typeof result==='object'&&!Array.isArray(result)?result:{result}),job_id:job?.id,launch_id:reply.launch_id};
}
export async function run(argv, deps={}){
  const task=await plan(argv);
  const machine=parseArgs({args:argv,options,allowPositionals:true,strict:true}).values.machine;
  if(machine && ['read','interactive'].includes(task.type))fail('--machine targets native app commands. Run Brain retrieval on the explicitly selected host.');
  const transport=payload=>(deps.request??request)({...payload,...(machine?{machine_id:machine}:{})});
  const call=deps.invoke??((name,args,control)=>invoke(name,args,{...control,transport}));
  if(task.type==='help')return {help};
  if(task.type==='workflow-check')return checkWorkflow({transport,machine:machine??process.env.MYMAN_MACHINE_ID});
  if(task.type==='discovery')return discover(task.name,{transport,offline:task.offline});
  if(task.type==='jobs')return transport({method:'jobs'});
  if(task.type==='value')return task.value;
  if(task.type==='interactive'){await (deps.open??((host)=>promisify(execFile)('/usr/bin/open',['-g',`myman://${host}`])))(task.host);return {ok:true,interactive:true,dispatched:task.host};}
  if(task.type==='job')return transport({method:'job',id:task.id});
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
