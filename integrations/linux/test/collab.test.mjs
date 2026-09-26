import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

test('credentials narrow access and coordinate bundles, handoffs and leases', async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'myman-collab-'));
  process.env.XDG_CONFIG_HOME = path.join(home, 'config'); process.env.XDG_STATE_HOME = path.join(home, 'state');
  delete process.env.MYMAN_AGENT_TOKEN;
  const identity = await import('../identity.mjs');
  const collab = await import('../collab.mjs');
  // Before any credential exists, local use is allowed but collaboration is not.
  assert.equal((await identity.authenticate()).id, 'local');
  await assert.rejects(collab.execute('agent.whoami', {}), { code: 'IDENTITY_REQUIRED' });
  const a = await identity.issue('Writer', ['capture', 'library']), b = await identity.issue('Reviewer', ['library']);
  assert.equal(a.agent.digest, undefined);
  await assert.rejects(identity.authenticate(''), { code: 'IDENTITY_REQUIRED' });
  await assert.rejects(identity.authenticate('nope'), { code: 'INVALID_CREDENTIAL' });
  const who = await identity.authenticate(b.token);
  assert.throws(() => identity.validate(who, ['capture']), { code: 'AGENT_SCOPE_DENIED' });
  identity.validate(who, ['library']);
  assert.equal((await collab.execute('agent.whoami', {})).name, 'Reviewer');
  assert.equal((await collab.execute('agent.list', {})).length, 2);
  // Leases: the clipboard belongs to its holder until expiry.
  await identity.authenticate(a.token);
  const lease = await collab.execute('lease.acquire', { resource: 'clipboard', seconds: 30 });
  await collab.begin(['clipboard'], lease.id);
  await identity.authenticate(b.token);
  await assert.rejects(collab.begin(['clipboard']), { code: 'RESOURCE_OWNED' });
  await assert.rejects(collab.execute('lease.acquire', { resource: 'clipboard' }), { code: 'RESOURCE_OWNED' });
  await assert.rejects(collab.execute('lease.release', { resource: 'clipboard', lease_id: lease.id }), { code: 'RESOURCE_OWNED' });
  await identity.authenticate(a.token);
  assert.deepEqual(await collab.execute('lease.release', { resource: 'clipboard', lease_id: lease.id }), { released: 'clipboard' });
  await assert.rejects(collab.execute('lease.acquire', { resource: 'window:1' }), { code: 'INVALID_ARGUMENTS' });
  // Sessions: only the owner may control or transfer a recording.
  await collab.ownSession('S1');
  await identity.authenticate(b.token);
  await assert.rejects(collab.checkSession('S1'), { code: 'NOT_OWNER' });
  await identity.authenticate(a.token);
  await assert.rejects(collab.execute('session.transfer', { session_id: 'S1', recipient: b.agent.id }), { code: 'NOT_OWNER' }); // no recording scope
  // Revoked credentials stop working.
  await identity.revoke(b.agent.id);
  await assert.rejects(identity.authenticate(b.token), { code: 'INVALID_CREDENTIAL' });
  await identity.setRequired(false);
  assert.equal((await identity.authenticate('')).id, 'local');
});
