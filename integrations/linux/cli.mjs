#!/usr/bin/env node
import { plan, unwrap, exitCode } from '../brain/app-cli.mjs';
import { Brain } from '../brain/brain.mjs';
import { execute } from '../brain/tools.mjs';
import { capabilities, doctor, errorData, invoke, job, jobs } from './service.mjs';
import { unsupported, fail } from './system.mjs';

const help=`MyMan Linux (agents), Node 22+, X11, Hyprland (Omarchy) or Sway
myman doctor --json
myman screenshot [--display main|INDEX|id:INDEX] [--region x,y,w,h] [--window-id ID] --json
myman annotate --id SHOT-ID --ops-file ops.json [--dry-run|--preview] --json
myman note create --body TEXT|--body-file FILE|- [--title TITLE] --json
myman library search --query TEXT [--kind notes|screenshots|recordings] [--after DATE] [--before DATE] [--pinned-only] [--lexical-only] --json
myman library read --id ID --json (body, revision, updated_at, alt text)
myman search --query TEXT [--kind screenshots|notes] [--root PATH] --json (plain Brain keywords, any Brain folder)
myman note update --id NOTE-ID --body TEXT|--body-file FILE --expected-updated-at ISO --json
myman note append --id NOTE-ID --body TEXT [--expected-updated-at ISO] --json
myman note attach --id NOTE-ID --source-id SHOT-ID|--path /abs/image.png --alt TEXT --json
myman library rename|pin|unpin|hide|unhide --id ID [--title T] [--expected-revision N] --json
myman library delete --id ID --confirm --json (library grant; removes owned media)
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
myman windows list --json (X11, Hyprland, Sway; pass id to --window-id)
myman clipboard read --format text|image --json; myman clipboard write --text T --json
myman record start [--display main] [--region x,y,w,h] [--max-duration 30] --json
myman record stop|cancel|status --session-id ID --json (video only; needs recording grant)
Meetings, dictation, Live Text, native UI and audio/webcam recording are unsupported.
`;
export async function main(argv) {
  if (argv.some(v=>v==='--machine'||v.startsWith('--machine=')) || process.env.MYMAN_MACHINE_ID || process.env.MYMAN_AGENT_TOKEN) unsupported('Named Mac agents and remote machine targeting are unavailable on Linux. Run on the intended Linux host with local owner grants.');
  // Linux has no interactive picker. The same agent capture schema is the
  // default, while explicit interactive requests remain unsupported.
  if (argv.includes('--mode=interactive') || argv.some((v,i)=>v==='--mode'&&argv[i+1]==='interactive')) unsupported('The Linux companion has no interactive UI.');
  if (argv[0]==='screenshot' && !argv.some(v=>v==='--mode'||v.startsWith('--mode='))) argv=[...argv,'--mode','agent'];
  if (['meeting','dictation','live-text','livetext','cancel-meeting'].includes(argv[0])) unsupported(`${argv[0]} is not supported on Linux.`);
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
try {
  const result=await main(process.argv.slice(2));
  if(result.help&&!process.argv.includes('--json')) process.stdout.write(result.help);
  else process.stdout.write(JSON.stringify(result)+'\n');
  const error=result.error||result.job?.error;
  if(error) process.exitCode=exitCode(error.code);
} catch(error) {
  if(error.code?.startsWith('ERR_PARSE_ARGS')||error instanceof SyntaxError||['ENOENT','EACCES','EISDIR'].includes(error.code)) error={code:'INVALID_ARGUMENTS',message:error.message};
  const data=errorData(error);
  process.stdout.write(JSON.stringify({ok:false,error:data})+'\n');
  process.exitCode=exitCode(data.code);
}
