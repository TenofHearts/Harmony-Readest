import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { loadCore } from './core-loader.mjs';
const core = await loadCore();
const result = await build({ entryPoints: ['entry/src/main/ets/services/CloudSyncService.ets'], bundle: true, write: false,
  format: 'esm', platform: 'node', resolveExtensions: ['.ets', '.ts', '.js'], plugins: [{ name: 'cloud-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'native' }));
    b.onLoad({ filter: /.*/, namespace: 'native' }, () => ({ contents: `export const util = { generateRandomUUID: () => 'id-' + (++globalThis.cloudFixture.ids) };` }));
    b.onResolve({ filter: /\/(CloudFiles|NativeTransport)$/ }, args => ({ path: args.path.split('/').pop(), namespace: 'service' }));
    b.onLoad({ filter: /.*/, namespace: 'service' }, args => ({ contents: args.path === 'NativeTransport' ?
      'export class NativeTransport { request(...args) { return globalThis.cloudFixture.request(...args); } }' : `
      export class CloudFiles {
        exists(path) { return globalThis.cloudFixture.files.has(path); }
        size(path) { return globalThis.cloudFixture.files.get(path).byteLength; }
        async bytes(path) { return globalThis.cloudFixture.files.get(path); }
        async upload(url, path) {
          const f = globalThis.cloudFixture; f.operations.push(['upload', url]);
          if (f.failUpload) throw Error('OFFLINE'); f.objects.set(url.replace('https://objects.test/', ''), f.files.get(path));
        }
        async download(url, path, hash) {
          const f = globalThis.cloudFixture; const bytes = f.objects.get(url.replace('https://objects.test/', ''));
          if (!bytes) throw Error('CLOUD_FILE_MISSING'); f.downloadHashes.push(hash); f.files.set(path, bytes);
        }
      }` }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}] });
const { CloudSyncService } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
const hash = 'a'.repeat(32), otherHash = 'b'.repeat(32);
function fixture() {
  const f = globalThis.cloudFixture = { ids: 0, files: new Map(), objects: new Map(), books: new Map(), configs: new Map(), notes: new Map(),
    operations: [], downloadHashes: [], clock: Date.now(), failUpload: false, failConfig: false };
  f.request = async (url, method, headers, body) => {
    assert.equal(headers.Authorization, 'Bearer test-token'); f.operations.push([method, url, body && JSON.parse(body)]);
    const uri = new URL(url);
    if (uri.pathname.endsWith('/storage/upload')) return { status: 200, body: JSON.stringify({ uploadUrl: 'https://objects.test/' + JSON.parse(body).fileName }) };
    if (uri.pathname.endsWith('/storage/download')) return { status: 200, body: JSON.stringify({ downloadUrl: 'https://objects.test/' + uri.searchParams.get('fileKey').replace('account/', '') }) };
    if (method === 'GET') {
      const type = uri.searchParams.get('type'), key = uri.searchParams.get('book'), since = Number(uri.searchParams.get('since'));
      if (type === 'configs' && f.failConfig) throw Error('OFFLINE');
      const rows = [...f[type].values()].filter(row => (!key || row.book_hash === key) &&
        Math.max(core.cloudTime(type === 'books' ? row.synced_at : row.updated_at), core.cloudTime(row.deleted_at)) > since);
      return { status: 200, body: JSON.stringify({ [type]: rows }) };
    }
    const data = JSON.parse(body), iso = new Date(++f.clock).toISOString();
    if (data.notes) {
      const note = data.notes[0], existing = f.notes.get(note.id);
      const row = { user_id: 'account', book_hash: note.bookHash, id: note.id, type: note.type, cfi: note.cfi,
        text: note.text, style: note.style, color: note.color, note: note.note, xpointer0: note.xpointer0,
        created_at: new Date(note.createdAt).toISOString(), updated_at: new Date(note.updatedAt).toISOString(),
        deleted_at: note.deletedAt ? new Date(note.deletedAt).toISOString() : null };
      const accepted = existing && core.noteChange(existing) > core.noteChange(row) ? existing : row;
      f.notes.set(note.id, accepted); return { status: 200, body: JSON.stringify({ notes: [accepted] }) };
    }
    if (data.books) {
      const book = data.books[0], row = { user_id: 'account', book_hash: book.hash, title: book.title, author: book.author,
        source_title: book.sourceTitle, format: book.format, uploaded_at: book.uploadedAt ? new Date(book.uploadedAt).toISOString() : null,
        deleted_at: book.deletedAt ? new Date(book.deletedAt).toISOString() : null,
        created_at: new Date(book.createdAt).toISOString(), updated_at: new Date(book.updatedAt).toISOString(), synced_at: iso };
      f.books.set(row.book_hash, row); return { status: 200, body: JSON.stringify({ books: [row], configs: [] }) };
    }
    const config = data.configs[0], row = { ...f.configs.get(config.bookHash), user_id: 'account', book_hash: config.bookHash, updated_at: new Date(config.updatedAt).toISOString() };
    for (const [key, dbKey] of [['location','location'],['xpointer','xpointer'],['progress','progress'],['viewSettings','view_settings'],['searchConfig','search_config'],['rsvpPosition','rsvp_position']]) {
      if (config[key] !== undefined) row[dbKey] = typeof config[key] === 'object' ? JSON.stringify(config[key]) : config[key];
    }
    f.configs.set(row.book_hash, row); return { status: 200, body: JSON.stringify({ configs: [row], books: [] }) };
  };
  return f;
}
function client(directory) {
  const books = [], saved = new Map(), state = new Map(), styles = [];
  const config = Object.assign(new core.ReplicaSettings(), { userId: 'account', accessToken: 'test-token', sessionEpoch: 1 });
  const replica = { config, pendingProgress: 0, async session() { return { ...config }; }, validSession(c) { return c.userId === config.userId && c.sessionEpoch === config.sessionEpoch; } };
  const store = { directory, async save(b) { saved.set(b.id, structuredClone(b)); }, async remove(b) { saved.delete(b.id); cloudFixture.files.delete(b.path); },
    async cloudState(account) { return state.get(account) || [0, 0]; }, async saveCloudState(account, cursors) { state.set(account, cursors); } };
  const hooks = { books: () => books, changed() {}, async style(book) { styles.push(book.style); }, reading: () => undefined, defaults: () => new core.ReaderSettings(), fallback: async () => null,
    sendPosition: (book, position) => service.push(book.hash, position) };
  const service = new CloudSyncService(store, replica, hooks);
  return { books, saved, state, config, replica, service, styles, hooks };
}
function localBook() {
  const book = Object.assign(new core.BookRecord(), { id: 'local', title: 'Book', author: 'Author', filename: 'book.epub', hash,
    path: '/first/local.epub', importedAt: Date.now() });
  cloudFixture.files.set(book.path, new ArrayBuffer(10)); return book;
}

test('two devices sync EPUB library, lazy content, per-book typography and cloud CFI positions', async () => {
  const f = fixture(), a = client('/first'), b = client('/second'), book = localBook(); a.books.push(book);
  book.style = Object.assign(new core.ReaderSettings(), { fontSize: 29, wordSpacing: 2, maxColumnCount: 1 }); book.styleUpdatedAt = Date.now(); book.styleDirty = true;
  await a.service.sync(a.config);
  const uploaded = f.operations.findIndex(o => o[0] === 'upload'), complete = f.operations.findIndex(o => o[2]?.books?.[0].uploadedAt);
  assert.ok(uploaded > 0 && complete > uploaded); assert.equal(book.cloudUploaded, true); assert.equal(book.styleDirty, false);
  const position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/2!/4/2)', xpointer: '/body/DocFragment[1]/body/p', percentage: .34, updatedAt: Date.now(), revision: 1 });
  await a.service.push(hash, position); await b.service.sync(b.config);
  assert.equal(b.books.length, 1); assert.equal(b.books[0].path, ''); assert.equal(b.books[0].style.fontSize, 29);
  assert.equal(b.books[0].style.wordSpacing, 2); assert.equal((await b.service.pull(hash)).cfi, position.cfi);
  await b.service.download(b.books[0]); assert.equal(b.books[0].path, '/second/id-1.epub'); assert.deepEqual(f.downloadHashes, [hash]);
  assert.deepEqual(new Uint8Array(f.files.get(b.books[0].path)), new Uint8Array(f.files.get(book.path)));
  const posts = f.operations.filter(o => o[0] === 'POST').length; await b.service.sync(b.config);
  assert.equal(f.operations.filter(o => o[0] === 'POST').length, posts);
});

test('interrupted book upload retries and marks uploaded only after successful content transfer', async () => {
  const f = fixture(), a = client('/first'), book = localBook(); a.books.push(book); f.failUpload = true;
  await assert.rejects(a.service.sync(a.config), /OFFLINE/); assert.equal(book.cloudUploaded, false);
  assert.equal(f.books.get(hash).uploaded_at, null); f.failUpload = false; await a.service.sync(a.config); assert.equal(book.cloudUploaded, true);
});

test('first cloud sync publishes existing saved progress and appearance even when KoSync already acknowledged them', async () => {
  const f = fixture(), a = client('/first'), book = localBook(); a.books.push(book);
  book.position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/4)', xpointer: '/body/DocFragment[2]/body/p', percentage: .76, updatedAt: 0, revision: 2 });
  book.dirty = false; a.hooks.defaults = () => Object.assign(new core.ReaderSettings(), { fontSize: 22 });
  await a.service.sync(a.config);
  assert.equal(f.configs.get(hash).location, book.position.cfi); assert.equal(JSON.parse(f.configs.get(hash).view_settings).defaultFontSize, 22);
  assert.equal(book.dirty, false);
});

