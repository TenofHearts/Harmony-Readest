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
      }`,
      CredentialVault: 'export class CredentialVault {}',
      NativeTransport: 'export class NativeTransport { request() { throw Error("NETWORK_FORBIDDEN"); } }',
      ReaderGateway: `export class ReaderGateway {
        ready = true; session = 'import';
        async open(book, metadataOnly) {
          const f = globalThis.importFixture; f.metadataOnly = metadataOnly;
          if (f.failure) this.onEvent({ version: 1, session: this.session, type: 'error', message: f.failure });
          else this.onEvent({ version: 1, session: this.session, type: 'opened' });
        }
        async send() {} cancel() {} reset() {}
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
