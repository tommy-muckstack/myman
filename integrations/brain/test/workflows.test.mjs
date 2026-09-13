import test from 'node:test';
import assert from 'node:assert/strict';
import { catalog } from '../actions.mjs';
import { plan, run } from '../app-cli.mjs';
import { checkWorkflow } from '../workflows.mjs';

const live = () => ({ ...catalog, machine: {id:'selected-mac'}, app_version:'candidate', permissions:{enabled:true,library:true}, agent:{id:'worker',scopes:['library']} });
test('setup checks the actual Mac, identity and grants without invoking actions', async () => {
  const calls=[];
  const result=await checkWorkflow({machine:'selected-mac',transport:async message=>{calls.push(message);return {ok:true,result:live()};}});
  assert.equal(result.ok,true);assert.equal(result.host_attachment_delivery,'not_tested');assert.equal(result.host_dispatch,'not_tested');
  assert.deepEqual(calls,[{method:'actions'}]);
  for(const [name,edit] of [
    ['selected_mac',data=>data.machine.id='different'],
    ['named_agent',data=>delete data.agent],
    ['library_access',data=>data.permissions.library=false],
    ['brief_actions',data=>data.actions=data.actions.filter(a=>a.name!=='brief.review')],
  ]) {
    const data=live(); edit(data);
    const blocked=await checkWorkflow({machine:'selected-mac',transport:async()=>({ok:true,result:data})});
    assert.equal(blocked.ok,false);assert.equal(blocked.checks.find(c=>c.name===name).ok,false);
  }
});
test('offline catalog cannot pass the workflow check',async()=>{
  const result=await checkWorkflow({machine:'selected-mac',transport:async()=>{throw Object.assign(new Error('Offline'),{code:'APP_NOT_RUNNING'});}});
  assert.equal(result.ok,false);assert.equal(result.source,'bundled_cli');assert.equal(result.machine,null);
});
test('brief CLI preserves structured criteria, review evidence, and selected public media',async()=>{
  const created=await plan(['brief','create','--title','Bug','--outcome','Fix checkout','--recipe','bug-fix','--criteria','["Checkout works"]','--source-ids','["recording-source"]','--frame-times','[1,3]']);
  assert.equal(created.name,'brief.create');assert.deepEqual(created.args.criteria,['Checkout works']);assert.deepEqual(created.args.frame_times,[1,3]);
  const checks=[{criterion:0,passed:true,evidenceIDs:['shot-proof'],note:'Verified checkout'}];
  const reviewed=await plan(['brief','review','--id','brief','--expected-revision','3','--checks',JSON.stringify(checks)]);
  assert.deepEqual(reviewed.args.checks,checks);assert.equal(reviewed.args.expected_revision,3);
  const exported=await plan(['brief','export','--id','brief','--expected-revision','4','--public-title','Result','--public-summary','Public copy','--output-ids','["shot-proof"]','--confirm']);
  assert.equal(exported.args.confirm,true);assert.deepEqual(exported.args.output_ids,['shot-proof']);
  const result=await run(['workflow','check','--machine','selected-mac'],{request:async message=>{assert.equal(message.machine_id,'selected-mac');return {ok:true,result:live()};}});
  assert.equal(result.ok,true);
});
