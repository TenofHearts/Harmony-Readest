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
const continuous = await maliciousEPUB({ 'chapter.xhtml': `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Continuous pages</title></head><body><p>${Array.from({ length: 2400 }, (_, i) => `<span data-word="${i}">word${String(i).padStart(4, '0')}</span>`).join(' ')}</p></body></html>` });
const drm = await maliciousEPUB({ 'META-INF/encryption.xml': '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/><CipherData><CipherReference URI="chapter.xhtml"/></CipherData></EncryptedData></encryption>' });
const server = createServer(async (req, res) => {
  try {
    const name = req.url?.split('?')[0];
    if (['/books/alice.epub', '/books/evil.epub', '/books/drm.epub', '/books/continuous.epub'].includes(name)) {
      res.writeHead(200, { 'Content-Type': 'application/epub+zip' }); res.end(name.includes('continuous') ? continuous : name.includes('evil') ? evil : name.includes('drm') ? drm : epub); return;
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
    // Match restricted embedded engines: neither WASM nor native raw-deflate
    // support can be required to import/render an offline EPUB.
    window.WebAssembly = undefined;
    window.DecompressionStream = undefined;
    window.events = []; window.hacked = false;
    window.HarmonyReader = { post: value => window.events.push(JSON.parse(value)) };
  });
  await page.goto(`${origin}/reader/index.html`);
  await page.waitForFunction(() => window.readerTest && window.events.some(e => e.type === 'ready'));
  const command = async cmd => {
    await page.evaluate(async c => { window.readerReceive(c); await window.readerTest.idle(); }, { version: 1, session: 'alice', ...cmd });
  };
  const externalRequests = [];
  page.on('request', req => { if (!req.url().startsWith(origin) && !req.url().startsWith('blob:')) externalRequests.push(req.url()); });
  await command({ type: 'open', url: `${origin}/books/alice.epub`, metadataOnly: true });
  assert.equal(await page.evaluate(() => window.readerTest.getView()), undefined);
  assert.equal(await page.evaluate(() => window.events.some(e => e.type === 'cover')), true);
  assert.equal(await page.evaluate(() => window.events.at(-1).type), 'opened');
  assert.deepEqual(externalRequests, []);
  report.tests.push('Offline metadata/cover import completes without creating a renderer or contacting the internet');
  await command({ type: 'open', url: `${origin}/books/alice.epub` });
  assert.deepEqual(await page.evaluate(() => {
    const bounds = window.readerTest.getView().getBoundingClientRect();
    return { top: bounds.top, bottom: bounds.bottom, viewport: innerHeight };
  }), { top: 0, bottom: 780, viewport: 780 });
  report.tests.push('Empty error banner does not offset the reading viewport or clip its last lines');
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
  const beforeInspect = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  await command({ type: 'inspect', xpointer: target, requestId: 'preview-1' });
  const preview = await page.evaluate(() => window.events.find(e => e.requestId === 'preview-1'));
  assert.equal(preview.type, 'inspected'); assert.ok(preview.position.cfi); assert.ok(Number.isFinite(preview.position.percentage));
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), beforeInspect);
  report.tests.push('Remote conflict preview resolves locally without moving the reader');
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
  await command({ type: 'appearance', settings: { fontSize: 20, lineHeight: 1.7, theme: 'light' } });
  await page.setViewportSize({ width: 1180, height: 780 });
  await command({ type: 'open', url: `${origin}/books/continuous.epub` });
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.columnCount), 2);
  const visibleWords = () => page.evaluate(() => {
    const contents = window.readerTest.getView().renderer.getContents();
    const visible = [];
    for (const { doc } of contents) {
      const frame = doc.defaultView.frameElement.getBoundingClientRect();
      for (const span of doc.querySelectorAll('[data-word]')) {
        const r = span.getBoundingClientRect();
        const left = r.left + frame.left, right = r.right + frame.left;
        const top = r.top + frame.top, bottom = r.bottom + frame.top;
        if (left >= -1 && right <= innerWidth + 1 && top >= 0 && bottom <= innerHeight + 1) visible.push(Number(span.dataset.word));
      }
    }
    return visible.sort((a, b) => a - b);
  });
  let words = await visibleWords(); assert.ok(words.length > 20); assert.equal(words[0], 0);
  const lowestWord = await page.evaluate(() => {
    let bottom = 0;
    for (const { doc } of window.readerTest.getView().renderer.getContents()) {
      const frame = doc.defaultView.frameElement.getBoundingClientRect();
      for (const span of doc.querySelectorAll('[data-word]')) {
        const r = span.getBoundingClientRect();
        if (r.left + frame.left >= 0 && r.right + frame.left <= innerWidth && r.bottom + frame.top <= innerHeight)
          bottom = Math.max(bottom, r.bottom + frame.top);
      }
    }
    return bottom;
  });
  assert.ok(lowestWord > 700, `Text must fill the viewport, not only its upper half (lowest word: ${lowestWord})`);
  for (let spread = 0; spread < 5; spread++) {
    assert.equal(words.length, words.at(-1) - words[0] + 1, 'Every word in the visible spread is connected');
    const nextWord = words.at(-1) + 1;
    await command({ type: 'next' }); words = await visibleWords();
    assert.equal(words[0], nextWord, 'The next spread starts immediately after the previous spread');
  }
  await page.screenshot({ path: 'output/playwright/reader-two-columns.png' });
  const startCFI = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  await command({ type: 'next' });
  const expectedCFI = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  await command({ type: 'restore', cfi: startCFI, requestId: 'swipe-start' });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 900, y: 390 }] });
  for (const x of [800, 700, 600, 500]) await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: 390 }] });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForFunction(cfi => window.readerTest.getView().lastLocation.cfi === cfi, expectedCFI);
  await page.waitForTimeout(150);
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), expectedCFI, 'One touch swipe turns exactly one spread');
  await cdp.detach();
  const toggleCount = await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length);
  for (const x of [1180 * .4, 1180 * .5, 1180 * .6]) await page.mouse.click(x, 250);
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length), toggleCount + 3);
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), expectedCFI, 'Middle-third taps toggle controls without turning pages, including the gutter');
  await command({ type: 'next' });
  const expectedTapCFI = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  await command({ type: 'restore', cfi: expectedCFI, requestId: 'tap-start' });
  await page.mouse.click(1050, 250);
  await page.mouse.click(1050, 250);
  await page.waitForFunction(cfi => window.readerTest.getView().lastLocation.cfi === cfi, expectedTapCFI);
  await page.waitForTimeout(310);
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), expectedTapCFI, 'Accidental rapid duplicate taps turn once');
  await page.mouse.click(100, 250);
  await page.waitForFunction(cfi => window.readerTest.getView().lastLocation.cfi === cfi, expectedCFI);
  await page.setViewportSize({ width: 412, height: 780 });
  await page.waitForFunction(() => window.readerTest.getView().renderer.columnCount === 1);
  report.tests.push('Full-height two-column tablet spreads, five consecutive boundaries without missing words, one turn per touch swipe, middle-third controls, guarded edge taps, and single-column phone relayout');
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
  const offline = await browser.newContext({ offline: true, viewport: { width: 412, height: 780 } });
  const offlineOrigin = 'https://reader.harmonyreadest.invalid';
  const offlineUnexpected = [];
  await offline.route('**/*', async route => {
    const path = route.request().url().slice(offlineOrigin.length);
    if (route.request().url() === `${offlineOrigin}/books/alice.epub`) {
      await route.fulfill({ contentType: 'application/epub+zip', body: epub });
    } else if (['/reader/index.html', '/reader/reader.js'].includes(path)) {
      await route.fulfill({ contentType: path.endsWith('.js') ? 'text/javascript' : 'text/html',
        body: await readFile(`output/playwright/bundle/${path.split('/').pop()}`) });
    } else { offlineUnexpected.push(route.request().url()); await route.abort(); }
  });
  const offlinePage = await offline.newPage();
  await offlinePage.addInitScript(() => {
    window.events = []; window.WebAssembly = undefined; window.DecompressionStream = undefined;
    window.HarmonyReader = { post: value => window.events.push(JSON.parse(value)) };
  });
  await offlinePage.goto(`${offlineOrigin}/reader/index.html`);
  await offlinePage.waitForFunction(() => window.readerTest);
  await offlinePage.evaluate(async origin => {
    window.readerReceive({ version: 1, session: 'offline', type: 'open', url: `${origin}/books/alice.epub`, metadataOnly: true });
    await window.readerTest.idle();
    window.readerReceive({ version: 1, session: 'offline', type: 'open', url: `${origin}/books/alice.epub` });
    await window.readerTest.idle();
  }, offlineOrigin);
  assert.equal(await offlinePage.evaluate(() => navigator.onLine), false);
  assert.equal(await offlinePage.evaluate(() => window.events.filter(e => e.type === 'opened').length), 2);
  assert.ok(await offlinePage.evaluate(() => window.readerTest.getView().lastLocation.cfi));
  assert.deepEqual(offlineUnexpected, []);
  await offlinePage.screenshot({ path: 'output/playwright/reader-offline.png' });
  await offline.close();
  report.tests.push('Import and rendering succeed with the browser offline and only native-style local resource responses');
  assert.deepEqual(report.consoleErrors, []);
  await mkdir('output/playwright', { recursive: true });
  await writeFile('output/playwright/browser-results.json', JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
