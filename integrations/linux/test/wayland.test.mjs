import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, readFile, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { waylandDesktop, captureRect } from '../images.mjs';
const exec=promisify(execFile);

test('Hyprland logical geometry handles HiDPI, rotation and negative monitor origins',()=>{
 const d=waylandDesktop([
  {id:0,name:'DP-1',width:3840,height:2160,x:0,y:0,scale:2,transform:0,focused:true},
  {id:4,name:'DP-2',width:1920,height:1080,x:-1080,y:-200,scale:1,transform:1},
  {id:7,name:'disabled',disabled:true}
 ],'hyprland');
 assert.deepEqual(d.origin,[-1080,-200]);assert.equal(d.width,3000);assert.equal(d.height,1920);
 assert.deepEqual(d.displays[0].frame,[1080,640,1920,1080]);
 assert.deepEqual(captureRect({display:'DP-2'},d),[0,0,1080,1920]);
 assert.deepEqual(captureRect({display:'main',region:[20,30,200,100]},d),[1100,230,200,100]);
 assert.deepEqual(captureRect({region:[1100,1590,200,100]},d),[1100,230,200,100]);
 assert.throws(()=>waylandDesktop([{name:'bad',width:100,height:100,x:0,y:0,scale:0}],'hyprland'));
 assert.throws(()=>waylandDesktop([],'hyprland'));
});

test('Sway logical rectangles preserve fractional scaling without double scaling',()=>{
 const d=waylandDesktop([{name:'HEADLESS-1',active:true,scale:1.5,rect:{x:0,y:0,width:1280,height:720}}],'sway');
 assert.equal(d.width,1280);assert.equal(d.displays[0].native_scale,1.5);assert.equal(d.displays[0].scale,1);
});

test('Hyprland source and bundle select Wayland over Xwayland and pass native geometry to grim',async t=>{
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-hyprland-'));
 t.after(()=>rm(base,{recursive:true,force:true}));
 const bin=path.join(base,'bin'),config=path.join(base,'config/myman');await mkdir(bin);await mkdir(config,{recursive:true,mode:0o700});
 await writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,capture:true}}),{mode:0o600});
 // Synthetic backend creates the requested solid image; actual protocol capture
 // is tested separately against a real headless compositor in Linux CI.
 const script=(body)=>`#!${process.execPath}\n${body}\n`;
 await writeFile(path.join(bin,'hyprctl'),script(`process.stdout.write(JSON.stringify([{id:0,name:'DP-1',width:800,height:600,x:-800,y:-40,scale:1,focused:true}]))`),{mode:0o755});
 await writeFile(path.join(bin,'grim'),script(`const fs=require('node:fs');const cp=require('node:child_process');const a=process.argv.slice(2);fs.writeFileSync(${JSON.stringify(path.join(base,'args.json'))},JSON.stringify(a));const size=a[a.indexOf('-g')+1].split(' ')[1];cp.execFileSync(process.env.TEST_IM,['-size',size,'xc:red',a.at(-1)]);`),{mode:0o755});
 const {command}=await import('../system.mjs');const im=await command('magick')||await command('convert');assert.ok(im);
 const env={...process.env,PATH:bin+path.delimiter+process.env.PATH,TEST_IM:im,WAYLAND_DISPLAY:'wayland-fixture',HYPRLAND_INSTANCE_SIGNATURE:'fixture',DISPLAY:':invalid',XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(base,'state'),MYMAN_BRAIN_ROOT:path.join(base,'Brain')};
 for(const entry of ['cli.mjs','bundle/cli.mjs']) {
  const cli=new URL('../'+entry,import.meta.url).pathname;
  const {stdout}=await exec(process.execPath,[cli,'screenshot','--display','main','--region','10,20,100,80','--json'],{env,timeout:90000});
  const result=JSON.parse(stdout);assert.equal(result.backend,'grim');assert.equal(result.width,100);assert.equal(result.height,80);
  assert.deepEqual(JSON.parse(await readFile(path.join(base,'args.json'),'utf8')).slice(0,4),['-s','1','-g','-790,-20 100x80']);
 }
});

test('real headless Wayland CLI captures full output and regions and annotates', {skip:process.env.MYMAN_TEST_WAYLAND!=='1'},async t=>{
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-wayland-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const config=path.join(base,'config/myman');await mkdir(config,{recursive:true,mode:0o700});
 await writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,capture:true,markup:true}}),{mode:0o600});
 const env={...process.env,XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(base,'state'),MYMAN_BRAIN_ROOT:path.join(base,'Brain')};
 delete env.HYPRLAND_INSTANCE_SIGNATURE;
 for(const entry of ['cli.mjs','bundle/cli.mjs']) {
  const invoke=async args=>JSON.parse((await exec(process.execPath,[new URL('../'+entry,import.meta.url).pathname,...args,'--json'],{env,timeout:90000})).stdout);
  await mkdir(env.MYMAN_BRAIN_ROOT,{recursive:true});
  const doc=await invoke(['doctor']);assert.equal(doc.app.desktop.session,'wayland');assert.equal(doc.app.ready.capture,true);
  for(const args of [[],['--display','main'],['--region','10,20,100,80'],['--display','main','--region','10,20,100,80']]) {
   const r=await invoke(['screenshot',...args]);assert.equal(r.backend,'grim');assert.equal(r.width,args.includes('--region')?100:1280);assert.equal(r.height,args.includes('--region')?80:800);
   const marked=await invoke(['annotate','--id',r.id,'--ops','[{"op":"box","rect":[5,5,30,20]}]']);assert.equal(marked.source_id,r.id);
  }
 }
});
