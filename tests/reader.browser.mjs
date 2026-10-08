import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { BlobWriter, TextReader, ZipWriter } from '@zip.js/zip.js';
const fixtureRoot = 'vendor/readest/apps/readest-app/src/__tests__/fixtures';
const epub = await readFile(`${fixtureRoot}/data/sample-alice.epub`);
const oracle = JSON.parse(await readFile(`${fixtureRoot}/crengine/sample-alice.json`, 'utf8'));

async function maliciousEPUB(extra = {}) {
  const writer = new ZipWriter(new BlobWriter('application/epub+zip'));
  const files = {
    mimetype: 'application/epub+zip',
    'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    'book.opf': '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">security</dc:identifier><dc:title>Security fixture</dc:title><dc:language>en</dc:language></metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>',
    'chapter.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Security</title><script>parent.hacked=true;parent.HarmonyReader.post("evil");</script></head><body onload="parent.hacked=true"><p>Scripts must not run.</p><img src="https://example.com/tracking.png"/><a href="https://example.com/escape">Outside</a></body></html>',
    ...extra
  };
  for (const [name, text] of Object.entries(files)) await writer.add(name, new TextReader(text));
  return Buffer.from(await (await writer.close()).arrayBuffer());
}
const evil = await maliciousEPUB();
const drm = await maliciousEPUB({ 'META-INF/encryption.xml': '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/><CipherData><CipherReference URI="chapter.xhtml"/></CipherData></EncryptedData></encryption>' });
const server = createServer(async (req, res) => {
  try {
    const name = req.url?.split('?')[0];
    if (name === '/books/alice.epub' || name === '/books/evil.epub' || name === '/books/drm.epub') {
      res.writeHead(200, { 'Content-Type': 'application/epub+zip' }); res.end(name.includes('evil') ? evil : name.includes('drm') ? drm : epub); return;
    }
    if (!['/reader/index.html', '/reader/reader.js'].includes(name)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': name.endsWith('.js') ? 'text/javascript' : 'text/html' });
    res.end(await readFile(`output/playwright/bundle/${name.split('/').pop()}`));
  } catch { res.writeHead(500); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
await mkdir('output/playwright', { recursive: true });
let browser;
const report = { tests: [], oracleWords: 0, consoleErrors: [] };
try {
  browser = await chromium.launch({ channel: process.env.PW_CHANNEL || 'msedge', headless: true });
  const page = await browser.newPage({ viewport: { width: 412, height: 780 } });
  page.on('pageerror', error => report.consoleErrors.push(error.message));
  await page.addInitScript(() => {
    window.events = []; window.hacked = false;
    window.HarmonyReader = { post: value => window.events.push(JSON.parse(value)) };
  });
  await page.goto(`${origin}/reader/index.html`);
  await page.waitForFunction(() => window.readerTest && window.events.some(e => e.type === 'ready'));
  const command = async cmd => {
    await page.evaluate(async c => { window.readerReceive(c); await window.readerTest.idle(); }, { version: 1, session: 'alice', ...cmd });
  };
  await command({ type: 'open', url: `${origin}/books/alice.epub` });
  assert.equal(await page.evaluate(() => window.events.some(e => e.type === 'opened')), true,
    JSON.stringify(await page.evaluate(() => window.events)));
  const metadata = await page.evaluate(() => window.events.find(e => e.type === 'metadata').metadata);
  assert.match(metadata.title, /Alice/); assert.ok(metadata.toc.length > 5);
  // Golden digest of the pinned fixture, independently computed from its six sampled blocks.
  assert.equal(metadata.hash, '32bb20d7452627491831bb64a8d0dd94'); report.tests.push('EPUB metadata, TOC and compatible binary digest');
  const oracleResult = await page.evaluate(async oracle => {
    const { XCFI } = window.readerTest, book = window.readerTest.getBook();
    const failures = []; let count = 0;
    for (const fragment of oracle.fragments) {
      const doc = await book.sections[fragment.index].createDocument();
      const converter = new XCFI(doc, fragment.index);
      for (const word of fragment.words) {
        count++;
        const indexed = xp => xp.replace(/^\/body\/DocFragment\//, '/body/DocFragment[1]/');
        const xp = indexed(word.xp), end = indexed(word.xp_end);
        try {
          const cfi = converter.xPointerToCFI(xp, end);
          const resolved = book.resolveCFI(cfi); const range = resolved.anchor(doc);
          if (range.toString() !== word.text) failures.push(`${xp}: wrong word`);
          const back = converter.cfiToXPointer(cfi);
          if (back.pos0 !== xp || back.pos1 !== end) failures.push(`${xp}: wrong round trip`);
        } catch (e) { failures.push(`${xp}: ${e.message}`); }
      }
    }
    return { count, failures };
  }, oracle);
  assert.deepEqual(oracleResult.failures.slice(0, 10), []); report.oracleWords = oracleResult.count;
  report.tests.push('Every upstream CREngine oracle word resolves and round trips');
  const target = oracle.fragments.find(f => f.index === 5).words[5].xp;
  await command({ type: 'restore', xpointer: target, requestId: 'restore-1' });
  const restored = await page.evaluate(() => window.events.find(e => e.requestId === 'restore-1'));
  assert.equal(restored.type, 'restored'); assert.ok(restored.position.cfi);
  const beforeNext = await page.evaluate(() => window.events.length);
  await command({ type: 'next' });
  assert.equal(await page.evaluate(start => window.events.slice(start).some(e => e.type === 'position' && !e.restored), beforeNext), true,
    JSON.stringify(await page.evaluate(start => window.events.slice(start), beforeNext)));
  const after = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  assert.notEqual(after, restored.position.cfi);
  await command({ type: 'open', url: `${origin}/books/alice.epub`, cfi: after });
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), after);
  report.tests.push('Exact remote locator, page turn and reopen at saved CFI');
  await command({ type: 'restore', xpointer: '/body/DocFragment[999]/body/p', requestId: 'invalid' });
  assert.equal(await page.evaluate(() => window.events.find(e => e.requestId === 'invalid').type), 'error');
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), after);
  await command({ session: 'stale', type: 'next' });
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), after);
  report.tests.push('Unresolvable and stale-session commands cannot move the reader');
  await command({ type: 'appearance', settings: { fontSize: 24, lineHeight: 1.9, theme: 'dark' } });
  await page.setViewportSize({ width: 780, height: 412 });
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-landscape.png' });
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(25, 35, 33)');
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'position').at(-1).restored), true);
  report.tests.push('Appearance and landscape relayout');
  const tracking = [];
  page.on('request', req => { if (req.url().startsWith('https://example.com')) tracking.push(req.url()); });
  await command({ type: 'open', url: `${origin}/books/evil.epub` });
  await page.waitForTimeout(200);
  assert.equal(await page.evaluate(() => window.hacked), false);
  assert.deepEqual(tracking, [], await page.evaluate(() => window.readerTest.getView().renderer.getContents()[0].doc.head.innerHTML));
  const sandbox = await page.evaluate(() => window.readerTest.getView().renderer.getContents()[0].doc.defaultView.frameElement.getAttribute('sandbox'));
  assert.equal(sandbox.includes('allow-scripts'), false);
  report.tests.push('EPUB scripts and external tracking resources are blocked');
  await page.setViewportSize({ width: 412, height: 780 });
  await page.screenshot({ path: 'output/playwright/security-fixture.png' });
  await command({ type: 'open', url: `${origin}/books/drm.epub` });
  assert.equal(await page.evaluate(() => window.events.at(-1).message), 'DRM_OR_ENCRYPTED');
  report.tests.push('EPUB content encryption is rejected before rendering');
  assert.deepEqual(report.consoleErrors, []);
  await mkdir('output/playwright', { recursive: true });
  await writeFile('output/playwright/browser-results.json', JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