test('first cloud sync cannot overwrite a differing KoSync fallback position in the background', async () => {
  const f = fixture(), a = client('/first'), book = localBook(); a.books.push(book);
  book.position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/4)', xpointer: '/body/DocFragment[2]/body/p', percentage: .76, revision: 2 });
  a.hooks.fallback = async () => ({ progress: '/body/DocFragment[3]/body/p', percentage: .78, timestamp: 20 });
  await a.service.sync(a.config); assert.equal(a.replica.pendingProgress, 1);
  assert.equal(f.configs.get(hash).location, undefined); assert.equal(book.position.percentage, .76);
});

test('an equivalent acknowledged KoSync fallback can seed a missing Readest position', async () => {
  const f = fixture(), a = client('/first'), book = localBook(); a.books.push(book);
  book.position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/4)', xpointer: '/body/DocFragment[2]/body/p', percentage: .76 });
  a.hooks.fallback = async () => ({ progress: book.position.xpointer, percentage: .76 });
  await a.service.sync(a.config); assert.equal(a.replica.pendingProgress, 0); assert.equal(f.configs.get(hash).location, book.position.cfi);
});

test('failed pull does not skip a cursor; timestamp ties and remote tombstones are applied', async () => {
  const f = fixture(), a = client('/first'); const iso = new Date(f.clock).toISOString();
  for (const h of [hash, otherHash]) f.books.set(h, { user_id: 'account', book_hash: h, format: 'EPUB', title: h, author: '', synced_at: iso });
  f.failConfig = true; await assert.rejects(a.service.sync(a.config), /OFFLINE/); assert.equal(a.state.size, 0);
  f.failConfig = false; await a.service.sync(a.config); assert.equal(a.books.length, 2); assert.equal(a.state.get('account')[0], f.clock);
  const row = f.books.get(hash); row.synced_at = new Date(++f.clock).toISOString(); row.deleted_at = row.synced_at;
  await a.service.sync(a.config); assert.equal(a.books.find(b => b.hash === hash).cloudDeleted, true);
  assert.equal(f.operations.filter(o => o[2]?.books?.[0]?.hash === hash).length, 0);
});

