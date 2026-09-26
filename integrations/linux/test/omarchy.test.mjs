import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { hyprlandWindows, swayWindows, placeWindow } from '../desktop.mjs';
import { parseColors, roles, markupTheme, fallback } from '../theme.mjs';

const monitors=[{id:0,name:'DP-1',activeWorkspace:{id:1},specialWorkspace:{id:0}},{id:1,name:'DP-2',activeWorkspace:{id:3},specialWorkspace:{id:-98}}];
const client=(o)=>({mapped:true,hidden:false,at:[0,0],size:[100,100],workspace:{id:1,name:'1'},pid:10,class:'foot',title:'t',...o});

test('Hyprland windows keep visible mapped clients in focus order with address ids',()=>{
 const w=hyprlandWindows([
  client({address:'0xb',focusHistoryID:1,title:'second'}),
  client({address:'0xa',focusHistoryID:0,title:'first',class:'',initialClass:'kitty'}),
  client({address:'0xc',focusHistoryID:2,workspace:{id:2,name:'2'}}),
  client({address:'0xd',focusHistoryID:3,hidden:true}),
  client({address:'0xe',focusHistoryID:4,mapped:false}),
  client({address:'0xf',focusHistoryID:5,workspace:{id:-98,name:'special:scratch'},floating:true,at:[-50,20]}),
 ],monitors);
 assert.deepEqual(w.map(x=>x.id),['0xa','0xb','0xf']);
 assert.equal(w[0].app,'kitty');assert.equal(w[0].focused,true);assert.equal(w[1].focused,false);
 assert.deepEqual(w[2].frame,[-50,20,100,100]);assert.equal(w[2].floating,true);
 assert.deepEqual(hyprlandWindows(null,monitors),[]);
});

test('Sway windows walk tiling and floating nodes and put focus first',()=>{
 const tree={type:'root',nodes:[{type:'output',nodes:[{type:'workspace',name:'1',nodes:[
  {type:'con',id:5,pid:1,visible:true,app_id:'foot',name:'term',rect:{x:0,y:0,width:640,height:720}},
  {type:'con',id:6,pid:2,visible:false,app_id:'hidden',name:'tab',rect:{x:0,y:0,width:1,height:1}},
 ],floating_nodes:[{type:'floating_con',id:7,pid:3,visible:true,focused:true,window_properties:{class:'Firefox'},name:'web',rect:{x:100,y:50,width:400,height:300}}]}]}]};
 const w=swayWindows(tree);
 assert.deepEqual(w.map(x=>x.id),['7','5']);
 assert.equal(w[0].app,'Firefox');assert.equal(w[0].floating,true);assert.equal(w[0].workspace,'1');
});

test('placeWindow converts to bottom-left regions, honours negative origins and clips to one display',()=>{
 const desktop={session:'wayland',origin:[-1000,0],width:2920,height:1080,displays:[
  {selector:'left',x:0,y:0,width:1000,height:1080},{selector:'main',x:1000,y:0,width:1920,height:1080}]};
 const inside=placeWindow({frame:[100,80,400,300]},desktop);
 assert.deepEqual(inside.region,[1100,700,400,300]);assert.equal(inside.display,'main');assert.equal(inside.clipped,undefined);
 const straddle=placeWindow({frame:[-200,0,600,100]},desktop);
 assert.equal(straddle.display,'main');assert.deepEqual(straddle.region,[1000,980,400,100]);assert.equal(straddle.clipped,true);
 const gone=placeWindow({frame:[5000,0,10,10]},desktop);
 assert.equal(gone.offscreen,true);assert.equal(gone.region,null);
});

test('Omarchy colors.toml maps to markup roles and ignores invalid values',()=>{
 const c=parseColors('# theme\naccent = "#7aa2f7"\nred = "#f7768e" # comment\nyellow="#e0af68"\nmode = "dark"\nbad = unquoted\n');
 assert.deepEqual(roles(c),{arrow:'#f7768e',box:'#7aa2f7',highlight:'#e0af68',text:'#7aa2f7'});
 assert.deepEqual(roles({accent:'#123456'}),{arrow:'#123456',box:'#123456',highlight:'#123456',text:'#123456'});
 assert.equal(roles({accent:'red'}),null);
 assert.equal(roles({accent:'#12345'}),null);
});

