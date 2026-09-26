#!/usr/bin/env node
import { plan, unwrap, exitCode } from '../brain/app-cli.mjs';
import { Brain } from '../brain/brain.mjs';
import { execute } from '../brain/tools.mjs';
import { capabilities, doctor, errorData, invoke, job, jobs } from './service.mjs';
import { authorize, unsupported, fail } from './system.mjs';
import { indicator } from './indicator.mjs';
import * as identity from './identity.mjs';
import * as omarchy from './omarchy.mjs';
import { show } from './show.mjs';
import * as dictation from './dictation.mjs';
import * as meeting from './meeting.mjs';
import * as recording from './recording.mjs';
import * as cursor from './cursor.mjs';
import * as studio from './studio.mjs';
import * as demoRunner from './demo.mjs';
import { alternativeFor, human, suggestCommand, suggestFlag } from './guide.mjs';

const help=`MyMan Linux (agents), Node 22+, X11, Hyprland (Omarchy) or Sway
myman doctor --json
myman screenshot [--display main|INDEX|id:INDEX] [--region x,y,w,h] [--window-id ID] --json
myman annotate --id SHOT-ID --ops-file ops.json [--dry-run|--preview] --json
myman capture-markup --mode agent [--region x,y,w,h] --ops-file ops.json --json (capture + markup grants; saves only the marked-up image)
myman capture import --path /abs/image.png|jpg|webp|gif --json (markup grant)
  ops: {"type":"box|highlight|pixelate|text","rect":[x,y,w,h]} or {"type":"arrow","from":[x,y],"to":[x,y]};
  or target on-screen text instead of pixels: {"type":"box","target_text":"Save"} / {"type":"arrow","target_region":"ocr-..."}
myman note create --body TEXT|--body-file FILE|- [--title TITLE] --json
myman library search --query TEXT [--kind notes|screenshots|recordings] [--after DATE] [--before DATE] [--pinned-only] [--lexical-only] --json
myman library read --id ID --json (body, revision, updated_at, alt text)
myman search --query TEXT [--kind screenshots|notes] [--root PATH] --json (plain Brain keywords, any Brain folder)
myman note update --id NOTE-ID --body TEXT|--body-file FILE --expected-updated-at ISO --json
myman note append --id NOTE-ID --body TEXT [--expected-updated-at ISO] --json
myman note attach --id NOTE-ID --source-id SHOT-ID|--path /abs/image.png --alt TEXT --json
myman library rename|pin|unpin|hide|unhide --id ID [--title T] [--expected-revision N] --json
myman library delete --id ID --confirm --json (library grant; removes owned media)
myman library related --id ID --json (links, same window, capture time, title words)
myman task list [--state open|done|all] --json; myman task add --title T [--notes N] [--due DATE] --json
myman task update|complete|reopen --id TASK-ID [--title T] [--notes N] [--due DATE|--clear-due] [--expected-version V] --json
myman task delete --id TASK-ID --confirm --json
myman actions [ACTION] [--offline] --json
myman screens list --json; myman capture image --id SHOT-ID --json
myman job UUID --json; myman jobs --json
--request-id UUID deduplicates writes; --no-wait returns a durable job ID.
Regions: global bottom-left, or display-local top-left with --display.
Annotations: arrow, box, highlight, text, pixelate; crop applies last.
Uncolored markup follows the Omarchy theme; MYMAN_MARKUP_THEME=none|FILE.
Human permissions: ~/.config/myman/agents.json (or XDG_CONFIG_HOME).
All grants start off. CLI and MCP cannot grant access.
myman capture ocr --id SHOT-ID --json (line text + pixel boxes)
myman capture targets --id SHOT-ID [--query TEXT] [--granularity line|word] --json (stable region IDs)
myman capture compare --before-id ID --after-id ID [--ignore-rects JSON] [--threshold 20] --json (library grant)
myman windows list --json (X11, Hyprland, Sway; pass id to --window-id)
myman clipboard read --format text|image --json; myman clipboard write --text T --json
myman record start [--display main] [--region x,y,w,h] [--max-duration 30] [--hide-cursor] --json (--hide-cursor: X11; record polish draws a smooth cursor instead)
myman record stop|cancel|status|pause|resume --session-id ID --json (video only; needs recording grant)
myman timer start --seconds N [--sound-enabled false] --json; myman timer status --json (library grant)
myman timer pause|resume|cancel --session-id ID --json; myman timer sound --session-id ID --enabled true|false --json
myman reminder create --message TEXT --seconds N|--at ISO-WITH-OFFSET --json; myman reminder list|cancel [--id ID] --json
myman record cursor --id REC-ID [--full] --json (pointer path, clicks, typing moments and where the action is)
myman record polish --id REC-ID [--auto-zoom [subtle|normal|strong|1.1-4]] [--cursor [normal|big|huge|1-3]] [--background dusk|ocean|meadow|slate|none] [--background-color '#RRGGBB'] [--corner-radius N] [--music upbeat|calm|cinematic|/path/audio] [--music-volume 0-1] [--title TEXT] [--end TEXT] [--recipe FILE|JSON] [--dry-run] --json (polished copy: smooth zoom, cursor highlight, click ripples, backdrop like the image editor, music ducked under narration)
myman demo --script steps.json [--app 'gnome-calculator'] [--dry-run] --json (one command: open the app, record, run the steps, then polish with zoom, cursor, backdrop, music and title/end cards; X11)
myman record frames --id REC-ID [--times 0,2.5|--count 6] [--width 400] --json (temporary PNGs + contact sheet)
myman record export --id REC-ID [--start S] [--end S] [--max-bytes N] [--edits JSON] --json (new recording; caption/step/title/zoom/redact)
myman agent whoami|list --json; myman machine current --json (named agents: set MYMAN_AGENT_TOKEN)
myman bundle create --title T --item-ids ID,ID [--members AGENT-ID] --json; myman bundle list|read|update|delete
myman handoff create --bundle-id ID --recipient AGENT-ID --instruction TEXT --json; myman handoff list|read|update --state accepted|declined|completed|failed|cancelled
myman lease acquire --resource clipboard|item:ID [--seconds 60] --json; myman lease release --resource R --lease-id L --json
myman collaboration events [--after-cursor N] --json; myman session transfer --session-id ID --recipient AGENT-ID --json
myman show [--note TEXT] (people: drag over part of the screen to save it for your agents)
myman dictation connect|disconnect|status (people: save each Voxtype dictation to the Brain)
myman omarchy install|remove|status (people: SUPER+SHIFT+PRINT for show, plus a MyMan menu under Trigger)
myman agents list|add NAME --scopes capture,markup|revoke ID|require on|off (people only, at a terminal)
myman meeting start [--title TEXT] [--no-system-audio] [--keep-audio] [--max-minutes 240] --json (mic as You, computer audio as Others)
myman meeting stop|cancel [--id ID] [--keep-audio] --json; myman meeting status --json; myman meeting transcribe ID (retry)
  Transcribed on this computer with Whisper (voxtype or whisper.cpp). Agents need the recording and microphone grants.
myman indicator (Waybar-style JSON: is an agent recording or capturing right now?)
Every agent screenshot and recording shows a desktop notification.
Every meeting recording shows a notification and the indicator. Live Text, native UI, live meeting notes and webcam recording are unsupported. Dictation uses Voxtype (see dictation connect).
`;
// Person-only credential management. Never a catalog action, never reachable
// through MCP or the app server, and refused inside an agent's environment.
async function manageAgents(args) {
  const [sub,...rest]=args, flag=n=>{const k=rest.indexOf('--'+n);return k>=0?rest[k+1]:undefined;};
  if (!sub||sub==='list') return identity.listAll();
  if (process.env.MYMAN_AGENT_TOKEN||!process.stdin.isTTY||!process.stdout.isTTY) fail('HUMAN_REQUIRED','Only the person at this computer can change agent credentials, from an interactive terminal (not from an agent).');
  const readline=await import('node:readline/promises'), rl=readline.createInterface({input:process.stdin,output:process.stdout});
  const confirm=async(prompt,expected)=>{ try { if((await rl.question(prompt)).trim()!==expected) fail('CANCELLED','Nothing changed.'); } finally { rl.close(); } };
  if (sub==='add') {
    const name=rest.find(v=>!v.startsWith('--')&&v!==flag('scopes')), scopes=(flag('scopes')??'capture,markup').split(',').map(v=>v.trim()).filter(Boolean);
    await confirm(`Issue a credential named "${name}" with ${scopes.join(', ')} access? Local agents without a credential will then be refused (undo with myman agents require off). Type the name to confirm: `,name);
    const out=await identity.issue(name,scopes);
    return {...out,next:`Give this agent the environment variable MYMAN_AGENT_TOKEN=${out.token}. It is shown only once; revoke with myman agents revoke ${out.agent.id}.`};
  }
  if (sub==='revoke') { const id=rest[0]; await confirm(`Revoke agent ${id}? Type revoke to confirm: `,'revoke'); return identity.revoke(id); }
  if (sub==='require') { const on=rest[0]!=='off'; await confirm(`${on?'Require':'Stop requiring'} named credentials? Type yes: `,'yes'); return identity.setRequired(on); }
  fail('INVALID_ARGUMENTS','Use myman agents list|add NAME --scopes capture,markup|revoke ID|require on|off.');
}
export async function main(argv) {
  // --machine / MYMAN_MACHINE_ID only confirm this is the intended computer.
  const mi=argv.findIndex(v=>v==='--machine'||v.startsWith('--machine='));
  if (mi>=0) { const value=argv[mi].includes('=')?argv[mi].split('=')[1]:argv[mi+1]; argv=argv.filter((_,k)=>k!==mi&&!(k===mi+1&&!argv[mi].includes('='))); await identity.checkMachine(value); }
  else await identity.checkMachine(process.env.MYMAN_MACHINE_ID);
  if (argv[0]==='agents') return manageAgents(argv.slice(1));
  if (argv[0]==='dictation' && argv[1]==='save') { await dictation.save(); process.exit(0); }
  if (argv[0]==='dictation' && argv[1]==='store' && argv[2] && !process.env.MYMAN_AGENT_TOKEN) { await dictation.store(argv[2]); process.exit(0); }
  if (argv[0]==='dictation' && ['connect','disconnect','status'].includes(argv[1])) return dictation[argv[1]]();
  if (argv[0]==='dictation') unsupported('On Linux, people dictate with Voxtype (Omarchy: F9 or Super+Ctrl+X). Run myman dictation connect to save each dictation to your Brain; agents read them with myman library search --kind dictations --json.');
  if (argv[0]==='show') { const k=argv.indexOf('--note'); return show({note:k>=0?argv[k+1]:undefined}); }
  if (argv[0]==='omarchy') { const sub=argv[1]||'status'; if(!['install','remove','status'].includes(sub)) fail('INVALID_ARGUMENTS','Use myman omarchy install|remove|status.'); return omarchy[sub](); }
  // Linux has no interactive picker. The same agent capture schema is the
  // default, while explicit interactive requests remain unsupported.
  if (argv.includes('--mode=interactive') || argv.some((v,i)=>v==='--mode'&&argv[i+1]==='interactive')) unsupported('The Linux companion has no interactive UI.');
  if (argv[0]==='screenshot' && !argv.some(v=>v==='--mode'||v.startsWith('--mode='))) argv=[...argv,'--mode','agent'];
  if (argv[0]==='record' && argv[1]==='track' && argv[2] && !process.env.MYMAN_AGENT_TOKEN) { await recording.trackSession(argv[2]); process.exit(0); }
  if (argv[0]==='record' && argv[1]==='start' && argv.includes('--hide-cursor')) { argv=argv.filter(a=>a!=='--hide-cursor'); await recording.requestHiddenCursor(); }
  if (argv[0]==='record' && argv[1]==='cursor') {
    await authorize(['library']); identity.validate(await identity.authenticate(),['library']);
    const k=argv.indexOf('--id'); return cursor.read(k>=0?argv[k+1]:undefined,{full:argv.includes('--full')});
  }
  if (argv[0]==='demo') {
    await authorize(['recording']); identity.validate(await identity.authenticate(),['recording']);
    const val=f=>{const k=argv.indexOf(f); return k>=0?argv[k+1]:undefined;};
    return demoRunner.demo({script:val('--script'),app:val('--app'),dryRun:argv.includes('--dry-run')});
  }
  if (argv[0]==='record' && argv[1]==='polish') {
    await authorize(['recording']); identity.validate(await identity.authenticate(),['recording']);
    const val=f=>{const k=argv.indexOf(f); return k>=0?argv[k+1]:undefined;};
    let recipe={};
    const raw=val('--recipe');
    if (raw!==undefined) { const { readFile }=await import('node:fs/promises'); const text=raw.trim().startsWith('{')?raw:await readFile(raw,'utf8').catch(()=>fail('INVALID_ARGUMENTS','--recipe must be JSON or a path to a JSON file.')); try { recipe=JSON.parse(text); } catch { fail('INVALID_ARGUMENTS','--recipe is not valid JSON.'); } }
    const k=argv.indexOf('--auto-zoom');
    if (k>=0) { const v=argv[k+1]; recipe={...recipe,zoom:{...(recipe.zoom||{}),auto:true,...(v&&!v.startsWith('--')?{level:v}:{})}}; }
    const bi=argv.indexOf('--background'), bc=argv.indexOf('--background-color'), br=argv.indexOf('--corner-radius');
    if (bi>=0||bc>=0||br>=0) { const prev=typeof recipe.background==='string'?{style:recipe.background}:(recipe.background&&typeof recipe.background==='object'?recipe.background:{}); const b={...prev};
      if (bi>=0) { const v=argv[bi+1]; if (v&&!v.startsWith('--')) b.style=v; }
      if (bc>=0) { b.color=argv[bc+1]; if (bi<0) b.style='custom'; }
      if (br>=0) { const v=Number(argv[br+1]); b.corner_radius=Number.isFinite(v)?v:argv[br+1]; }
      recipe={...recipe,background:b}; }
    const mi=argv.indexOf('--music'), mv=argv.indexOf('--music-volume');
    if (mi>=0||mv>=0) { const prev=typeof recipe.music==='string'?(recipe.music.startsWith('/')?{file:recipe.music}:{track:recipe.music}):(recipe.music&&typeof recipe.music==='object'?recipe.music:{}); const m={...prev};
      if (mi>=0) { const v=argv[mi+1]; if (v&&!v.startsWith('--')) { delete m.track; delete m.file; if (v.startsWith('/')) m.file=v; else m.track=v; } }
      if (mv>=0) { const v=Number(argv[mv+1]); m.volume=Number.isFinite(v)?v:argv[mv+1]; }
      recipe={...recipe,music:m}; }
    for (const key of ['title','end']) { const k=argv.indexOf(`--${key}`); if (k>=0) recipe={...recipe,[key]:argv[k+1]}; }
    const c=argv.indexOf('--cursor');
    if (c>=0) { const v=argv[c+1]; recipe={...recipe,cursor:{...(recipe.cursor||{}),...(v&&!v.startsWith('--')?{size:v}:{})}}; }
    return studio.polish({id:val('--id'),recipe,dryRun:argv.includes('--dry-run')});
  }
  if (argv[0]==='meeting') {
    const val=f=>{const k=argv.indexOf(f); return k>=0?argv[k+1]:undefined;}, has=f=>argv.includes(f);
    const sub=argv[1];
    if (sub==='start') return meeting.start({title:val('--title'),systemAudio:!has('--no-system-audio'),keepAudio:has('--keep-audio'),maxMinutes:val('--max-minutes')??240});
    if (sub==='stop') return meeting.stop({id:val('--id'),keepAudio:has('--keep-audio')?true:undefined});
    if (sub==='cancel') return meeting.cancel({id:val('--id')});
    if (sub==='status') return meeting.status();
    if (sub==='transcribe' && argv[2]) return meeting.resume(argv[2]);
    unsupported('Use myman meeting start|stop|cancel|status. Live meeting notes and the meeting assistant are Mac-only.');
  }
  if (['cancel-meeting'].includes(argv[0])) return meeting.cancel({});
  if (['meeting','dictation','live-text','livetext','cancel-meeting'].includes(argv[0])) unsupported(`${argv[0]} is not supported on Linux.`);
  if (argv[0]==='indicator') return indicator();
  const task=await plan(argv);
  switch(task.type) {
    case 'help': return {help};
    case 'discovery': return capabilities(task.name,task.offline);
    case 'interactive': unsupported('The Linux companion has no native UI.'); break;
    case 'workflow-check': unsupported('Mac brief workflows are unavailable on Linux.'); break;
    case 'job': return job(task.id);
    case 'jobs': return jobs();
    case 'read': return execute(new Brain(task.root),task.name,task.args);
    case 'doctor': {
      let brain; try { brain=await execute(new Brain(task.root),'status'); } catch(error) { brain={ok:false,error:errorData(error)}; }
      const app={ok:true,...await doctor()};
      return {ok:brain.ok!==false,app,brain,node:process.versions.node,...(brain.ok===false?{error:brain.error}:{})};
    }
    case 'action': {
      const reply=await invoke(task.name,task.args,task.control);
      if(reply.job?.state==='running'&&task.control.wait) return {ok:false,pending:true,job_id:reply.job.id,error:{code:'PROCESSING_TIMEOUT',message:'Job continues in the Linux worker. Poll job_id; do not repeat the action.'}};
      return task.raw?reply:unwrap(reply,task.select);
    }
    default: fail('INVALID_ARGUMENTS','Unsupported command.');
  }
}
const argv=process.argv.slice(2);
// JSON for agents and pipes; plain text only for a person at a terminal.
const person=process.stdout.isTTY&&!argv.includes('--json');
function explain(data) {
  if(['INVALID_ARGUMENTS','UNKNOWN_ACTION','UNKNOWN_TOOL'].includes(data.code)) {
    const flag=suggestFlag(data.message), cmd=flag?null:suggestCommand(argv);
    if(cmd) { data.message=`Unknown command "myman ${cmd.typed}".${cmd.suggestions.length?'':' Run myman --help to list commands.'}`; }
    const s=flag||cmd; if(s?.suggestions.length) data.suggestions=s.suggestions.map(x=>x.startsWith('--')?x:`myman ${x}`);
  }
  if(data.code==='unsupported_on_platform'&&!data.alternative) data.alternative=alternativeFor(argv.filter(a=>!a.startsWith('-')).slice(0,2).join(' '));
  return data;
}
function write(result) {
  if(result.help&&!argv.includes('--json')) return process.stdout.write(result.help);
  process.stdout.write(person?human(result):JSON.stringify(result)+'\n');
}
try {
  const result=await main(argv);
  const error=result.error||result.job?.error;
  if(error) explain(error);
  write(result);
  if(error) process.exitCode=exitCode(error.code);
} catch(error) {
  if(error.code?.startsWith('ERR_PARSE_ARGS')||error instanceof SyntaxError||['ENOENT','EACCES','EISDIR'].includes(error.code)) error={code:'INVALID_ARGUMENTS',message:error.message};
  const data=explain(errorData(error));
  write({ok:false,error:data});
  process.exitCode=exitCode(data.code);
}