test('style uploads preserve remote position and fields this app does not edit', () => {
  const book = new core.BookRecord(); book.hash = hash; book.style = new core.ReaderSettings(); book.style.fontSize = 26; book.styleDirty = true;
  book.cloudConfig = JSON.stringify({ user_id: 'account', book_hash: hash, location: 'epubcfi(/6/4)', progress: '[7,10]',
    view_settings: JSON.stringify({ userStylesheet: 'body { color:red }', customPlugin: { value: 9 }, defaultFontSize: 12 }),
    search_config: '{"caseSensitive":true}', rsvp_position: '{"index":300}', updated_at: new Date().toISOString() });
  const payload = core.configPayload(book); assert.equal(payload.location, undefined); assert.equal(payload.progress, undefined);
  assert.equal(payload.viewSettings.defaultFontSize, 26); assert.equal(payload.viewSettings.userStylesheet, 'body { color:red }');
  assert.deepEqual(payload.viewSettings.customPlugin, { value: 9 }); assert.equal(payload.rsvpPosition, undefined);
  assert.equal(payload.searchConfig, undefined);
});

test('progress-only payloads omit styles and unrelated state so the server keeps concurrent edits', () => {
  const book = new core.BookRecord(); book.hash = hash; book.cloudConfig = JSON.stringify({ user_id: 'account', book_hash: hash,
    view_settings: '{"defaultFontSize":12}', search_config: '{"query":"new"}', rsvp_position: '{"index":300}' });
  const position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/4)', percentage: .2 });
  const payload = core.configPayload(book, position); assert.equal(payload.location, position.cfi);
  for (const key of ['viewSettings','searchConfig','rsvpPosition']) assert.equal(payload[key], undefined);
});

