import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';

// Exercise the real controller and cleanup against HarmonyOS-style filesystem
// behavior (accessSync throws for missing files), with no network available.
const result = await build({
  entryPoints: ['entry/src/main/ets/services/AppController.ets'],
  bundle: true, write: false, format: 'esm', platform: 'node',
  resolveExtensions: ['.ets', '.ts', '.js'],
  plugins: [{ name: 'native-import-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'kit' }));
    b.onLoad({ filter: /.*/, namespace: 'kit' }, () => ({ contents: `
      export const picker = { DocumentViewPicker: class { async select() { return globalThis.importFixture.selected; } } };
      export const fileIo = {
        accessSync(path) { if (!globalThis.importFixture.files.has(path)) throw Error('ENOENT'); return true; },
        unlinkSync(path) { if (!globalThis.importFixture.files.delete(path)) throw Error('ENOENT'); }
      };
      export const hilog = { error() {} }; export const connection = {};
      export const ConfigurationConstant = { ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 } };
    ` }));
    b.onResolve({ filter: /\/(Repository|CredentialVault|NativeTransport|ReaderGateway)$/ }, args => ({
      path: args.path.split('/').pop(), namespace: 'service'
    }));
    b.onLoad({ filter: /.*/, namespace: 'service' }, args => ({ contents: {
      Repository: `export class Repository {
        async importFile() {
          const f = globalThis.importFixture; f.files.add(f.draft.path); return f.draft;
        }
        async save(book) { globalThis.importFixture.saved.push(book.id); }
        async saveSettings(settings) { globalThis.importFixture.settings = structuredClone(settings); }
        async saveLibrarySettings(settings) { globalThis.importFixture.librarySettings = structuredClone(settings); }
      }`,
      CredentialVault: `export class CredentialVault {
        async save(config) {
          if (globalThis.importFixture.vaultFailure) throw Error('SAVE_FAILED');
          globalThis.importFixture.savedConfig = structuredClone(config);
        }
      }`,
      NativeTransport: 'export class NativeTransport { request() { throw Error("NETWORK_FORBIDDEN"); } }',
      ReaderGateway: `export class ReaderGateway {
        ready = true; session = 'import';
        async open(book, metadataOnly) {
          const f = globalThis.importFixture; f.metadataOnly = metadataOnly;
          if (f.failure) this.onEvent({ version: 1, session: this.session, type: 'error', message: f.failure });
          else this.onEvent({ version: 1, session: this.session, type: 'opened' });
        }
        async send(command) { globalThis.importFixture.commands = [...(globalThis.importFixture.commands || []), command]; } cancel() {} reset() {}
      }`
    }[args.path] }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}]
});
const { AppController } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

function fixture(failure = '') {
  globalThis.importFixture = { selected: ['file://picked/book.epub'], files: new Set(), saved: [], failure,
    draft: { id: 'draft', path: '/private/draft.epub', cover: '', hash: 'a'.repeat(32), position: {}, title: 'Book' } };
  const app = new AppController({}); app.attach({}); return app;
}

test('EPUB import completes offline from metadata without rendering or syncing', async () => {
  const app = fixture(); await app.importBooks();
  assert.equal(app.books.length, 1); assert.deepEqual(importFixture.saved, ['draft']);
  assert.equal(importFixture.metadataOnly, true); assert.equal(app.busy, false);
  assert.equal(app.importing, false); assert.equal(app.activeBook, undefined);
});

test('duplicate cleanup tolerates a second deletion and releases the spinner', async () => {
  const app = fixture(); app.books = [{ id: 'existing', hash: importFixture.draft.hash }];
  await app.importBooks();
  assert.equal(app.error, 'DUPLICATE_BOOK'); assert.equal(app.books.length, 1);
  assert.equal(app.busy, false); assert.equal(app.importing, false);
  assert.equal(importFixture.files.size, 0);
});

test('reader import failure preserves its real error, cleans up and allows another import', async () => {
  const app = fixture('INVALID_EPUB'); await app.importBooks();
  assert.equal(app.error, 'INVALID_EPUB'); assert.equal(app.busy, false);
  assert.equal(app.importing, false); assert.equal(importFixture.files.size, 0);
  importFixture.failure = ''; await app.importBooks();
  assert.equal(app.error, ''); assert.equal(app.books.length, 1); assert.equal(app.busy, false);
});

test('cancelled picker leaves import idle', async () => {
  const app = fixture(); importFixture.selected = []; await app.importBooks();
  assert.equal(app.books.length, 0); assert.equal(app.busy, false);
  assert.equal(app.importing, false); assert.equal(importFixture.files.size, 0);
});

test('book/app openings check remote; reconnect and background use upload-only mode', async () => {
  const app = fixture(); const calls = [];
  app.activeBook = importFixture.draft; app.config.enabled = true;
  app.sync = async (mode = 'upload') => { calls.push(mode); };
  await app.handle({ version: 1, session: app.reader.session, type: 'opened' });
  app.onForeground(); app.onNetworkAvailable(); app.onBackground();
  assert.deepEqual(calls, ['reconcile', 'reconcile', 'upload', 'upload']);
  app.conflict = { progress: '/body/DocFragment[2]/body/p' }; app.blocked = true;
  app.onNetworkAvailable(); app.onBackground(); assert.equal(calls.length, 4);
});

test('reader appearance events persist valid settings and reject stale or invalid values', async () => {
  const app = fixture(); app.activeBook = importFixture.draft;
  const event = { version: 1, session: app.reader.session, type: 'appearanceChanged', settings: { fontSize: 24, lineHeight: 1.9, themeMode: 'dark', themeColor: 'solarized' } };
  await app.handle(event);
  assert.deepEqual(importFixture.settings, event.settings);
  assert.equal(importFixture.commands.at(-1).type, 'appearance');
  const accepted = structuredClone(importFixture.settings);
  for (const invalid of [{ fontSize: 80 }, { lineHeight: NaN }, { themeMode: 'unknown' }, { themeColor: 'unknown' }]) {
    await app.handle({ ...event, settings: { ...event.settings, ...invalid } });
    assert.deepEqual(importFixture.settings, accepted);
  }
  await app.handle({ ...event, session: 'closed-book', settings: { ...event.settings, fontSize: 18 } });
  assert.deepEqual(importFixture.settings, accepted);
});

test('shelf and reader themes persist independently; system changes never overwrite either preference', async () => {
  const app = fixture(); app.activeBook = importFixture.draft;
  await app.setAppearance({ fontSize: 24, lineHeight: 1.9, themeMode: 'auto', themeColor: 'solarized' });
  const reader = structuredClone(importFixture.settings);
  const commandCount = importFixture.commands.length;
  await app.setLibraryTheme({ themeMode: 'light', themeColor: 'grass' });
  assert.deepEqual(importFixture.settings, reader);
  assert.equal(importFixture.commands.length, commandCount);
  const shelf = structuredClone(importFixture.librarySettings);
  app.setSystemDark(true);
  assert.deepEqual(importFixture.settings, reader); assert.deepEqual(importFixture.librarySettings, shelf);
  assert.equal(importFixture.commands.at(-1).type, 'systemTheme');
  assert.equal(importFixture.commands.at(-1).systemDark, true);
  await app.setAppearance({ ...reader, themeColor: 'nord' });
  assert.deepEqual(importFixture.librarySettings, shelf);
  await app.setLibraryTheme({ themeMode: 'invalid', themeColor: 'grass' });
  assert.deepEqual(importFixture.librarySettings, shelf);
});

test('native reader actions accept only available actions from the current book', async () => {
  const app = fixture(); app.activeBook = importFixture.draft; const actions = [];
  app.readerAction = action => actions.push(action);
  for (const action of ['library', 'settings', 'upload', 'reconcile', 'unsupported']) await app.handle({ version: 1, session: app.reader.session, type: 'readerAction', action });
  await app.handle({ version: 1, session: 'closed-book', type: 'readerAction', action: 'upload' });
  assert.deepEqual(actions, ['library', 'settings', 'upload', 'reconcile']);
});

test('signed-in sync options save locally without authentication, progress traffic, or credential changes', async () => {
  const app = fixture();
  Object.assign(app.config, { enabled: true, username: 'fixture-account', password: 'fixture-password', userkey: 'fixture-key', basicKey: 'fixture-basic', deviceId: 'fixture-device' });
  const credentials = { ...app.config };
  await app.updateSyncOptions(false, '  Tablet  ');
  assert.equal(importFixture.savedConfig.enabled, false); assert.equal(importFixture.savedConfig.deviceName, 'Tablet');
  for (const key of ['serverUrl', 'username', 'password', 'userkey', 'basicKey', 'deviceId']) assert.equal(app.config[key], credentials[key]);
  assert.equal(importFixture.commands, undefined);
  await app.updateSyncOptions(true, '');
  assert.equal(importFixture.savedConfig.enabled, true); assert.equal(app.config.deviceName, 'Readest');
});

test('failed sync-option persistence retains the current account and enabled state', async () => {
  const app = fixture(); Object.assign(app.config, { userkey: 'fixture-key', enabled: true, deviceName: 'Original' });
  importFixture.vaultFailure = true;
  await assert.rejects(() => app.updateSyncOptions(false, 'Replacement'), /SAVE_FAILED/);
  assert.equal(app.config.enabled, true); assert.equal(app.config.deviceName, 'Original');
  assert.equal(importFixture.savedConfig, undefined);
});
