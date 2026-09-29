import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolvePeople} from '../people.mjs';
import {plan} from '../app-cli.mjs';
import {describe} from '../actions.mjs';

const fixtures=JSON.parse(await readFile(new URL('../../../Tests/Fixtures/people-resolution.json',import.meta.url),'utf8'));
for(const fixture of fixtures)test(`people shared fixture: ${fixture.name}`,()=>{
  assert.deepEqual(resolvePeople(fixture.names,fixture.records,fixture.limit),fixture.expected);
  assert.deepEqual(resolvePeople(fixture.names,[...fixture.records].reverse(),fixture.limit),fixture.expected);
});
test('people resolver validates bounded inputs and never returns partial source results',()=>{
 for(const names of [[],[' '],['???'],['Sam\nInvite'],['a'.repeat(201)],Array(21).fill('Sam')])assert.throws(()=>resolvePeople(names,[]),{code:'INVALID_ARGUMENTS'});
 for(const limit of [0,11,1.5])assert.throws(()=>resolvePeople(['Sam'],[],limit),{code:'INVALID_ARGUMENTS'});
 assert.throws(()=>resolvePeople(['Sam'],Array(10001).fill({name:'Sam',source:'people'})),{code:'PEOPLE_LIMIT_EXCEEDED'});
});
test('people resolve CLI shares its strict read-only schema and independent grant',async()=>{
 const value=await plan(['people','resolve','--names','["Jilles","Harshil"]','--limit','2','--json']);
 assert.equal(value.name,'people.resolve');assert.deepEqual(value.args,{names:['Jilles','Harshil'],limit:2});
 const action=describe(value.name);assert.equal(action.readOnly,true);assert.equal(action.destructive,false);assert.deepEqual(action.permissions,['people_read']);
 await assert.rejects(plan(['people','resolve','--names','["Sam"]','--contacts','on']));
 await assert.rejects(plan(['people','resolve','--names','["Sam"]','--path','/tmp/people.md']));
});