test('a typography-only cloud timestamp change cannot turn an acknowledged backwards edit into a conflict', () => {
  const book = new core.BookRecord(); book.position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/2)', xpointer: '/body/DocFragment[1]/body/p', percentage: .2, updatedAt: 20 }); book.dirty = true;
  const remote = { cfi: 'epubcfi(/6/4)', percentage: .4, timestamp: 10 }; book.remoteToken = core.remoteToken(remote);
  assert.equal(core.decideSync(book, { ...remote, timestamp: 50 }), 'push');
  assert.equal(core.decideSync(book, { ...remote, cfi: 'epubcfi(/6/8)' }), 'conflict');
});

test('a simultaneous local style edit stays dirty when an earlier snapshot finishes uploading', async () => {
  const f = fixture(), a = client('/first'), book = localBook(); a.books.push(book); await a.service.sync(a.config);
  book.style = new core.ReaderSettings(); book.styleDirty = true; book.styleUpdatedAt = Date.now();
  const request = f.request; let edited = false;
  f.request = async (...args) => { if (!edited && args[3]?.includes('configs')) { edited = true; book.style.fontSize = 33; book.styleUpdatedAt += 1; } return request(...args); };
  await a.service.sync(a.config); assert.equal(book.styleDirty, true); await a.service.sync(a.config);
  assert.equal(JSON.parse(f.configs.get(hash).view_settings).defaultFontSize, 33); assert.equal(book.styleDirty, false);
});

test('offline progress conflicting with cloud stays pending; compatible progress retries safely', async () => {
  const f = fixture(), a = client('/first'), book = localBook(); a.books.push(book); await a.service.sync(a.config);
  book.position = Object.assign(new core.ReadingPosition(), { cfi: 'epubcfi(/6/4)', xpointer: '/body/DocFragment[2]/body/p', percentage: .2, updatedAt: Date.now(), revision: 4 }); book.dirty = true;
  f.configs.set(hash, { user_id: 'account', book_hash: hash, location: 'epubcfi(/6/8)', progress: '[8,10]', updated_at: new Date(++f.clock).toISOString() });
  await a.service.sync(a.config); assert.equal(a.replica.pendingProgress, 1); assert.equal(book.dirty, true); assert.equal(f.configs.get(hash).location, 'epubcfi(/6/8)');
  f.configs.get(hash).location = book.position.cfi; f.configs.get(hash).updated_at = new Date(++f.clock).toISOString();
  await a.service.sync(a.config); assert.equal(book.dirty, false); assert.equal(a.replica.pendingProgress, 0);
});

test('disconnect/account change rejects an in-flight cloud response', async () => {
  const f = fixture(), a = client('/first'); let release; const gate = new Promise(r => release = r); const request = f.request;
  f.request = async (...args) => { await gate; return request(...args); };
  const work = a.service.sync({ ...a.config }); await new Promise(r => setImmediate(r)); a.config.sessionEpoch++; release();
  await assert.rejects(work, /SESSION_CLOSED/); assert.equal(a.books.length, 0); assert.equal(a.state.size, 0);
});

