import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, realpath, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { describeCapture, recognitionSection } from '../library.mjs';
const exec=promisify(execFile);

test('capture descriptions say what the image shows in plain words',()=>{
 assert.equal(describeCapture({width:640,height:400,window:{app:'Alacritty',title:'nvim ~/notes.md'}}).alt_text,'Screenshot of the Alacritty window "nvim ~/notes.md", 640x400 pixels');
 assert.equal(describeCapture({width:640,height:400,window:{app:'Alacritty',title:'nvim'}}).heading,'Screenshot: nvim (Alacritty)');
 assert.equal(describeCapture({width:1920,height:1080,display:'DP-1'}).alt_text,'Screenshot of display DP-1, 1920x1080 pixels');
 assert.equal(describeCapture({width:200,height:100,region:[0,0,200,100]}).alt_text,'Screenshot of a 200x100 region of the desktop, 200x100 pixels');
 assert.equal(describeCapture({width:1280,height:800}).alt_text,'Screenshot of the desktop, 1280x800 pixels');
 const marked=describeCapture({width:800,height:600,source_id:'shot-1',markup:['box','arrow','box','text'],window:{app:'foot',title:'build log'}});
 assert.equal(marked.alt_text,'Marked-up copy of screenshot shot-1 with 2 boxes, 1 arrow and 1 text, 800x600 pixels');
 assert.equal(marked.heading,'Marked-up screenshot: build log');
 // Window titles are untrusted: control characters and newlines never reach Markdown structure.
 const hostile=describeCapture({width:10,height:10,window:{app:'x\n# injected',title:'a\u0007b\n---'}});
 assert.ok(!hostile.alt_text.includes('\n'));assert.ok(!hostile.heading.includes('\n'));
});

test('text recognition outcome is always stated, never an empty section',()=>{
 assert.equal(recognitionSection({status:'ready',text:'hello'}),'hello');
 assert.match(recognitionSection({status:'ready',text:''}),/No text was found/);
 assert.match(recognitionSection({status:'unavailable',text:''}),/Install tesseract/);
 assert.match(recognitionSection({status:'failed',text:''}),/failed/);
});

test('saved screenshot notes embed the image with alt text and machine-readable front matter',async t=>{
 const {command}=await import('../system.mjs');const im=await command('magick')||await command('convert');
 if(!im||!await command('git')) return t.skip('ImageMagick and git are required');
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-readable-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const brain=path.join(base,'Brain'),png=path.join(base,'in.png');await mkdir(brain);
 await exec(im,['-size','300x120','xc:white','-fill','black','-pointsize','36','-annotate','+10+70','HELLO','PNG24:'+png]);
 const script=`const {saveCapture}=await import(${JSON.stringify(new URL('../library.mjs',import.meta.url).href)});process.stdout.write(JSON.stringify(await saveCapture({file:${JSON.stringify(png)}},undefined,{window:{app:'foot',title:'demo'}})));`;
 const {stdout}=await exec(process.execPath,['--input-type=module','-e',script],{env:{...process.env,MYMAN_BRAIN_ROOT:brain,XDG_STATE_HOME:path.join(base,'state'),XDG_CONFIG_HOME:path.join(base,'config')}});
 const r=JSON.parse(stdout);
 assert.equal(r.alt_text,'Screenshot of the foot window "demo", 300x120 pixels');assert.equal(r.attachment.alt_text,r.alt_text);assert.equal(r.title,'Screenshot: demo (foot)');
 const md=await readFile(path.join(brain,r.brain_path),'utf8');
 assert.match(md,/^---\nid: [0-9a-f-]{36}\nkind: screenshot\n/);
 assert.match(md,/\nalt: "Screenshot of the foot window \\"demo\\", 300x120 pixels"\n/);
 assert.match(md,/\napp: "foot"\nwindow_title: "demo"\n/);
 assert.ok(md.includes(`](../assets/captures/${r.id.slice(5)}.png)`));
 assert.match(md,/\n## Text on screen\n\n\S/);
 const entry=JSON.parse(await readFile(path.join(brain,'catalog.json'),'utf8')).exports.at(-1);
 assert.equal(entry.alt_text,r.alt_text);assert.equal(entry.app,'foot');assert.equal(entry.text_found,r.text_found);
});
