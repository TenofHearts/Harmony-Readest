import test from 'node:test';
import assert from 'node:assert/strict';
import { loadCore } from './core-loader.mjs';
const { BookRecord, ReadingPosition, KoSyncSettings, KoSyncClient, ProgressCoordinator, decideSync, remoteToken,
  isCurrentSession, canAcknowledge, normalizeServer, errorMessage } = await loadCore();
const hash = '0123456789abcdef0123456789abcdef';
const pointer = '/body/DocFragment[2]/body/p/text().0';
function book() {
  const b = new BookRecord(); b.hash = hash; b.position.cfi = 'epubcfi(/6/4!/4/2:0)';
  b.position.xpointer = pointer; b.position.percentage = .4; b.position.updatedAt = 20000; b.position.revision = 1; b.dirty = true; return b;
}
function config() { const c = new KoSyncSettings(); c.serverUrl = 'https://sync.example/base/'; c.username = 'reader'; c.userkey = 'hashed'; c.basicKey = 'basic'; return c; }
function transport(responses) {
  const requests = []; return { requests, async request(url, method, headers, body) {
    requests.push({ url, method, headers, body }); const r = responses.shift(); if (r instanceof Error) throw r;
    assert.ok(r, 'unexpected request'); return r;
  } };
}
const json = value => ({ status: 200, body: JSON.stringify(value) });

test('native numeric error messages cannot enter the UI string state', () => {
  for (const value of [{ code: 12000011, message: -13 }, {}, null]) assert.equal(errorMessage(value), 'OPERATION_FAILED');
  assert.equal(errorMessage(new Error('NETWORK_TIMEOUT')), 'NETWORK_TIMEOUT');
});