test('storage validates live quota numbers and signed storage requests use the canonical account key', async () => {
  const calls = [], config = Object.assign(new core.ReplicaSettings(), { userId: 'account', accessToken: 'token' });
  const client = new core.CloudClient({ async request(url, method, headers, body) {
    calls.push({ url, method, headers, body }); return { status: 200, body: JSON.stringify(url.includes('/stats') ?
      { usage: 250, quota: 1000, totalFiles: 3, totalSize: 250 } : { downloadUrl: 'https://objects.test/book' }) };
  } });
  assert.equal((await client.storage(config)).usagePercentage, 25); await client.downloadURL(config, hash);
  assert.equal(new URL(calls[1].url).searchParams.get('fileKey'), `account/Readest/Books/${hash}/${hash}.epub`);
  for (const payload of [{ usage: -1, quota: 3, totalFiles: 1, totalSize: 1 }, { usage: 3, quota: '1000', totalFiles: 1, totalSize: 3 }]) {
    await assert.rejects(new core.CloudClient({ async request() { return { status: 200, body: JSON.stringify(payload) }; } }).storage(config), /INVALID_CLOUD/);
  }
  await assert.rejects(new core.CloudClient({ async request() { return { status: 403, body: '{"error":"Insufficient storage quota"}' }; } }).uploadURL(config, hash, 10), /SYNC_QUOTA/);
});

test('both progress methods receive the chosen position, and mirror failure leaves it unacknowledged', async () => {
  const calls = [], remote = { cfi: 'epubcfi(/6/4)', percentage: .4 };
  const primary = { async authenticate() {}, async pull() { calls.push('cloud-pull'); return remote; }, async push() { calls.push('cloud-push'); return remote; } };
  const mirror = { async pull() { calls.push('ko-pull'); return null; }, async push() { calls.push('ko-push'); throw Error('OFFLINE'); } };
  const provider = new core.CombinedProgress(primary, mirror); assert.equal(await provider.pull(hash), remote);
  await assert.rejects(provider.push(hash, new core.ReadingPosition()), /OFFLINE/); assert.deepEqual(calls, ['cloud-pull', 'cloud-push', 'ko-push']);
});

test('choosing a cloud position mirrors it to KoSync; mirror failure keeps the restored position pending', async () => {
  const remote = { cfi: 'epubcfi(/6/4)', percentage: .4, timestamp: 10 }, calls = [];
  const cloud = { async pull() { return remote; }, async push() { calls.push('cloud-push'); return remote; } };
  const mirror = { async push(hash, position) { calls.push(position.cfi); throw Error('OFFLINE'); } };
  const provider = new core.CombinedProgress(cloud, mirror), book = new core.BookRecord(); book.hash = hash;
  const coordinator = new core.ProgressCoordinator(provider, { active: () => true, deviceId: '', status() {}, conflict() {},
    async save() {}, async restore() { return Object.assign(new core.ReadingPosition(), { cfi: remote.cfi, percentage: .4 }); } });
  await assert.rejects(coordinator.sync(book, 'reconcile'), /OFFLINE/);
  assert.equal(book.position.cfi, remote.cfi); assert.equal(book.dirty, true); assert.deepEqual(calls, [remote.cfi]);
});

