import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, realpath, mkdir, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec=promisify(execFile);
const lib=new URL('../library.mjs',import.meta.url).href, items=new URL('../items.mjs',import.meta.url).href;

// Runs one library call in a fresh process against an isolated Brain, the
// same way the Linux worker does. Grants are enforced one layer up (service).
async function fixture(t){
 const {command}=await import('../system.mjs');
 if(!await command('git')||!(await command('magick')||await command('convert'))) return null;
 const base=await mkdtemp(path.join(await realpath(tmpdir()),'myman-library-'));t.after(()=>rm(base,{recursive:true,force:true}));
 const brain=path.join(base,'Brain');await mkdir(brain);
 const env={...process.env,MYMAN_BRAIN_ROOT:brain,XDG_STATE_HOME:path.join(base,'state'),XDG_CONFIG_HOME:path.join(base,'config')};
 const call=async(mod,fn,args)=>{
  const script=`const m=await import(${JSON.stringify(mod)});try{process.stdout.write(JSON.stringify({ok:true,...await m[${JSON.stringify(fn)}](${JSON.stringify(args)})}));}catch(e){process.stdout.write(JSON.stringify({ok:false,code:e.code,message:e.message}));}`;
  return JSON.parse((await exec(process.execPath,['--input-type=module','-e',script],{env})).stdout);
 };
 return {base,brain,call,im:await command('magick')||await command('convert')};
}