test('markupTheme reads the current Omarchy theme, supports legacy paths, pinning and opt-out',async t=>{
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-omarchy-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const env={XDG_STATE_HOME:path.join(base,'state'),XDG_CONFIG_HOME:path.join(base,'config')};
 assert.deepEqual(await markupTheme(env),{name:null,source:'default',colors:fallback});
 const legacy=path.join(base,'config/omarchy/current/theme');await mkdir(legacy,{recursive:true});
 await writeFile(path.join(legacy,'colors.toml'),'accent = "#111111"\n');
 assert.equal((await markupTheme(env)).colors.box,'#111111');
 const cur=path.join(base,'state/omarchy/current');await mkdir(path.join(cur,'theme'),{recursive:true});
 await writeFile(path.join(cur,'theme/colors.toml'),'accent = "#7aa2f7"\nred = "#f7768e"\n');
 await writeFile(path.join(cur,'theme.name'),'tokyo-night\n');
 const t1=await markupTheme(env);
 assert.equal(t1.source,'omarchy');assert.equal(t1.name,'tokyo-night');assert.equal(t1.colors.arrow,'#f7768e');assert.equal(t1.colors.highlight,'#7aa2f7');
 assert.equal((await markupTheme({...env,MYMAN_MARKUP_THEME:'none'})).source,'default');
 assert.equal((await markupTheme({...env,MYMAN_MARKUP_THEME:path.join(legacy,'colors.toml')})).colors.box,'#111111');
});

test('Hyprland CLI lists windows and captures one by address through grim',async t=>{
 const {execFile}=await import('node:child_process');const {promisify}=await import('node:util');const exec=promisify(execFile);
 const {readFile}=await import('node:fs/promises');
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-hypr-win-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const bin=path.join(base,'bin'),config=path.join(base,'config/myman');await mkdir(bin);await mkdir(config,{recursive:true,mode:0o700});
 await writeFile(path.join(config,'agents.json'),JSON.stringify({version:1,grants:{enabled:true,capture:true}}),{mode:0o600});
 const script=(body)=>`#!${process.execPath}\n${body}\n`;
 const mons=[{id:0,name:'DP-1',width:1920,height:1080,x:0,y:0,scale:1,focused:true,activeWorkspace:{id:1},specialWorkspace:{id:0}}];
 const clients=[{address:'0x55d0',mapped:true,hidden:false,at:[100,50],size:[640,400],workspace:{id:1,name:'1'},class:'Alacritty',title:'nvim',pid:42,focusHistoryID:0},
  {address:'0x55e0',mapped:true,hidden:false,at:[0,0],size:[10,10],workspace:{id:4,name:'4'},class:'chromium',title:'offscreen',pid:43,focusHistoryID:1}];
 await writeFile(path.join(bin,'hyprctl'),script(`const a=process.argv.slice(2);process.stdout.write(JSON.stringify(a.includes('clients')?${JSON.stringify(clients)}:${JSON.stringify(mons)}))`),{mode:0o755});
 await writeFile(path.join(bin,'grim'),script(`const fs=require('node:fs');const cp=require('node:child_process');const a=process.argv.slice(2);fs.writeFileSync(${JSON.stringify(path.join(base,'args.json'))},JSON.stringify(a));const size=a[a.indexOf('-g')+1].split(' ')[1];cp.execFileSync(process.env.TEST_IM,['-size',size,'xc:red',a.at(-1)]);`),{mode:0o755});
 const {command}=await import('../system.mjs');const im=await command('magick')||await command('convert');assert.ok(im);
 const env={...process.env,PATH:bin+path.delimiter+process.env.PATH,TEST_IM:im,WAYLAND_DISPLAY:'wayland-fixture',HYPRLAND_INSTANCE_SIGNATURE:'fixture',DISPLAY:':invalid',XDG_CONFIG_HOME:path.dirname(config),XDG_STATE_HOME:path.join(base,'state'),MYMAN_BRAIN_ROOT:path.join(base,'Brain')};
 for(const entry of ['cli.mjs','bundle/cli.mjs']) {
  const run=async args=>JSON.parse((await exec(process.execPath,[new URL('../'+entry,import.meta.url).pathname,...args,'--json'],{env,timeout:90000})).stdout);
  const list=(await run(['windows','list'])).result;
  assert.deepEqual(list.map(w=>w.id),['0x55d0']);assert.deepEqual(list[0].region,[100,630,640,400]);
  const raw=await run(['screenshot','--window-id','0x55d0']),shot=raw.result??raw;
  assert.equal(shot.window_id,'0x55d0');assert.equal(shot.width,640);assert.equal(shot.height,400);
  assert.deepEqual(JSON.parse(await readFile(path.join(base,'args.json'),'utf8')).slice(2,4),['-g','100,50 640x400']);
 }
});
