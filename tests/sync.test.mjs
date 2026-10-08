import test from 'node:test';
import assert from 'node:assert/strict';
import { loadCore } from './core-loader.mjs';
const { BookRecord, ReadingPosition, KoSyncSettings, KoSyncClient, ProgressCoordinator, decideSync, remoteToken,
  isCurrentSession, canAcknowledge, normalizeServer } = await loadCore();
const hash = '0123456789abcdef0123456789abcdef';
const pointer = '/body/DocFragment[2]/body/p/text().0';
function book() {
  const b = new BookRecord(); b.hash = hash; b.position.cfi = 'epubcfi(/6/4!/4/2:0)';
  b.position.xpointer = pointer; b.position.updatedAt = 20000; b.position.revision = 1; b.dirty = true; return b;
}
function config() { const c = new KoSyncSettings(); c.serverUrl = 'https://sync.example/base/'; c.username = 'reader'; c.userkey = 'hashed'; c.basicKey = 'basic'; return c; }
function transport(responses) {
  const requests = []; return { requests, async request(url, method, headers, body) {
    requests.push({ url, method, headers, body }); const r = responses.shift(); if (r instanceof Error) throw r;
    assert.ok(r, 'unexpected request'); return r;
  } };
}
const json = value => ({ status: 200, body: JSON.stringify(value) });

test('timestamps pick newer positions, with explicit missing/tie conflicts', () => {
  const b = book(); const r = { progress: '/body/DocFragment[3]/body/p', timestamp: 21 };
  assert.equal(decideSync(b, r), 'pull'); assert.equal(decideSync(b, { ...r, timestamp: 19 }), 'push');
  assert.equal(decideSync(b, { ...r, timestamp: 20 }), 'conflict'); assert.equal(decideSync(b, { progress: r.progress }), 'conflict');
  b.position.updatedAt = 0; assert.equal(decideSync(b, r), 'pull');
});
test('known server echoes do not supersede offline reading; missing records preserve dirty changes', () => {
  const b = book(), r = { progress: '/body/DocFragment[1]/body/p', timestamp: 30 };
  b.remoteToken = remoteToken(r); assert.equal(decideSync(b, r), 'push'); b.dirty = false;
  assert.equal(decideSync(b, r), 'none'); assert.equal(decideSync(b, null), 'none'); b.dirty = true;
  assert.equal(decideSync(b, null), 'push');
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
test('404 is missing; transport, auth, HTML, malformed and mismatched responses are errors', async () => {
  assert.equal(await new KoSyncClient(config(), transport([{ status: 404, body: '' }])).pull(hash), null);
  for (const response of [new Error('offline'), { status: 403, body: '{}' }, { status: 200, body: '<html>' }, json({}),
    json({ progress: pointer, document: 'wrong' }), json({ percentage: 2 }), json({ progress: pointer, timestamp: 'bad' })]) {
    await assert.rejects(new KoSyncClient(config(), transport([response])).pull(hash));
  }
});
function coordinator(provider, overrides = {}) {
  const result = { saved: [], status: [], conflicts: [], restores: [] };
  const hooks = { save: async b => result.saved.push(JSON.parse(JSON.stringify(b))), active: () => true,
    restore: async r => { result.restores.push(r); const p = new ReadingPosition(); p.cfi = 'epubcfi(/6/6!/4/2:0)'; p.xpointer = r.progress; return p; },
    status: s => result.status.push(s), conflict: r => result.conflicts.push(r), ...overrides };
  return { result, engine: new ProgressCoordinator(provider, hooks) };
}
test('newer remote is persisted with its timestamp; restoration is not a new local edit', async () => {
  const b = book(); const r = { progress: '/body/DocFragment[3]/body/p', timestamp: 30 };
  const { engine, result } = coordinator({ pull: async () => r, push: async () => assert.fail('must not push') });
  await engine.sync(b); assert.equal(b.position.updatedAt, 30000); assert.equal(b.dirty, false); assert.equal(result.saved.length, 1);
});
test('unresolvable remote and offline failures retain pending changes without any upload', async () => {
  const b = book(); let pushes = 0;
  const { engine } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[999]/body/p', timestamp: 30 }), push: async () => pushes++ },
    { restore: async () => { throw Error('UNRESOLVED_POSITION'); } });
  await assert.rejects(engine.sync(b)); assert.equal(b.dirty, true); assert.equal(pushes, 0);
});
test('an in-flight upload cannot acknowledge a newer reading change', async () => {
  const b = book(); let pulls = 0;
  const { engine } = coordinator({ pull: async () => ++pulls === 1 ? null : { progress: pointer, timestamp: 31 },
    push: async () => { b.position.revision++; b.position.xpointer = '/body/DocFragment[4]/body/p'; } });
  await engine.sync(b); assert.equal(b.dirty, true); assert.equal(b.position.revision, 2);
});
test('account/session cancellation stops responses from applying', async () => {
  const b = book(); let active = true;
  const { engine, result } = coordinator({ pull: async () => { active = false; return { progress: pointer, timestamp: 50 }; }, push: async () => assert.fail() }, { active: () => active });
  await engine.sync(b); assert.equal(result.saved.length, 0); assert.equal(b.dirty, true);
});
test('missing timestamp raises a choice rather than uploading', async () => {
  const b = book(); const { engine, result } = coordinator({ pull: async () => ({ progress: '/body/DocFragment[3]/body/p' }), push: async () => assert.fail() });
  await engine.sync(b); assert.equal(result.conflicts.length, 1); assert.equal(result.saved.length, 0);
});
test('a reading change during pull is compared before applying a remote position', async () => {
  const b = book(); let pulls = 0, pushes = 0;
  const { engine, result } = coordinator({
    pull: async () => {
      if (++pulls === 1) { b.position.updatedAt = 40000; b.position.revision++; return { progress: '/body/DocFragment[3]/body/p', timestamp: 30 }; }
      return { progress: pointer, timestamp: 41 };
    }, push: async () => { pushes++; }
  });
  await engine.sync(b); assert.equal(pushes, 1); assert.equal(result.restores.length, 0); assert.equal(b.dirty, false);
});