test('different positions require a choice regardless of timestamps or percentages', () => {
  const b = book(); const r = { progress: '/body/DocFragment[3]/body/p', percentage: .6, timestamp: 19 };
  for (const timestamp of [undefined, 19, 20, 30]) {
    assert.equal(decideSync(b, { ...r, timestamp }), 'conflict');
    assert.equal(decideSync(b, { ...r, percentage: .2, timestamp }), 'conflict');
  }
  b.remoteToken = remoteToken(r); assert.equal(decideSync(b, r), 'push');
  b.dirty = false; assert.equal(decideSync(b, { ...r, percentage: .2 }), 'conflict');
  b.position.updatedAt = 0; assert.equal(decideSync(b, r), 'none');
  b.position.cfi = ''; assert.equal(decideSync(b, r), 'pull');
});
test('acknowledged echoes preserve backwards edits; new accounts upload saved local progress', () => {
  const b = book(), r = { progress: '/body/DocFragment[3]/body/p', percentage: .6, timestamp: 10 };
  b.remoteToken = remoteToken(r); assert.equal(decideSync(b, r), 'push');
  b.dirty = false; assert.equal(decideSync(b, null), 'push'); b.dirty = true;
  assert.equal(decideSync(b, null), 'push');
  b.position.cfi = ''; b.position.xpointer = ''; assert.equal(decideSync(b, null), 'none');
});
test('same locators converge; equal percentages alone cannot establish an exact match', () => {
  const b = book(); const r = { progress: '/body/DocFragment[3]/body/p', percentage: .4 };
  assert.equal(decideSync(b, r), 'conflict');
  assert.equal(decideSync(b, { ...r, percentage: undefined }), 'conflict');
  assert.equal(decideSync(b, { progress: pointer, percentage: .4 }), 'push');
  b.dirty = false; assert.equal(decideSync(b, { progress: pointer, percentage: .4 }), 'none');
  assert.equal(decideSync(b, { progress: pointer, percentage: .6 }), 'none');
  assert.equal(decideSync(b, { ...r, percentage: 0 }), 'conflict');
  b.position.percentage = 0; assert.equal(decideSync(b, { ...r, percentage: 0 }), 'conflict');
  assert.equal(decideSync(b, { ...r, percentage: 1 }), 'conflict');
});
test('session isolation and revision acknowledgment', () => {
  assert.equal(isCurrentSession('new', 'old'), false); assert.equal(isCurrentSession('', ''), false);
  assert.equal(isCurrentSession('new', 'new'), true); assert.equal(canAcknowledge(1, 2), false);
});
test('HTTPS endpoints preserve custom base paths and reject credentials/query URLs', () => {
  assert.equal(normalizeServer(' https://example.org/kosync/ '), 'https://example.org/kosync');
  for (const value of ['http://example.org', 'https://user:pass@example.org', 'https://example.org?x=1', 'garbage']) assert.throws(() => normalizeServer(value));
});
test('wire authentication, pull without document, PUT payload, Basic fallback', async () => {
  const t = transport([{ status: 401, body: '{}' }, json({ authorized: 'OK' }), json({ progress: pointer, percentage: .2, timestamp: 42 }), json({ updated: 'OK' })]);
  const c = new KoSyncClient(config(), t); await c.authenticate();
  const remote = await c.pull(hash); assert.equal(remote.progress, pointer);
  const p = new ReadingPosition(); p.xpointer = pointer; p.percentage = .2; await c.push(hash, p);
  assert.equal(t.requests[0].headers['X-Auth-User'], 'reader'); assert.equal(t.requests[1].headers.Authorization, 'Basic basic');
  assert.equal(t.requests[2].url, `https://sync.example/base/syncs/progress/${hash}`);
  assert.equal(t.requests[3].method, 'PUT'); assert.equal(JSON.parse(t.requests[3].body).document, hash);
});
test('404 and empty JSON are missing; transport, auth, HTML, malformed and mismatched responses are errors', async () => {
  assert.equal(await new KoSyncClient(config(), transport([{ status: 404, body: '' }])).pull(hash), null);
  assert.equal(await new KoSyncClient(config(), transport([json({})])).pull(hash), null);
  for (const response of [new Error('offline'), { status: 403, body: '{}' }, { status: 200, body: '<html>' }, json({ unexpected: true }), json([]),
    json({ progress: pointer, document: 'wrong' }), json({ percentage: 2 }), json({ progress: pointer, percentage: 2 }),
    json({ progress: pointer, percentage: '.2' }), json({ progress: pointer, timestamp: 'bad' })]) {
    await assert.rejects(new KoSyncClient(config(), transport([response])).pull(hash));
  }
});
test('authentication must return the KoSync authorization marker', async () => {
  for (const value of [{}, [], { authorized: 'NO' }, { code: 2001 }]) {
    await assert.rejects(new KoSyncClient(config(), transport([json(value)])).authenticate(), /NOT_KOSYNC/);
  }
});
function coordinator(provider, overrides = {}) {
  const result = { saved: [], status: [], conflicts: [], restores: [] };
  const hooks = { save: async b => result.saved.push(JSON.parse(JSON.stringify(b))), active: () => true, deviceId: 'this-device',
    inspect: async r => { const p = new ReadingPosition(); p.cfi = 'epubcfi(/6/6!/4/2:0)'; p.percentage = r.percentage ?? .6; return p; },
    restore: async r => { result.restores.push(r); const p = new ReadingPosition(); p.cfi = 'epubcfi(/6/6!/4/2:0)'; p.xpointer = r.progress; return p; },
    status: s => result.status.push(s), conflict: r => result.conflicts.push(r), ...overrides };
  return { result, engine: new ProgressCoordinator(provider, hooks) };
}
test('a remote position moves the reader only after the user selects the displayed report', async () => {
  const b = book(); const r = { progress: '/body/DocFragment[3]/body/p', percentage: .6, timestamp: 10 };
  const { engine, result } = coordinator({ pull: async () => r, push: async () => assert.fail('must not push') });
  await engine.sync(b, 'reconcile'); assert.equal(result.conflicts.length, 1); assert.equal(result.restores.length, 0);
  await engine.sync(b, 'use-remote'); assert.equal(b.position.updatedAt, 10000);
  assert.equal(b.dirty, false); assert.equal(result.saved.length, 1);
  await engine.sync(b, 'reconcile'); assert.equal(result.restores.length, 1); assert.equal(result.conflicts.length, 1);
});
test('unresolvable remote and offline failures retain pending changes without any upload', async () => {
  const b = book(); let pushes = 0;
  const { engine } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[999]/body/p', percentage: .6, timestamp: 30 }), push: async () => pushes++ },
    { restore: async () => { throw Error('UNRESOLVED_POSITION'); } });
  await engine.sync(b, 'reconcile'); await assert.rejects(engine.sync(b, 'use-remote'));
  assert.equal(b.dirty, true); assert.equal(pushes, 0);
});
test('an in-flight upload cannot acknowledge a newer reading change', async () => {
  const b = book(); let pulls = 0;
  const { engine } = coordinator({ pull: async () => ++pulls === 1 ? null : { progress: pointer, timestamp: 31 },
    push: async () => { b.position.revision++; b.position.xpointer = '/body/DocFragment[4]/body/p'; } });
  await engine.sync(b, 'manual-upload'); assert.equal(b.dirty, true); assert.equal(b.position.revision, 2);
});
test('account/session cancellation stops responses from applying', async () => {
  const b = book(); let active = true;
  const { engine, result } = coordinator({ pull: async () => { active = false; return { progress: pointer, timestamp: 50 }; }, push: async () => assert.fail() }, { active: () => active });
  await engine.sync(b, 'reconcile'); assert.equal(result.saved.length, 0); assert.equal(b.dirty, true);
});
test('missing timestamps and percentages still allow a user choice', async () => {
  const b = book(); const { engine, result } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[3]/body/p' }), push: async () => assert.fail() });
  await engine.sync(b, 'reconcile'); assert.equal(result.conflicts.length, 1); assert.equal(result.saved.length, 0);
});
test('a reading change during pull requires a choice and cannot upload over a differing remote', async () => {
  const b = book(); let pulls = 0, pushes = 0;
  const { engine, result } = coordinator({
    pull: async () => {
      if (++pulls === 1) { b.position.percentage = .8; b.position.updatedAt = 40000; b.position.revision++; return { progress: '/body/DocFragment[3]/body/p', percentage: .6, timestamp: 50 }; }
      return { progress: pointer, percentage: .8, timestamp: 41 };
    }, push: async () => { pushes++; }
  });
  await engine.sync(b, 'reconcile'); assert.equal(pushes, 0); assert.equal(result.restores.length, 0); assert.equal(b.dirty, true);
  assert.equal(result.conflicts.length, 1);
});
test('pending choices block queued automatic uploads; choosing local resumes uploads without pulling again', async () => {
  const b = book(); let pulls = 0, pushes = 0;
  const { engine, result } = coordinator({
    pull: async () => { pulls++; return { progress: '/body/DocFragment[3]/body/p', percentage: .6 }; },
    push: async () => { pushes++; }
  });
  const checking = engine.sync(b, 'reconcile'), uploading = engine.sync(b);
  await Promise.all([checking, uploading]); assert.equal(pushes, 0); assert.equal(result.restores.length, 0);
  await engine.sync(b, 'keep-local'); assert.equal(pushes, 1); assert.equal(pulls, 1); assert.equal(b.dirty, false);
  await engine.sync(b); assert.equal(pushes, 2); assert.equal(pulls, 1);
});
test('explicit Send progress uploads the current position without any remote GET', async () => {
  const b = book(); b.dirty = false; let pulls = 0, pushes = 0;
  const { engine, result } = coordinator({
    pull: async () => { pulls++; assert.fail('manual send must not pull'); },
    push: async () => { pushes++; }
  });
  await engine.sync(b, 'manual-upload'); assert.equal(pushes, 1); assert.equal(pulls, 0); assert.equal(result.restores.length, 0); assert.equal(b.dirty, false);
});
test('a reading change during restoration cannot be acknowledged or overwritten', async () => {
  const b = book(); const { engine, result } = coordinator({
    pull: async () => ({ progress: '/body/DocFragment[3]/body/p', percentage: .6 }), push: async () => assert.fail()
  }, { restore: async () => { b.position.percentage = .8; b.position.revision++; return new ReadingPosition(); } });
  await engine.sync(b, 'reconcile'); await engine.sync(b, 'use-remote');
  assert.equal(b.position.percentage, .8); assert.equal(b.dirty, true); assert.equal(result.saved.length, 0);
});

