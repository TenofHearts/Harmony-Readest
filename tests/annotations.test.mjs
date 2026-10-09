import test from 'node:test';
import assert from 'node:assert/strict';
import { loadCore } from './core-loader.mjs';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
const { validAnnotations, BookRecord, bookDetails } = await loadCore();
const mark = { id: 'one', kind: 'highlight', cfi: 'epubcfi(/6/2!/4/2:1)', text: 'Text', chapter: 'Chapter', percentage: 0.5, color: '#fff176', createdAt: 1 };

test('annotation messages reject duplicate IDs, excessive payloads, bad locators and unsafe colors', () => {
  assert.equal(validAnnotations([mark]), true); assert.equal(validAnnotations([]), true);
  for (const items of [[mark, mark], Array(2001).fill(mark), [{ ...mark, cfi: 'javascript:alert(1)' }],
    [{ ...mark, text: 'x'.repeat(16385) }], [{ ...mark, percentage: NaN }], [{ ...mark, createdAt: -1 }],
    [{ ...mark, color: 'url(https://example.com)' }], [{ ...mark, kind: 'script' }], [null], null]) assert.equal(validAnnotations(items), false);
});

test('details use EPUB metadata, decode readable descriptions and tolerate older or malformed books', () => {
  const book = new BookRecord(); book.title = 'Title'; book.author = 'Author'; book.filename = 'book.epub'; book.position.percentage = 0.35;
  book.metadataJSON = JSON.stringify({ publisher: [{ name: 'Publisher' }], language: ['en', 'zh'], identifier: 'ISBN',
    description: '<p>First &amp; second.</p><script>malicious()</script><p>Next.</p>' });
  const details = bookDetails(book);
  assert.equal(details.title, 'Title'); assert.equal(details.publisher, 'Publisher'); assert.equal(details.language, 'en, zh');
  assert.equal(details.progress, '35%'); assert.match(details.description, /First & second\./); assert.doesNotMatch(details.description, /<|malicious/);
  book.metadataJSON = '{broken'; assert.equal(bookDetails(book).filename, 'book.epub'); assert.equal(bookDetails(book).description, '');
});

const repositoryBundle = await build({ entryPoints: ['entry/src/main/ets/services/Repository.ets'], bundle: true, write: false, format: 'esm', platform: 'node',
  resolveExtensions: ['.ets', '.ts', '.js'], plugins: [{ name: 'annotation-storage-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'kit' }));
    b.onLoad({ filter: /.*/, namespace: 'kit' }, () => ({ contents: 'export const preferences = {}; export const relationalStore = {}; export const fileIo = {}; export const util = {};' }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}] });
const { Repository } = await import(`data:text/javascript;base64,${Buffer.from(repositoryBundle.outputFiles[0].text).toString('base64')}`);

test('real repository reloads saved bookmarks/highlights and migrates books without annotations', async () => {
  const records = new Map();
  const database = {
    async executeSql(sql, [id, record]) { records.set(id, record); },
    async querySql() { const items = [...records.values()]; let index = -1; return { goToNextRow: () => ++index < items.length, getString: () => items[index], close() {} }; }
  };
  const original = new Repository(); original.db = database;
  const book = new BookRecord(); book.id = 'book'; book.annotations = [mark]; await original.save(book);
  records.set('legacy', JSON.stringify({ id: 'legacy', position: {} }));
  const restarted = new Repository(); restarted.db = database;
  const restored = await restarted.list(); assert.deepEqual(restored.find(item => item.id === 'book').annotations, [mark]);
  assert.deepEqual(restored.find(item => item.id === 'legacy').annotations, []);
  book.annotations = []; await original.save(book); assert.deepEqual((await restarted.list()).find(item => item.id === 'book').annotations, []);
});
