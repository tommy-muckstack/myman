import { run, exitCode } from './app-cli.mjs';
import { errorResult } from './tools.mjs';
try {
  const result=await run(process.argv.slice(2));
  if(result.help)console.log(process.argv.includes('--json')?JSON.stringify({ok:true,help:result.help}):result.help);
  else console.log(JSON.stringify(result));
  const error=result.error??result.job?.error;
  if(error)process.exitCode=exitCode(error.code);
} catch(error){
  const result=errorResult(error);
  if(error instanceof SyntaxError || error.code?.startsWith('ERR_PARSE_ARGS'))result.error={code:'INVALID_ARGUMENTS',message:'Check syntax with --help; arguments must be valid JSON.'};
  if(['ENOENT','EACCES','EISDIR'].includes(error.code))result.error={code:'INVALID_ARGUMENTS',message:'Input file is missing, unreadable, or not a regular file.'};
  console.log(JSON.stringify({ok:false,...result}));process.exitCode=exitCode(result.error.code);
}