test('a resolved equivalent passage suppresses a prompt even when server percentages disagree', async () => {
  const b = book(); b.dirty = false;
  const { engine, result } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[3]/body/p', percentage: .9 }), push: async () => assert.fail() },
    { inspect: async () => ({ cfi: b.position.cfi, percentage: b.position.percentage }) });
  await engine.sync(b, 'reconcile'); assert.equal(result.conflicts.length, 0); assert.equal(result.restores.length, 0);
});
test('unresolvable remote previews always prompt even when percentages match', async () => {
  const b = book(); const { engine, result } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[999]/body/p', percentage: .4 }), push: async () => assert.fail() },
    { inspect: async () => { throw Error('UNRESOLVED_POSITION'); } });
  await engine.sync(b, 'reconcile'); await engine.sync(b); assert.equal(result.conflicts.length, 1); assert.equal(result.restores.length, 0);
});
test('an unchanged explicitly resolved report cannot prompt again after an offline backwards edit', async () => {
  const b = book(); const r = { progress: '/body/DocFragment[3]/body/p', percentage: .6, timestamp: 50, device_id: 'other-device' };
  let pushes = 0; const { engine, result } = coordinator({ pull: async () => r, push: async () => { pushes++; throw Error('offline'); } });
  await engine.sync(b, 'reconcile'); await engine.sync(b, 'use-remote');
  b.position = { ...b.position, cfi: 'epubcfi(/6/2!/4/2:0)', xpointer: pointer, percentage: .1, revision: 3 }; b.dirty = true;
  await assert.rejects(engine.sync(b, 'reconcile'));
  assert.equal(result.conflicts.length, 1); assert.equal(pushes, 1); assert.equal(b.position.percentage, .1);
});

test('same-device sub-page drift is ignored, but a significant difference prompts', async () => {
  const b = book(); b.dirty = false; let percentage = .405;
  const { engine, result } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[3]/body/p', percentage, device_id: 'this-device' }), push: async () => assert.fail() },
    { inspect: async () => assert.fail('own-device reports use comparable percentages') });
  await engine.sync(b, 'reconcile'); assert.equal(result.conflicts.length, 0);
  percentage = .6; await engine.sync(b, 'reconcile'); assert.equal(result.conflicts.length, 1); assert.equal(result.restores.length, 0);
});
test('a failed foreground check cannot release queued automatic uploads', async () => {
  const b = book(); let failing = false, pushes = 0;
  const { engine } = coordinator({ pull: async () => { if (failing) throw Error('offline'); return null; }, push: async () => { pushes++; } });
  await engine.sync(b, 'reconcile'); assert.equal(pushes, 1);
  failing = true; await assert.rejects(engine.sync(b, 'reconcile')); b.dirty = true;
  await engine.sync(b); assert.equal(pushes, 1); assert.equal(b.dirty, true);
});
