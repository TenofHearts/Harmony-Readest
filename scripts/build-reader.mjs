import { build } from 'esbuild';
import { mkdir, readFile, writeFile, copyFile } from 'node:fs/promises';
import path from 'node:path';
import './generate-themes.mjs';
import './sync-branding.mjs';

const testing = process.argv.includes('--test');
const out = testing ? 'output/playwright/bundle' : 'entry/src/main/resources/rawfile/reader';
await mkdir(out, { recursive: true });
await build({
  entryPoints: ['reader/src/reader.ts'], bundle: true, format: 'esm', target: 'chrome105',
  outfile: `${out}/reader.js`, sourcemap: false, minifySyntax: true,
  loader: { '.css': 'text' },
  define: { __READER_TEST__: String(testing) },
  alias: { 'foliate-js': path.resolve('vendor/foliate-js') },
  plugins: [{ name: 'epub-only', setup(b) {
    b.onLoad({ filter: /\.ets$/ }, async ({ path: file }) => ({ contents: await readFile(file, 'utf8'), loader: 'ts' }));
    b.onResolve({ filter: /\/vendor\/zip\.js$/ }, () => ({ path: path.resolve('node_modules/@zip.js/zip.js/index-native.js') }));
    b.onResolve({ filter: /^\.\/(pdf|mobi|fb2|comic-book|fixed-layout)\.js$|\/vendor\/fflate\.js$/ },
      () => ({ path: 'unsupported', namespace: 'unsupported' }));
    b.onLoad({ filter: /.*/, namespace: 'unsupported' }, () => ({ contents:
      'export const makePDF=()=>{throw Error("EPUB only")}; export const isMOBI=()=>false; export class MOBI{}; export const makeFB2=makePDF; export const makeComicBook=makePDF; export const unzlibSync=makePDF;' }));
    // Upstream allows scripts for dynamic EPUB content. This app deliberately disables them.
    b.onLoad({ filter: /foliate-js[\\/]paginator\.js$/ }, async ({ path: file }) => ({
      contents: (await readFile(file, 'utf8')).replace("'allow-same-origin allow-scripts'", "'allow-same-origin'"), loader: 'js'
    }));
  }}]
});
await copyFile('reader/index.html', `${out}/index.html`);
await writeFile(`${out}/provenance.json`, await readFile('vendor/revisions.json'));
const notices = await readFile('THIRD_PARTY_NOTICES.md', 'utf8');
const licenses = await Promise.all(['LICENSE', 'vendor/foliate-js/LICENSE', 'node_modules/@zip.js/zip.js/LICENSE',
  'node_modules/js-md5/LICENSE.txt'].map(file => readFile(file, 'utf8')));
await writeFile(`${out}/licenses.txt`, [notices, ...licenses].join('\n\n---\n\n'));
console.log(`Offline EPUB reader built into ${out}`);