test('notes can be read, appended, replaced with a revision check, renamed and searched',async t=>{
 const f=await fixture(t);if(!f)return t.skip('git and ImageMagick are required');
 const note=await f.call(lib,'saveNote',{title:'Standup',body:'Ship the Linux library.'});
 let r=await f.call(items,'read',{id:note.id});
 assert.equal(r.body,'Ship the Linux library.');assert.equal(r.revision,1);assert.equal(r.kind,'note');
 const a=await f.call(items,'noteAppend',{id:note.id,body:'Then tasks.',expected_updated_at:r.updated_at});
 assert.equal(a.revision,2);
 r=await f.call(items,'read',{id:note.id});
 assert.equal(r.body,'Ship the Linux library.\n\nThen tasks.');
 // A stale timestamp must never overwrite a newer edit.
 const stale=await f.call(items,'noteUpdate',{id:note.id,body:'overwrite',expected_updated_at:note.updated_at});
 assert.equal(stale.ok,false);assert.equal(stale.code,'EDIT_CONFLICT');assert.match(stale.message,/library read/);
 const u=await f.call(items,'noteUpdate',{id:note.id,body:'Replaced body',expected_updated_at:r.updated_at});
 assert.equal(u.ok,true);
 const n=await f.call(items,'rename',{id:note.id,title:'Daily standup'});
 assert.equal(n.previous_title,'Standup');
 const md=await readFile(path.join(f.brain,note.brain_path),'utf8');
 assert.match(md,/\n# Daily standup\n\nReplaced body\n$/);
 const wrongRev=await f.call(items,'pin',{id:note.id,pinned:true,expected_revision:1});
 assert.equal(wrongRev.code,'EDIT_CONFLICT');
 assert.equal((await f.call(items,'pin',{id:note.id,pinned:true})).pinned,true);
 let s=await f.call(items,'search',{query:'replaced body'});
 assert.equal(s.results[0].id,note.id);assert.ok(s.results[0].reasons.includes('exact phrase'));
 s=await f.call(items,'search',{query:'replacd'});
 assert.equal(s.total,1);assert.match(s.results[0].reasons[0],/near spelling/);
 assert.equal((await f.call(items,'search',{query:'replacd',lexical_only:true})).total,0);
 assert.equal((await f.call(items,'search',{query:'body',pinned_only:true})).total,1);
 assert.equal((await f.call(items,'search',{query:'body',kind:'screenshot'})).total,0);
 const sem=await f.call(items,'search',{query:'x',semantic:true});
 assert.equal(sem.code,'unsupported_on_platform');
 const lease=await f.call(items,'noteAppend',{id:note.id,body:'x',lease_id:'L1'});
 assert.equal(lease.code,'unsupported_on_platform');
 const log=(await exec('git',['-C',f.brain,'log','--format=%s'])).stdout;
 assert.match(log,/update note/);assert.match(log,/append to note/);assert.match(log,/rename item/);
});

test('hidden items leave every reader and search, and come back intact',async t=>{
 const f=await fixture(t);if(!f)return t.skip('git and ImageMagick are required');
 const note=await f.call(lib,'saveNote',{title:'Secret plan',body:'zebra launch'});
 assert.equal((await f.call(items,'exclude',{id:note.id,excluded:true})).hidden,true);
 const s=await f.call(items,'search',{query:'zebra'});
 assert.equal(s.total,0);assert.equal(s.hidden_items_omitted,1);
 const r=await f.call(items,'read',{id:note.id});
 assert.equal(r.hidden,true);assert.equal(r.body,null);
 const edit=await f.call(items,'noteAppend',{id:note.id,body:'x'});
 assert.equal(edit.code,'UNKNOWN_ITEM');
 await f.call(items,'exclude',{id:note.id,excluded:false});
 assert.equal((await f.call(items,'search',{query:'zebra'})).total,1);
 // A later capture or note keeps hidden items hidden.
 await f.call(items,'exclude',{id:note.id,excluded:true});
 await f.call(lib,'saveNote',{body:'another'});
 assert.equal(JSON.parse(await readFile(path.join(f.brain,'catalog.json'),'utf8')).excluded.length,1);
});

test('attached images are owned copies with alt text, and delete needs --confirm',async t=>{
 const f=await fixture(t);if(!f)return t.skip('git and ImageMagick are required');
 const png=path.join(f.base,'in.png');await exec(f.im,['-size','120x60','xc:white','PNG24:'+png]);
 const shot=await f.call(lib,'saveCapture',{file:png});
 const note=await f.call(lib,'saveNote',{title:'Review',body:'See below.'});
 const a=await f.call(items,'noteAttach',{id:note.id,source_id:shot.id});
 assert.equal(a.attachment.alt_text,shot.alt_text);assert.equal(a.warnings,undefined);
 const b=await f.call(items,'noteAttach',{id:note.id,path:png});
 assert.equal(b.warnings[0].code,'ALT_TEXT_MISSING');assert.match(b.attachment.alt_text,/in\.png, 120x60 pixels/);
 const c=await f.call(items,'noteAttach',{id:note.id,path:png,alt:'Blank white test card'});
 const md=await readFile(path.join(f.brain,note.brain_path),'utf8');
 assert.ok(md.includes('![Blank white test card](../assets/note-images/'));
 // Deleting the source screenshot never breaks the note's copy.
 assert.equal((await f.call(items,'remove',{id:shot.id})).code,'CONFIRMATION_REQUIRED');
 const d=await f.call(items,'remove',{id:shot.id,confirm:true});
 assert.equal(d.deleted,true);
 await assert.rejects(access(shot.image_path));await access(a.attachment.path);
 assert.equal((await f.call(items,'read',{id:shot.id})).code,'UNKNOWN_ITEM');
 await f.call(items,'remove',{id:note.id,confirm:true});
 await assert.rejects(access(c.attachment.path));
 const status=(await exec('git',['-C',f.brain,'status','--porcelain'])).stdout;
 assert.equal(status.trim(),'');
});

test('tasks round-trip through the Mac export format with version checks',async t=>{
 const f=await fixture(t);if(!f)return t.skip('git and ImageMagick are required');
 const task=await f.call(items,'taskCreate',{title:'Book oil change',notes:'Odyssey',due:'2026-10-01'});
 assert.match(task.id,/^task-/);assert.equal(task.version,'1');assert.equal(task.done,false);assert.match(task.brain_path,/^task-items\//);
 const bad=await f.call(items,'taskCreate',{title:'x',due:'next tuesday'});assert.equal(bad.code,'INVALID_ARGUMENTS');
 const stale=await f.call(items,'taskUpdate',{id:task.id,done:true,expected_version:'9'});assert.equal(stale.code,'EDIT_CONFLICT');
 const done=await f.call(items,'taskUpdate',{id:task.id,done:true,expected_version:'1'});
 assert.equal(done.done,true);assert.ok(done.completed_at);assert.deepEqual(done.changed,['done']);assert.equal(done.notes,'Odyssey');
 const cleared=await f.call(items,'taskUpdate',{id:task.id,clear_due:true});assert.equal(cleared.due,null);
 const r=await f.call(items,'read',{id:task.id});assert.equal(r.body,'Odyssey');assert.equal(r.version,'3');assert.equal(r.done,true);
 // The unchanged Brain reader sees the task and its state.
 const script=`const {Brain}=await import(${JSON.stringify(new URL('../../brain/brain.mjs',import.meta.url).href)});process.stdout.write(JSON.stringify(await new Brain(${JSON.stringify(f.brain)}).tasks({state:'done'})));`;
 const list=JSON.parse((await exec(process.execPath,['--input-type=module','-e',script])).stdout);
 assert.equal(list.results.length,1);assert.equal(list.results[0].title,'Book oil change');
 assert.equal((await f.call(items,'taskDelete',{id:task.id})).code,'CONFIRMATION_REQUIRED');
 assert.equal((await f.call(items,'taskDelete',{id:task.id,confirm:true})).deleted,true);
});

test('related items explain every match',async t=>{
 const f=await fixture(t);if(!f)return t.skip('git and ImageMagick are required');
 const png=path.join(f.base,'in.png');await exec(f.im,['-size','80x40','xc:white','PNG24:'+png]);
 const shot=await f.call(lib,'saveCapture',{file:png},);
 const note=await f.call(lib,'saveNote',{title:'Pricing review',body:'Notes'});
 await f.call(items,'noteAttach',{id:note.id,source_id:shot.id,alt:'Pricing table'});
 const rel=await f.call(items,'related',{id:shot.id});
 const hit=rel.results.find(r=>r.id===note.id);
 assert.ok(hit);assert.ok(hit.reasons.includes('note that embeds this item'));assert.ok(hit.reasons.some(r=>/captured/.test(r)));
 const back=await f.call(items,'related',{id:note.id});assert.ok(back.results.find(r=>r.id===shot.id).reasons.includes('embedded in this note'));
});
