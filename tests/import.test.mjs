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
      export const fileUri = { getUriFromPath: path => 'file://' + path };
      export const uniformTypeDescriptor = { UniformDataType: { EPUB: 'general.epub' } };
      export const systemShare = {
        SharedData: class { constructor(record) { this.record = record; } },
        SharePreviewMode: { DETAIL: 1 },
        ShareController: class { constructor(data) { this.data = data; } async show(context, options) {
          globalThis.importFixture.shared = { record: this.data.record, context, options };
        } }
      };
      export const fileIo = {
        accessSync(path) { if (!globalThis.importFixture.files.has(path)) throw Error('ENOENT'); return true; },
        unlinkSync(path) { if (!globalThis.importFixture.files.delete(path)) throw Error('ENOENT'); }
      };
      export const hilog = { error() {} }; export const connection = {};
      export const preferences = {}; export const cryptoFramework = {}; export const util = {}; export const font = {}; export const http = {};
      export const ConfigurationConstant = { ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 } };
      export const i18n = { System: { getSystemLanguage: () => globalThis.importFixture.systemLanguage || 'en',
        setAppPreferredLanguage: language => { globalThis.importFixture.preferredLanguage = language; } } };
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
        async saveLanguage(language) {
          const f = globalThis.importFixture;
          f.languageWrites = [...(f.languageWrites || []), language];
          await f.saveLanguage?.(language);
          f.language = language;
        }
      }`,
      CredentialVault: `export class CredentialVault {
        async save(config) {
          if (globalThis.importFixture.vaultFailure) throw Error('SAVE_FAILED');
          globalThis.importFixture.savedConfig = structuredClone(config);
        }
      }`,
      NativeTransport: 'export class NativeTransport { request() { throw Error("NETWORK_FORBIDDEN"); } }',
      ReaderGateway: `export const READER_ORIGIN = 'https://reader.harmonyreadest.invalid'; export class ReaderGateway {
        ready = true; session = 'import';
        async open(book, metadataOnly, settings, systemDark) {
          const f = globalThis.importFixture; f.metadataOnly = metadataOnly; f.openSettings = structuredClone(settings); f.openSystemDark = systemDark;
          if (f.failure) this.onEvent({ version: 1, session: this.session, type: 'error', message: f.failure });
          else this.onEvent({ version: 1, session: this.session, type: 'opened' });
        }
        async send(command) {
          globalThis.importFixture.commands = [...(globalThis.importFixture.commands || []), command];
          if (command.type === 'close') this.onEvent({ version: 1, session: this.session, type: 'closed' });
        } cancel() {} reset() {}
      }`
    }[args.path] }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}]
});
const { AppController } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

function fixture(failure = '') {
  globalThis.importFixture = { selected: ['file://picked/book.epub'], files: new Set(), saved: [], failure,
    draft: { id: 'draft', path: '/private/draft.epub', cover: '', hash: 'a'.repeat(32), position: {}, title: 'Book' } };
  const app = new AppController({ getApplicationContext: () => ({ setLanguage: language => {
    importFixture.languageCalls = (importFixture.languageCalls || 0) + 1;
    if (importFixture.languageCalls > 8) throw Error('RECURSIVE_LANGUAGE_CHANGE');
    if (importFixture.languageFailure) throw Error('LANGUAGE_FAILED');
    importFixture.appliedLanguage = language; importFixture.onConfiguration?.();
  } }) }); app.attach({}); return app;
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

test('EPUB sharing sends the actual private file URI and EPUB type to the system sheet', async () => {
  const app = fixture(); const book = importFixture.draft; book.author = 'Author'; importFixture.files.add(book.path);
  await app.share(book);
  assert.deepEqual(importFixture.shared.record, { utd: 'general.epub', uri: 'file:///private/draft.epub', title: 'Book', description: 'Author' });
  assert.equal(importFixture.shared.options.previewMode, 1);
  importFixture.files.clear(); importFixture.shared = undefined;
  await assert.rejects(app.share(book)); assert.equal(importFixture.shared, undefined);
});

test('the combined sync action refreshes the library and reconciles progress once', async () => {
  const app = fixture(); const calls = [];
  app.replica.sync = async () => { calls.push('library'); };
  app.sync = async mode => { calls.push(mode); };
  await app.syncNow(); assert.deepEqual(calls, ['library', 'reconcile']);
});

test('annotations persist only for the opened current book and reject malformed bridge records', async () => {
  const app = fixture(); const book = importFixture.draft; app.activeBook = book; app.books = [book];
  await app.handle({ version: 1, session: app.reader.session, type: 'opened' }); importFixture.saved = [];
  const annotations = [{ id: 'mark', kind: 'highlight', cfi: 'epubcfi(/6/2!/4/2:1)', text: 'Passage', chapter: 'Chapter', percentage: 0.2, color: '#fff176', createdAt: 10 }];
  const event = { version: 1, session: app.reader.session, type: 'annotationsChanged', annotations };
  await app.handle(event); assert.deepEqual(book.annotations, annotations); assert.deepEqual(importFixture.saved, ['draft']);
  for (const invalid of [{ ...event, session: 'previous-book', annotations: [] }, { ...event, annotations: [{ ...annotations[0], percentage: 2 }] },
    { ...event, annotations: [{ ...annotations[0], color: 'url(https://example.com)' }] }]) await app.handle(invalid);
  assert.deepEqual(book.annotations, annotations); assert.equal(importFixture.saved.length, 1);
  await app.handle({ ...event, annotations: [] }); assert.deepEqual(book.annotations, []);
});

test('concurrent import taps launch one picker; a picker failure releases the guard for retry', async () => {
  const app = fixture(); let picks = 0, release;
  app.reader.ready = true;
  const waiting = new Promise(resolve => { release = resolve; });
  Object.defineProperty(importFixture, 'selected', { configurable: true, get() { picks++; return waiting; } });
  const first = app.importBooks(); await app.importBooks(); assert.equal(picks, 1);
  release([]); await first;
  Object.defineProperty(importFixture, 'selected', { configurable: true, value: Promise.reject(Error('PICKER_FAILED')) });
  await assert.rejects(app.importBooks(), /PICKER_FAILED/);
  Object.defineProperty(importFixture, 'selected', { configurable: true, value: [] });
  await app.importBooks(); assert.equal(app.busy, false); assert.equal(app.picking, false);
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
  for (const key of Object.keys(event.settings)) assert.equal(importFixture.settings[key], event.settings[key]);
  assert.equal(importFixture.commands.at(-1).type, 'appearance');
  const accepted = structuredClone(importFixture.settings);
  for (const invalid of [{ fontSize: 121 }, { lineHeight: NaN }, { themeMode: 'unknown' }, { themeColor: 'unknown' }]) {
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
  for (const action of ['library', 'settings', 'sync', 'share', 'upload', 'reconcile', 'unsupported']) await app.handle({ version: 1, session: app.reader.session, type: 'readerAction', action });
  await app.handle({ version: 1, session: 'closed-book', type: 'readerAction', action: 'share' });
  assert.deepEqual(actions, ['library', 'settings', 'sync', 'share']);
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

test('shelf defaults override old book colors/fonts on every opening without replacing saved book layout or defaults', async () => {
  const app = fixture();
  await app.setAppearance({ themeMode: 'dark', themeColor: 'nord', serifFont: 'Selected Font', overrideFont: true, fontSize: 24 });
  const defaults = structuredClone(importFixture.settings);
  const book = importFixture.draft; book.style = { themeMode: 'light', themeColor: 'sepia', serifFont: 'Old Font', fontSize: 32, lineHeight: 2 };
  app.books = [book]; importFixture.files.add(book.path);
  await app.open(book); await app.events;
  assert.equal(app.activeAppearance.themeMode, 'dark'); assert.equal(app.activeAppearance.themeColor, 'nord');
  assert.equal(app.activeAppearance.serifFont, 'Selected Font'); assert.equal(app.activeAppearance.fontSize, 32);
  assert.equal(importFixture.openSettings.themeColor, 'nord'); assert.deepEqual(importFixture.settings, defaults);
  await app.close();
  await app.setAppearance({ ...defaults, themeMode: 'light', themeColor: 'grass', serifFont: 'Next Font' });
  await app.open(book); await app.events;
  assert.equal(importFixture.openSettings.themeColor, 'grass'); assert.equal(importFixture.openSettings.serifFont, 'Next Font');
  assert.equal(importFixture.openSettings.fontSize, 32); await app.close();
});

test('reader ready only reapplies settings; it cannot write appearance defaults', async () => {
  const app = fixture(); app.initialized = true;
  await app.handle({ version: 1, session: '', type: 'ready' });
  assert.equal(importFixture.settings, undefined); assert.equal(importFixture.commands.at(-1).type, 'appearance');
});

test('closing saves the latest position and returns without waiting for a stalled upload, including repeated close taps', async () => {
  const app = fixture(), book = importFixture.draft;
  book.position = { cfi: 'epubcfi(old)', revision: 0, percentage: 0, updatedAt: 0 };
  book.syncScope = app.scope(); app.books = [book]; app.activeBook = book; app.opened = true;
  await app.handle({ version: 1, session: app.reader.session, type: 'position', position: { cfi: 'epubcfi(new)', percentage: .6 } });
  let uploaded = false;
  app.coordinator = { uploadPending(value, active) { assert.equal(value.position.cfi, 'epubcfi(new)'); assert.equal(active(), true); uploaded = true; return new Promise(() => {}); } };
  app.sync = () => { throw Error('Navigation must not await sync'); };
  let timer;
  try {
    await Promise.race([Promise.all([app.close(), app.close()]), new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Close stalled')), 250); })]);
  } finally { clearTimeout(timer); }
  assert.equal(app.activeBook, undefined); assert.equal(app.busy, false); assert.equal(uploaded, true);
  assert.equal(importFixture.saved.at(-1), book.id);
  assert.equal(importFixture.commands.filter(c => c.type === 'close').length, 1);
});

test('language selection persists, immediately applies English/Chinese, and System tracks later OS changes', async () => {
  const app = fixture(); importFixture.systemLanguage = 'zh-Hans';
  await app.setLanguage('en'); assert.equal(importFixture.language, 'en'); assert.equal(importFixture.appliedLanguage, 'en');
  await app.setLanguage('zh-Hans'); assert.equal(importFixture.language, 'zh-Hans'); assert.equal(importFixture.appliedLanguage, 'zh-Hans');
  await app.setLanguage('auto'); assert.equal(importFixture.preferredLanguage, undefined); assert.equal(importFixture.appliedLanguage, 'zh-Hans');
  importFixture.systemLanguage = 'en'; app.onLanguageChanged(); assert.equal(importFixture.appliedLanguage, 'en');
  await app.setLanguage('invalid'); assert.equal(importFixture.language, 'auto');
});

test('synchronous HarmonyOS language callbacks cannot reenter language application during startup or System changes', async () => {
  const app = fixture(); importFixture.systemLanguage = 'zh-Hans';
  importFixture.onConfiguration = () => { app.setSystemDark(false); app.onLanguageChanged(); };
  app.onLanguageChanged();
  assert.equal(importFixture.languageCalls, 1); assert.equal(importFixture.appliedLanguage, 'zh-Hans');
  app.onLanguageChanged(); assert.equal(importFixture.languageCalls, 1);
  importFixture.systemLanguage = 'en'; app.onLanguageChanged();
  assert.equal(importFixture.languageCalls, 2); assert.equal(importFixture.appliedLanguage, 'en');
  await app.setLanguage('zh-Hans'); assert.equal(importFixture.languageCalls, 3);
  await app.setLanguage('auto'); assert.equal(importFixture.languageCalls, 4);
});

test('a failed native language application releases its guard so a later configuration callback can retry', () => {
  const app = fixture(); importFixture.languageFailure = true;
  assert.throws(() => app.onLanguageChanged(), /LANGUAGE_FAILED/);
  importFixture.languageFailure = false; app.onLanguageChanged();
  assert.equal(importFixture.languageCalls, 2); assert.equal(importFixture.appliedLanguage, 'en');
});

test('consecutive language choices update immediately while ordered persistence is stalled', async () => {
  const app = fixture(); importFixture.systemLanguage = 'zh-Hans';
  let release; const pending = new Promise(resolve => { release = resolve; });
  importFixture.saveLanguage = language => language === 'en' ? pending : undefined;
  let refreshes = 0; app.changed = () => { refreshes++; };
  importFixture.onConfiguration = () => {
    app.setSystemDark(false); app.onLanguageChanged(importFixture.appliedLanguage);
  };
  const first = app.setLanguage('en');
  assert.equal(app.language, 'en'); assert.equal(importFixture.appliedLanguage, 'en');
  await Promise.resolve();
  const second = app.setLanguage('zh-Hans');
  assert.equal(app.language, 'zh-Hans'); assert.equal(importFixture.appliedLanguage, 'zh-Hans');
  assert.equal(importFixture.languageCalls, 2); assert.equal(refreshes, 2);
  assert.equal(importFixture.preferredLanguage, undefined);
  app.onLanguageChanged('zh-Hans'); app.setSystemDark(false);
  await app.setLanguage('zh-Hans');
  assert.equal(refreshes, 2); assert.equal(importFixture.languageCalls, 2);
  assert.deepEqual(importFixture.commands || [], []);
  release(); await Promise.all([first, second]);
  assert.deepEqual(importFixture.languageWrites, ['en', 'zh-Hans']);
  assert.equal(importFixture.language, 'zh-Hans');
});

test('language write failures do not block later choices, and native failures restore the selection', async () => {
  const app = fixture();
  importFixture.saveLanguage = language => { if (language === 'en') throw Error('FLUSH_FAILED'); };
  await assert.rejects(app.setLanguage('en'), /FLUSH_FAILED/);
  await app.setLanguage('zh-Hans'); assert.equal(importFixture.language, 'zh-Hans');
  importFixture.languageFailure = true;
  await assert.rejects(app.setLanguage('en'), /LANGUAGE_FAILED/);
  assert.equal(app.language, 'zh-Hans'); assert.equal(importFixture.appliedLanguage, 'zh-Hans');
  importFixture.languageFailure = false; importFixture.saveLanguage = undefined;
  await app.setLanguage('en'); assert.equal(importFixture.language, 'en');
});
