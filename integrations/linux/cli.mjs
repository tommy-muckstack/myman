#!/usr/bin/env node
import { plan, unwrap, exitCode } from '../brain/app-cli.mjs';
import { Brain } from '../brain/brain.mjs';
import { execute } from '../brain/tools.mjs';
import { capabilities, doctor, errorData, invoke, job, jobs } from './service.mjs';
import { unsupported, fail } from './system.mjs';

const help=`MyMan Linux (agents), Node 22+, local X11 desktop
myman doctor --json
myman screenshot [--display main|INDEX|id:INDEX] [--region x,y,w,h] --json
myman annotate --id SHOT-ID --ops-file ops.json [--dry-run|--preview] --json
myman note create --body TEXT|--body-file FILE|- [--title TITLE] --json
myman search --query TEXT [--kind screenshots|notes] [--root PATH] --json
myman actions [ACTION] [--offline] --json
myman screens list --json; myman capture image --id SHOT-ID --json
myman job UUID --json; myman jobs --json
--request-id UUID deduplicates writes; --no-wait returns a durable job ID.
Regions: global bottom-left, or display-local top-left with --display.
Annotations: arrow, box, highlight, text, pixelate; crop applies last.
Human permissions: ~/.config/myman/agents.json (or XDG_CONFIG_HOME).
All grants start off. CLI and MCP cannot grant access.
Meetings, dictation, Live Text, native UI and recording are unsupported.
`;
export async function main(argv) {
  if (argv.some(v=>v==='--machine'||v.startsWith('--machine=')) || process.env.MYMAN_MACHINE_ID || process.env.MYMAN_AGENT_TOKEN) unsupported('Named Mac agents and remote machine targeting are unavailable on Linux. Run on the intended Linux host with local owner grants.');
  // Linux has no interactive picker. The same agent capture schema is the
  // default, while explicit interactive requests remain unsupported.
  if (argv.includes('--mode=interactive') || argv.some((v,i)=>v==='--mode'&&argv[i+1]==='interactive')) unsupported('The Linux companion has no interactive UI.');
  if (argv[0]==='screenshot' && !argv.some(v=>v==='--mode'||v.startsWith('--mode='))) argv=[...argv,'--mode','agent'];
  if (['meeting','dictation','record','live-text','livetext','cancel-meeting'].includes(argv[0])) unsupported(`${argv[0]} is not supported on Linux.`);
  // library search is a documented keyword query on Linux, using the unchanged
  // Brain reader. Never silently advertise the Mac's semantic search.
  if(argv[0]==='library'&&argv[1]==='search'&&!argv.includes('--offline')) argv=[...argv,'--offline'];
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
