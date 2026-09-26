import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, readFile, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec=promisify(execFile);

// A fake wf-recorder that behaves like the real one on an idle compositor:
// SIGINT only finalizes when a frame arrives, and without --no-damage (-D) an
// unchanged screen never sends one. It has no duration flag of its own.
const fakeRecorder=(log)=>`#!${process.execPath}
const fs=require('node:fs'),cp=require('node:child_process');const a=process.argv.slice(2);
if(a.includes('--help')){process.stdout.write('  -D, --no-damage   request frames even without damage\\n');process.exit(0);}
fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(a)+'\\n');
const out=a[a.indexOf('-f')+1];const started=Date.now();
const finish=()=>{const secs=Math.max(1,Math.round((Date.now()-started)/1000));cp.execFileSync(process.env.TEST_FFMPEG,['-v','error','-y','-f','lavfi','-i','testsrc=size=320x240:rate=10','-t',String(secs),'-pix_fmt','yuv420p',out]);process.exit(0);};
process.on('SIGINT',()=>{ if(a.includes('-D')) finish(); /* else: wait for a frame that never comes */ });
setInterval(()=>{},1000);
`;

test('Wayland recording stops promptly on an idle screen and honours max_duration',{timeout:120000},async t=>{
 const {command}=await import('../system.mjs');const ffmpeg=await command('ffmpeg'),im=await command('magick')||await command('convert');
 if(!ffmpeg||!await command('ffprobe')||!await command('timeout')) return t.skip('ffmpeg, ffprobe and timeout are required');
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-rec-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const bin=path.join(base,'bin'),config=path.join(base,'config/myman'),log=path.join(base,'argv.log');await mkdir(bin);await mkdir(config,{recursive:true,mode:0o700});
 await writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,capture:true,recording:true}}),{mode:0o600});
 await writeFile(path.join(bin,'hyprctl'),`#!${process.execPath}\nprocess.stdout.write(JSON.stringify([{id:0,name:'DP-1',width:1280,height:800,x:0,y:0,scale:1,focused:true}]))\n`,{mode:0o755});
 await writeFile(path.join(bin,'wf-recorder'),fakeRecorder(log),{mode:0o755});
 await writeFile(path.join(bin,'grim'),`#!/bin/sh\nexit 1\n`,{mode:0o755});
 const env={...process.env,PATH:bin+path.delimiter+process.env.PATH,TEST_FFMPEG:ffmpeg,TEST_IM:im,WAYLAND_DISPLAY:'wayland-fixture',HYPRLAND_INSTANCE_SIGNATURE:'fixture',DISPLAY:':invalid',XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(base,'state'),MYMAN_BRAIN_ROOT:path.join(base,'Brain')};
 await mkdir(env.MYMAN_BRAIN_ROOT,{recursive:true});
 for(const entry of ['cli.mjs','bundle/cli.mjs']) {
  const run=async args=>JSON.parse((await exec(process.execPath,[new URL('../'+entry,import.meta.url).pathname,...args,'--json'],{env,timeout:60000})).stdout);
  // Idle screen: stop must finalize well inside the 15 second fallback.
  const s=await run(['record','start','--max-duration','60']);assert.equal(s.backend,'wf-recorder');
  await new Promise(r=>setTimeout(r,1500));
  const t0=Date.now();const done=await run(['record','stop','--session-id',s.session_id]);
  assert.ok(Date.now()-t0<8000,`stop took ${Date.now()-t0}ms`);assert.equal(done.warnings,undefined);assert.ok(done.duration>0);
  assert.ok(JSON.parse((await readFile(log,'utf8')).trim().split('\n').at(-1)).includes('-D'));
  // max_duration ends the recording on its own; stop then just saves it.
  const m=await run(['record','start','--max-duration','2']);
  await new Promise(r=>setTimeout(r,4500));
  assert.equal((await run(['record','status','--session-id',m.session_id])).state,'finished');
  const saved=await run(['record','stop','--session-id',m.session_id]);assert.ok(saved.duration>=1&&saved.duration<=3.5,`duration ${saved.duration}`);
 }
});