function annotation(id, kind = 'highlight') {
  return Object.assign(new core.BookAnnotation(), { id, kind, cfi:'epubcfi(/6/2!/4/2:0)', text:'Saved passage', createdAt:Date.now() });
}
test('Readest-only clients exchange bookmarks/highlights and retain deletions across restart', async () => {
  const f=fixture(),a=client('/first'),b=client('/second'),book=localBook();a.books.push(book);
  book.annotations=[annotation('highlight'),annotation('bookmark','bookmark')];
  await a.service.sync(a.config);await b.service.sync(b.config);
  assert.deepEqual(b.books[0].annotations.map(n=>n.id).sort(),['bookmark','highlight']);
  assert.equal(f.notes.get('highlight').type,'annotation');assert.equal(f.notes.get('bookmark').type,'bookmark');
  core.recordAnnotations(book,book.annotations.filter(n=>n.id!=='highlight'));
  const request=f.request;f.request=async()=>{throw Error('OFFLINE')};await assert.rejects(a.service.sync(a.config));
  assert.ok(book.annotationSync.find(n=>n.id==='highlight').dirty);
  // Persisted book state, not a process-local delete queue, drives the next retry.
  a.books[0]=JSON.parse(JSON.stringify(book));f.request=request;await a.service.sync(a.config);await b.service.sync(b.config);
  assert.ok(f.notes.get('highlight').deleted_at);assert.deepEqual(b.books[0].annotations.map(n=>n.id),['bookmark']);
  assert.equal(b.books[0].annotationSync.find(n=>n.id==='highlight').dirty,false);
});
test('font/annotation switches are independent and disabled notes keep their cursor and pending edits', async () => {
  const f=fixture(),a=client('/first'),book=localBook();a.books.push(book);book.annotations=[annotation('mark','bookmark')];
  a.config.syncAnnotations=false;await a.service.sync(a.config);assert.equal(f.notes.size,0);
  assert.equal(f.operations.filter(o=>new URL(o[1]).searchParams.get('type')==='notes').length,0);
  a.config.syncAnnotations=true;await a.service.sync(a.config);assert.equal(f.notes.size,1);
});
test('a newer local annotation edit survives an older upload acknowledgment and retries', async () => {
  const f=fixture(),a=client('/first'),book=localBook();a.books.push(book);book.annotations=[annotation('mark')];
  await a.service.sync(a.config);
  core.recordAnnotations(book,[{...book.annotations[0],color:'#90caf9'}]);
  const request=f.request;let changed=false;
  f.request=async(...args)=>{
    if(!changed && args[3]?.includes('"notes"')){changed=true;core.recordAnnotations(book,[{...book.annotations[0],color:'#f48fb1'}]);}
    return request(...args);
  };
  await a.service.sync(a.config);assert.equal(book.annotations[0].color,'#f48fb1');assert.equal(book.annotationSync[0].dirty,true);
  await a.service.sync(a.config);assert.equal(f.notes.get('mark').color,'#f48fb1');assert.equal(book.annotationSync[0].dirty,false);
});
test('remote tombstones without locators remove notes and a tied deletion wins', () => {
  const book=new core.BookRecord();book.annotations=[annotation('mark')];core.prepareAnnotations(book,'account');
  const at=book.annotationSync[0].updatedAt;
  const row={user_id:'account',book_hash:hash,id:'mark',deleted_at:new Date(at).toISOString(),updated_at:new Date(at).toISOString()};
  assert.equal(core.validCloudNote(row,'account'),true);core.applyCloudNote(book,row);assert.equal(book.annotations.length,0);
  core.applyCloudNote(book,{...row,deleted_at:null,type:'annotation',cfi:'epubcfi(/6/2)',text:'Old'});
  assert.equal(book.annotations.length,0);
});
test('annotation edits preserve Readest note text and XPointer fields; account changes drop old tombstones', () => {
  const book=new core.BookRecord();book.hash=hash;core.prepareAnnotations(book,'account');
  const row={user_id:'account',book_hash:hash,id:'mark',type:'annotation',cfi:'epubcfi(/6/2)',text:'Quote',color:'blue',style:'highlight',
    note:'Keep this personal note',xpointer0:'/body/DocFragment[1]/body/p',created_at:new Date(100).toISOString(),updated_at:new Date(200).toISOString()};
  core.applyCloudNote(book,row);core.recordAnnotations(book,[{...book.annotations[0],color:'#fff176'}],300);
  const payload=core.notePayload(book,book.annotationSync[0]);assert.equal(payload.note,row.note);assert.equal(payload.xpointer0,row.xpointer0);
  core.recordAnnotations(book,[],400);core.prepareAnnotations(book,'another-account');assert.equal(book.annotationSync.length,0);
});
test('a failed notes pull cannot advance any cloud cursor or lose pending annotations', async () => {
  const f=fixture(),a=client('/first'),book=localBook();a.books.push(book);book.annotations=[annotation('mark')];
  const request=f.request;f.request=async(...args)=>{if(new URL(args[0]).searchParams.get('type')==='notes')throw Error('OFFLINE');return request(...args)};
  await assert.rejects(a.service.sync(a.config),/OFFLINE/);assert.equal(a.state.size,0);assert.equal(book.annotations.length,1);
  f.request=request;await a.service.sync(a.config);assert.equal(f.notes.size,1);
});
