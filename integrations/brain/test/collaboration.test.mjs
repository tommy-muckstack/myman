import test from 'node:test';
import assert from 'node:assert/strict';
import { plan, run } from '../app-cli.mjs';
import { catalog } from '../actions.mjs';

test('all collaboration actions have CLI routes and bounded catalog schemas', async () => {
  for (const name of ['machine.current','agent.whoami','agent.list','resource.version','bundle.create','bundle.list','bundle.read','bundle.update','bundle.delete','handoff.create','handoff.list','handoff.read','handoff.update','collaboration.events','lease.acquire','lease.release','session.transfer']) {
    const action = catalog.actions.find(x => x.name === name);
    assert.ok(action, name);
    assert.equal(action.inputSchema.additionalProperties, false);
    assert.equal((await plan(name.split('.'))).name, name);
  }
  const bundle = await plan(['bundle','create','--title','Demo','--item-ids','["shot-a"]','--members','["agent-b"]']);
  assert.deepEqual(bundle.args,{title:'Demo',item_ids:['shot-a'],members:['agent-b']});
  assert.equal((await plan(['bundle','update','--id','bundle','--expected-revision','2'])).args.expected_revision,2);
  assert.ok(catalog.actions.find(x=>x.name==='bundle.delete').destructive);
  assert.ok(!catalog.actions.some(x=>/agent\.(create|issue|grant|revoke)/.test(x.name)), 'Only humans provision credentials');
});

test('machine targeting reaches discovery, invocation and result polling', async () => {
  const calls=[];
  const transport = async payload => {
    calls.push(payload);
    if(payload.method==='actions')return {ok:true,result:catalog};
    return {ok:true,launch_id:'fixture',job:{id:payload.id,state:'succeeded',result:{id:'note-fixture'}}};
  };
  await run(['note','create','--body','Synthetic','--machine','fixture-mac'],{request:transport});
  assert.ok(calls.length >= 2);
  assert.ok(calls.every(x=>x.machine_id==='fixture-mac'));
  calls.length=0;
  await run(['jobs','--machine','fixture-mac'],{request:transport});
  assert.equal(calls[0].machine_id,'fixture-mac');
  await assert.rejects(run(['search','--machine','fixture-mac'],{request:transport}),/targets native app commands/);
});
