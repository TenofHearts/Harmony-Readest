import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { loadCore } from './core-loader.mjs';

const core = await loadCore();
const bundled = await build({ stdin: { contents: `export { FontLibrary } from './entry/src/main/ets/services/FontLibrary.ets';
  export { ReplicaService } from './entry/src/main/ets/services/ReplicaService.ets';`, resolveDir: process.cwd() },
  bundle: true, write: false, format: 'esm', platform: 'node', resolveExtensions: ['.ets', '.ts', '.js'],
  plugins: [{ name: 'font-platform-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'kit' }));
    b.onLoad({ filter: /.*/, namespace: 'kit' }, () => ({ contents: `
      import { createHash, randomUUID } from 'node:crypto';
      const f = () => globalThis.fontFixture;
      export const util = { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } }, generateRandomUUID: randomUUID };
      export const font = { getSystemFontList() { return ['Fixture Sans']; }, registerFont(value) { f().registered.push(value); } };
      export const cryptoFramework = { createMd() { const hash = createHash('md5'); return {
        async update(value) { hash.update(value.data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; }
      }; } };
      export const preferences = { async getPreferences(context, { name }) {
        const key = context.filesDir + '/' + name;
        if (!f().prefs.has(key)) f().prefs.set(key, new Map()); const data = f().prefs.get(key);
        return { async get(key, fallback) { return data.get(key) ?? fallback; }, async put(key, value) { data.set(key, value); }, async flush() {} };
      } };
      export const picker = { DocumentViewPicker: class { async select() { return f().selected; } } };
      export const fileIo = {
        OpenMode: { READ_ONLY: 0, CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
        accessSync(path) { if (!f().files.has(path) && !f().folders.has(path)) throw Error('ENOENT'); return true; },
        mkdirSync(path) { f().folders.add(path); },
        openSync(path, mode) { if (mode) f().files.set(path, Buffer.alloc(0)); if (!f().files.has(path)) throw Error('ENOENT');
          const fd = ++f().nextFd; f().handles.set(fd, { path, offset: 0 }); return { fd }; },
        statSync(fd) { return { size: f().files.get(f().handles.get(fd).path).length }; },
        async read(fd, buffer) { const h = f().handles.get(fd), bytes = f().files.get(h.path);
          const count = Math.min(buffer.byteLength, bytes.length - h.offset, 37); new Uint8Array(buffer).set(bytes.subarray(h.offset, h.offset + count)); h.offset += count; return count; },
        async write(fd, buffer) { const h = f().handles.get(fd), chunk = Buffer.from(buffer).subarray(0, 31);
          f().files.set(h.path, Buffer.concat([f().files.get(h.path), chunk])); return chunk.length; },
        closeSync(fd) { if (typeof fd === 'object') fd = fd.fd; if (!f().handles.delete(fd)) throw Error('DOUBLE_CLOSE'); }, unlinkSync(path) { f().files.delete(path); }
      };
      export const http = { RequestMethod: { GET: 'GET', PUT: 'PUT' }, HttpDataType: { ARRAY_BUFFER: 1 }, createHttp() {
        return { async request(url, options) { f().binaryCalls.push({ url, options });
          if (f().failBinary) throw Error('OFFLINE');
          if (options.method === 'PUT') { f().cloudFiles.set(url, Buffer.from(options.extraData)); return { responseCode: 200, result: new ArrayBuffer(0) }; }
          const bytes = f().cloudFiles.get(url); if (!bytes) return { responseCode: 404, result: new ArrayBuffer(0) };
          return { responseCode: 200, result: Uint8Array.from(bytes).buffer };
        }, destroy() {} };
      } };
    ` }));
    b.onResolve({ filter: /\/(CredentialVault|NativeTransport)$/ }, args => ({ path: args.path.split('/').pop(), namespace: 'service' }));
    b.onLoad({ filter: /.*/, namespace: 'service' }, args => ({ contents: args.path === 'CredentialVault' ?
      `export class CredentialVault { text = ''; async init() {} async loadText() { return this.text; }
        async saveText(value) { this.text = value; } async clear() { this.text = ''; } }` :
      `export class NativeTransport { async request(...args) { return globalThis.fontFixture.request(...args); } }` }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}] });
await mkdir('output/tests', { recursive: true }); await writeFile('output/tests/fonts-replica-fixture.mjs', bundled.outputFiles[0].text);
const { FontLibrary, ReplicaService } = await import(pathToFileURL(resolve('output/tests/fonts-replica-fixture.mjs')));

function fontBytes(family = 'Fixture Serif') {
  const name = Buffer.from(family, 'utf16le'); for (let i = 0; i < name.length; i += 2) [name[i], name[i + 1]] = [name[i + 1], name[i]];
  const bytes = Buffer.alloc(28 + 18 + name.length); bytes.writeUInt32BE(0x10000, 0); bytes.writeUInt16BE(1, 4);
  bytes.write('name', 12); bytes.writeUInt32BE(28, 20); bytes.writeUInt32BE(18 + name.length, 24);
  bytes.writeUInt16BE(1, 30); bytes.writeUInt16BE(18, 32); bytes.writeUInt16BE(3, 34); bytes.writeUInt16BE(1, 36);
  bytes.writeUInt16BE(0x409, 38); bytes.writeUInt16BE(1, 40); bytes.writeUInt16BE(name.length, 42); name.copy(bytes, 46);
  return Uint8Array.from(bytes).buffer;
}

function fixture() {
  const f = globalThis.fontFixture = { files: new Map(), folders: new Set(), handles: new Map(), nextFd: 0,
    prefs: new Map(), registered: [], selected: [], cloudFiles: new Map(), rows: new Map(), calls: [], binaryCalls: [], failBinary: false };
  f.request = async (url, method, headers, body) => {
    f.calls.push({ url, method, headers, body }); const parsed = body ? JSON.parse(body) : null;
    if (url.includes('/auth/v1/token')) return { status: 200, body: JSON.stringify({ access_token: 'fixture-token', refresh_token: 'fixture-refresh', expires_in: 3600, user: { id: 'fixture-user', email: 'reader@example.test' } }) };
    if (url.includes('/sync/replicas')) {
      if (method === 'POST') {
        const incoming = parsed.rows[0], existing = f.rows.get(incoming.replica_id);
        const merged = { ...incoming, fields_jsonb: { ...existing?.fields_jsonb, ...incoming.fields_jsonb },
          manifest_jsonb: incoming.manifest_jsonb || existing?.manifest_jsonb || null };
        f.rows.set(incoming.replica_id, merged); return { status: 200, body: JSON.stringify({ rows: [merged] }) };
      }
      const since = new URL(url).searchParams.get('since') || '';
      return { status: 200, body: JSON.stringify({ rows: [...f.rows.values()].filter(r => r.updated_at_ts > since).sort((a,b) => a.updated_at_ts.localeCompare(b.updated_at_ts)) }) };
    }
    if (url.includes('/storage/upload')) return { status: 200, body: JSON.stringify({ uploadUrl: 'https://objects.example.test/' + parsed.fileName }) };
    if (url.includes('/storage/download')) {
      const key = new URL(url).searchParams.get('fileKey').replace('fixture-user/', '');
      return { status: 200, body: JSON.stringify({ downloadUrl: 'https://objects.example.test/' + key }) };
    }
    throw Error('UNEXPECTED_ENDPOINT');
  };
  return f;
}

async function client(directory) {
  const library = new FontLibrary(); await library.init({ filesDir: directory });
  const service = new ReplicaService(library); service.deviceId = directory.slice(1);
  Object.assign(service.config, { userId: 'fixture-user', email: 'reader@example.test', accessToken: 'fixture-token', refreshToken: 'fixture-refresh', expiresAt: Date.now() + 3600000 });
  return { library, service };
}

test('font parsing rejects malformed fonts and extracts real SFNT family names without trusting filenames', () => {
  const font = core.parseFont(fontBytes('阅读测试'), 'renamed.ttf'); assert.equal(font.family, '阅读测试');
  for (const [bytes, name] of [[new ArrayBuffer(1), 'bad.ttf'], [fontBytes(), '../escape.ttf'], [fontBytes(), 'font.woff'], [new ArrayBuffer(32 * 1024 * 1024 + 1), 'large.ttf']]) assert.throws(() => core.parseFont(bytes, name));
  const malformed = fontBytes(); new DataView(malformed).setUint32(20, 0xffffffff); assert.throws(() => core.parseFont(malformed, 'bad.ttf'));
});

test('native font import matches Readest content identity, persists across restart, and closes short-read/write descriptors', async () => {
  const f = fixture(), { library } = await client('/first'); const bytes = fontBytes();
  const installed = await library.install(bytes, 'reading.ttf');
  // This small fixture contributes only Readest's initial 1024-byte sample.
  const partial = createHash('md5').update(Buffer.from(bytes)).digest('hex');
  assert.equal(installed.partialMd5, partial);
  assert.equal(installed.id, createHash('md5').update(`${partial}|${bytes.byteLength}|reading.ttf`).digest('hex'));
  assert.deepEqual(Buffer.from(await library.bytes(installed.path)), Buffer.from(bytes)); assert.equal(f.handles.size, 0);
  assert.equal((await library.install(bytes, 'reading.ttf')).id, installed.id); assert.equal(library.fonts.length, 1);
  const reopened = new FontLibrary(); await reopened.init({ filesDir: '/first' }); assert.equal(reopened.fonts[0].family, 'Fixture Serif');
  await assert.rejects(library.install(bytes, 'tampered.ttf', installed.id), /INVALID_FONT/); assert.equal(reopened.fonts.length, 1);
});

test('two clients exchange font replicas and binaries, publishing manifests last and persisting cursors', async () => {
  const f = fixture(), a = await client('/first'), b = await client('/second');
  const font = await a.library.install(fontBytes(), 'reading.ttf'); await a.service.sync();
  const pushes = f.calls.filter(c => c.method === 'POST' && c.url.includes('/sync/replicas')).map(c => JSON.parse(c.body).rows[0]);
  assert.equal(pushes.length, 2); assert.equal(pushes[0].manifest_jsonb, null); assert.equal(pushes[1].fields_jsonb && Object.keys(pushes[1].fields_jsonb).length, 0);
  assert.equal(pushes[1].manifest_jsonb.files[0].partialMd5, font.partialMd5);
  assert.ok(f.binaryCalls.every(c => !c.options.header));
  await b.service.sync(); assert.equal(b.library.fonts[0].id, font.id);
  assert.deepEqual(Buffer.from(await b.library.bytes(b.library.fonts[0].path)), Buffer.from(fontBytes()));
  assert.ok(b.service.config.cursor); assert.equal(JSON.parse(b.service.vault.text).cursor, b.service.config.cursor);
  const calls = f.calls.length; await b.service.sync(); assert.equal(f.calls.slice(calls).filter(c => c.method === 'POST').length, 0);
});

test('failed transfers retain unpublished files and retry without committing a manifest or skipping a cursor', async () => {
  const f = fixture(), a = await client('/first'); const font = await a.library.install(fontBytes(), 'reading.ttf');
  f.failBinary = true; await assert.rejects(a.service.sync(), /OFFLINE/); assert.equal(font.publishedFor, '');
  assert.equal(f.rows.get(font.id).manifest_jsonb, null);
  f.failBinary = false; await a.service.sync(); const b = await client('/second');
  f.failBinary = true; await assert.rejects(b.service.sync(), /OFFLINE/); assert.equal(b.service.config.cursor, '');
  f.failBinary = false; await b.service.sync(); assert.equal(b.library.fonts.length, 1);
});

test('font category switch stops font traffic; refresh precedes pulls; disconnect cannot apply an old account response', async () => {
  const f = fixture(), a = await client('/first');
  a.service.config.syncFonts = false; await a.service.sync(); assert.equal(f.calls.filter(c => c.url.includes('/sync/replicas')).length, 0);
  f.calls.length = 0;
  a.service.config.syncFonts = true; a.service.config.expiresAt = 0; await a.service.sync();
  assert.match(f.calls[0].url, /grant_type=refresh_token/); assert.ok(!f.calls[0].body.includes('password'));
  let release; const pending = new Promise(resolve => { release = resolve; }); const request = f.request;
  f.request = async (...args) => { await pending; return request(...args); };
  const sync = a.service.sync(); const disconnect = a.service.disconnect(); release();
  await assert.rejects(sync, /SESSION_CLOSED/); await disconnect;
  assert.equal(a.service.config.userId, ''); assert.equal(a.service.vault.text, '');
});

test('remote deletion removes local fonts and local deletion queues a durable tombstone while offline', async () => {
  const f = fixture(), a = await client('/first'), b = await client('/second');
  const font = await a.library.install(fontBytes(), 'reading.ttf'); await a.service.sync(); await b.service.sync();
  await a.service.removeFont(font.id); await a.service.sync(); await b.service.sync();
  assert.equal(a.library.fonts.length, 0); assert.equal(b.library.fonts.length, 0); assert.ok(f.rows.get(font.id).deleted_at_ts);
  const offlineFont = await a.library.install(fontBytes('Offline Font'), 'offline.ttf');
  const request = f.request; f.request = async () => { throw Error('OFFLINE'); };
  await a.service.removeFont(offlineFont.id); await a.service.inflight?.catch(() => {});
  assert.ok(JSON.parse(a.service.vault.text).pendingDeletes.includes(offlineFont.id));
  const restarted = await client('/first'); restarted.service.config = JSON.parse(a.service.vault.text);
  assert.equal(restarted.library.fonts.length, 0); f.request = request; await restarted.service.sync();
  assert.ok(f.rows.get(offlineFont.id).deleted_at_ts); assert.deepEqual(restarted.service.config.pendingDeletes, []);
});

test('wire validation rejects foreign accounts, unsafe paths, unsupported schema, bad clocks and malformed replies', async () => {
  const font = core.parseFont(fontBytes(), 'reading.ttf'); font.id = 'a'.repeat(32); font.partialMd5 = 'b'.repeat(32);
  const row = core.fontReplica(font, 'fixture-user', core.nextReplicaClock('', 'device'), 'device'); assert.equal(core.validFontRow(row, 'fixture-user'), true);
  for (const bad of [{ ...row, user_id: 'other' }, { ...row, schema_version: 2 }, { ...row, updated_at_ts: 'bad' },
    { ...row, manifest_jsonb: { schemaVersion: 1, files: [{ filename: '../escape.ttf', byteSize: 12, partialMd5: font.partialMd5 }] } }]) assert.equal(core.validFontRow(bad, 'fixture-user'), false);
  const config = Object.assign(new core.ReplicaSettings(), { userId: 'fixture-user', accessToken: 'fixture-token' });
  for (const body of ['{}', 'null', '{"rows":[{}]}']) {
    const client = new core.ReplicaClient({ async request() { return { status: 200, body }; } }); await assert.rejects(client.pull(config));
  }
  const a = core.nextReplicaClock('', 'device', 1000), b = core.nextReplicaClock(a, 'device', 900); assert.ok(b > a);
});

test('unsupported remote font formats remain remote without blocking supported font uploads', async () => {
  const f = fixture(), a = await client('/first');
  const remoteFont = core.parseFont(fontBytes(), 'remote.ttf'); remoteFont.id = 'a'.repeat(32); remoteFont.partialMd5 = 'b'.repeat(32);
  const row = core.fontReplica(remoteFont, 'fixture-user', core.nextReplicaClock('', 'other'), 'other');
  row.manifest_jsonb.files[0].filename = 'remote.woff2'; f.rows.set(row.replica_id, row);
  const local = await a.library.install(fontBytes('Local Font'), 'local.ttf'); await a.service.sync();
  assert.equal(a.library.fonts.length, 1); assert.equal(a.library.fonts[0].id, local.id);
  assert.ok(f.rows.has(row.replica_id)); assert.ok(f.rows.get(local.id).manifest_jsonb);
  assert.equal(f.binaryCalls.filter(call => call.options.method === 'GET').length, 0);
});

test('every expanded typography preference survives migration and invalid values cannot enter the bridge', () => {
  const input = { ...new core.ReaderSettings(), fontSize: 46, minimumFontSize: 16, fontWeight: 700, overrideFont: true,
    serifFont: '阅读测试', defaultCJKFont: '阅读测试', paragraphMargin: 1.5, wordSpacing: -1, letterSpacing: 0.5,
    marginLeftPx: 44, maxColumnCount: 3, scrolled: true };
  assert.deepEqual({ ...core.migrateAppearance(input) }, input); assert.equal(core.validAppearanceEvent(input), true);
  for (const patch of [{ maxColumnCount: 1.5 }, { wordSpacing: NaN }, { scrolled: 'yes' }, { serifFont: 'bad\nfont' }, { fontWeight: 950 }]) assert.equal(core.validAppearanceEvent({ ...input, ...patch }), false);
});
