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
const styled = await maliciousEPUB({ 'chapter.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Typography</title><style>html{font-family:Georgia}p{font-size:12px;line-height:1.2;margin:3px;text-align:left;text-indent:0;hyphens:none}code{font-family:Georgia}</style></head><body><p id="copy">Publisher font and layout. <span id="tiny" style="font-size:6px">Small print</span></p><pre><code id="code">const reading = true;</code></pre></body></html>' });
let customFontBytes;
for (const filename of [process.env.READER_TEST_FONT, 'C:/Windows/Fonts/arial.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'].filter(Boolean)) {
  try { customFontBytes = await readFile(filename); break; } catch {}
}
if (!customFontBytes) throw Error('Set READER_TEST_FONT to a local TTF or OTF for custom-font rendering checks');
const server = createServer(async (req, res) => {
  try {
    const name = req.url?.split('?')[0];
    if (name === '/fonts/test.ttf') { res.writeHead(200, { 'Content-Type': 'font/ttf' }); res.end(customFontBytes); return; }
    if (['/books/alice.epub', '/books/evil.epub', '/books/drm.epub', '/books/continuous.epub', '/books/styled.epub'].includes(name)) {
      res.writeHead(200, { 'Content-Type': 'application/epub+zip' }); res.end(name.includes('styled') ? styled : name.includes('continuous') ? continuous : name.includes('evil') ? evil : name.includes('drm') ? drm : epub); return;
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
  const openMenuPanel = async action => {
    await page.locator('.header-bar [data-action="menu"]').click();
    await page.locator(`.view-menu [data-action="${action}"]`).click();
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
  const assertBarsHidden = async (target, hidden) => {
    for (const selector of ['.header-bar', '.footer-bar']) {
      assert.equal(await target.locator(selector).getAttribute('aria-hidden'), String(hidden));
      assert.equal(await target.locator(selector).evaluate(el => el.inert), hidden);
    }
  };
  await assertBarsHidden(page, true);
  await command({ type: 'chrome', chrome: { syncEnabled: false, status: 'Offline ready' } });
  await assertBarsHidden(page, true);
  await page.mouse.click(206, 390);
  await assertBarsHidden(page, false);
  await page.mouse.click(206, 390);
  await assertBarsHidden(page, true);
  await page.mouse.click(206, 390);
  await assertBarsHidden(page, false);
  report.tests.push('Books open with toolbar and progress bar hidden; status updates preserve that state and center taps reveal and hide both bars');
  assert.deepEqual(await page.evaluate(() => {
    const bounds = window.readerTest.getView().getBoundingClientRect();
    return { top: bounds.top, bottom: bounds.bottom, viewport: innerHeight };
  }), { top: 0, bottom: 780, viewport: 780 });
  report.tests.push('Empty error banner does not offset the reading viewport or clip its last lines');
  assert.equal(await page.evaluate(() => window.events.some(e => e.type === 'opened')), true,
    JSON.stringify(await page.evaluate(() => window.events)));
  const metadata = await page.evaluate(() => window.events.find(e => e.type === 'metadata').metadata);
  assert.match(metadata.title, /Alice/); assert.ok(metadata.toc.length > 5);
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.hasAttribute('animated')), true);
  const motion = await page.locator('.header-bar').evaluate(el => ({
    properties: getComputedStyle(el).transitionProperty, duration: getComputedStyle(el).transitionDuration
  }));
  assert.deepEqual(motion, { properties: 'opacity, margin-top', duration: '0.3s' });
  const firstCFI = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  const turnSamples = await page.evaluate(async () => {
    const samples = []; let sampling = true;
    const sample = () => {
      const doc = window.readerTest.getView().renderer.getContents()[0]?.doc;
      if (doc) samples.push(Math.round(doc.defaultView.frameElement.getBoundingClientRect().left));
      if (sampling) requestAnimationFrame(sample);
    };
    sample(); window.readerReceive({ version: 1, session: 'alice', type: 'next' });
    await window.readerTest.idle(); sampling = false; sample();
    return [...new Set(samples)];
  });
  assert.ok(turnSamples.length > 2, `The upstream page turn must render intermediate positions (${turnSamples})`);
  await command({ type: 'restore', cfi: firstCFI, requestId: 'motion-reset' });
  const phoneBounds = await page.locator('foliate-view').boundingBox();
  await page.locator('.mobile-tools [data-action="progress"]').click();
  assert.equal(await page.locator('[data-panel="progress"]').getAttribute('aria-hidden'), 'false');
  const assertPageProgress = async () => {
    const expected = await page.evaluate(() => {
      const { current, total } = window.readerTest.getView().lastLocation.location;
      return `${Math.min(total, current + 1)} / ${total}`;
    });
    assert.equal(await page.locator('[data-panel="progress"] .page-progress').textContent(), expected);
    assert.equal(await page.locator('.desktop-tools .page-progress').textContent(), expected);
    assert.equal(await page.locator('[data-action="historyBack"], [data-action="historyForward"]').count(), 0);
  };
  await assertPageProgress();
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-progress-panel.png' });
  await page.locator('[data-panel="progress"] [data-action="next"]').click();
  await page.evaluate(() => window.readerTest.idle());
  assert.notEqual(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), firstCFI);
  await assertPageProgress();
  report.tests.push('Phone and tablet progress controls show Foliate current/total pages after page turns, with no history arrow buttons');
  await command({ type: 'restore', cfi: firstCFI, requestId: 'chrome-reset' });
  await command({ type: 'back' });
  await openMenuPanel('font');
  await page.locator('[data-action="increase"]').click();
  await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('[data-font-size]').textContent(), '22');
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'appearanceChanged').at(-1).settings.fontSize), 22);
  await command({ type: 'back' });
  await openMenuPanel('color');
  assert.equal(await page.locator('[data-theme]').count(), 11);
  await page.locator('[data-mode="dark"]').click();
  await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('[data-mode="dark"]').getAttribute('aria-checked'), 'true');
  await page.locator('[data-theme="solarized"]').click();
  await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('[data-theme="solarized"]').getAttribute('aria-pressed'), 'true');
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(0, 43, 54)');
  await page.emulateMedia({ colorScheme: 'light' });
  await page.locator('[data-mode="auto"]').click();
  await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(253, 246, 227)');
  const savedChoices = await page.evaluate(() => window.events.filter(e => e.type === 'appearanceChanged').length);
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.waitForFunction(() => document.body.style.background === 'rgb(0, 43, 54)');
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'appearanceChanged').length), savedChoices);
  await command({ type: 'systemTheme', systemDark: false });
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(253, 246, 227)');
  await command({ type: 'systemTheme', systemDark: true });
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(0, 43, 54)');
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'appearanceChanged').length), savedChoices);
  await page.locator('[data-mode="light"]').click();
  await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(253, 246, 227)');
  await page.locator('[data-mode="dark"]').click();
  await page.evaluate(() => window.readerTest.idle());
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-theme-panel-dark.png' });
  report.tests.push('All 11 official schemes, independent mode/color controls, live System mode, native system appearance override, and explicit mode without preference rewrites');
  await command({ type: 'appearance', settings: { fontSize: 20, themeMode: 'light', themeColor: 'default' } });
  await command({ type: 'back' });
  await page.locator('.mobile-tools [data-action="toc"]').click();
  assert.equal(await page.locator('.toc-item').count(), metadata.toc.length);
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-contents-panel.png' });
  await command({ type: 'back' });
  assert.equal(await page.locator('[data-panel="toc"]').getAttribute('aria-hidden'), 'true');
  await page.locator('[data-action="menu"]').click();
  await command({ type: 'chrome', chrome: { controls: true, syncEnabled: false, status: 'Offline ready' } });
  assert.equal(await page.locator('[data-action="sync"]').isDisabled(), true);
  await command({ type: 'chrome', chrome: { controls: true, syncEnabled: true, status: 'Progress synced' } });
  await page.locator('[data-action="sync"]').click();
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'readerAction').at(-1).action), 'sync');
  assert.equal(await page.locator('[data-action="upload"],[data-action="reconcile"]').count(), 0);
  assert.equal(await page.locator('.header-bar [data-action="font"],.header-bar [data-action="color"],.mobile-tools [data-action="font"],.mobile-tools [data-action="color"]').count(), 0);
  await page.locator('[data-action="menu"]').click(); await page.locator('[data-action="share"]').click();
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'readerAction').at(-1).action), 'share');
  await command({ type: 'chrome', chrome: { controls: false, syncEnabled: true } });
  await page.waitForTimeout(350);
  assert.equal(await page.locator('.header-bar').evaluate(el => getComputedStyle(el).opacity), '0');
  assert.equal(await page.locator('.footer-bar').evaluate(el => el.inert), true);
  assert.deepEqual(await page.locator('foliate-view').boundingBox(), phoneBounds, 'Toggling bars never resizes the reading viewport');
  await page.screenshot({ path: 'output/playwright/reader-chrome-hidden.png' });
  await command({ type: 'chrome', chrome: { controls: true, syncEnabled: false } });
  await page.waitForTimeout(350);
  await page.screenshot({ path: 'output/playwright/reader-chrome-phone.png' });
  await command({ type: 'chrome', chrome: { controls: true, safeTop: 30, safeBottom: 24 } });
  assert.equal(await page.locator('.header-bar').evaluate(el => el.getBoundingClientRect().height), 74);
  assert.equal(await page.locator('.footer-bar').evaluate(el => getComputedStyle(el).paddingBottom), '24px');
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getAttribute('margin-top')), '42px');
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getAttribute('margin-bottom')), '36px');
  assert.deepEqual(await page.locator('foliate-view').boundingBox(), phoneBounds);
  await page.screenshot({ path: 'output/playwright/reader-edge-to-edge.png' });
  await command({ type: 'chrome', chrome: { controls: false, safeTop: 30, safeBottom: 24 } });
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getAttribute('margin-top')), '42px');
  await command({ type: 'chrome', chrome: { controls: true, safeTop: 0, safeBottom: 0 } });
  report.tests.push('Edge-to-edge viewport with status/gesture insets for controls and text, preserved when bars toggle');
  await command({ type: 'restore', cfi: firstCFI, requestId: 'chrome-finish' });
  report.tests.push('Readest bar transitions, expandable progress/font/theme/TOC panels, toolbar page turns, appearance events, native sync actions, and constant viewport when hidden');
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
  await command({ type: 'inspect', cfi: preview.position.cfi, requestId: 'cloud-preview' });
  const cloudPreview = await page.evaluate(() => window.events.find(e => e.requestId === 'cloud-preview'));
  assert.equal(cloudPreview.type, 'inspected'); assert.equal(cloudPreview.position.cfi, preview.position.cfi);
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), beforeInspect);
  report.tests.push('Readest CFI-only cloud positions resolve without moving the reader');
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
  await command({ type: 'appearance', settings: { fontSize: 24, lineHeight: 1.9, themeMode: 'dark', themeColor: 'default' } });
  await page.setViewportSize({ width: 780, height: 412 });
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-landscape.png' });
  assert.equal(await page.evaluate(() => document.body.style.background), 'rgb(34, 34, 34)');
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'position').at(-1).restored), true);
  report.tests.push('Appearance and landscape relayout');
  await command({ type: 'appearance', settings: { fontSize: 20, lineHeight: 1.7, themeMode: 'light', themeColor: 'default' } });
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
  await command({ type: 'chrome', chrome: { controls: true } });
  const panel = page.locator('[data-panel="font"]');
  await openMenuPanel('font');
  await page.waitForTimeout(200);
  const closeButton = panel.locator('[data-action="close"]');
  const closeBounds = await closeButton.boundingBox();
  await panel.locator('.panel-scroll').evaluate(el => { el.scrollTop = el.scrollHeight; });
  assert.deepEqual(await closeButton.boundingBox(), closeBounds, 'Close stays in the upper-right corner while settings scroll');
  assert.ok(await panel.locator('.panel-scroll').evaluate(el => el.scrollTop > 0));
  await page.keyboard.press('ArrowRight');
  await command({ type: 'next' });
  await page.mouse.move(1050, 250); await page.mouse.wheel(0, 600);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 1100, y: 250 }] });
  for (const x of [1050, 1000, 950]) await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: 250 }] });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForTimeout(350);
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), startCFI, 'Floating settings block keyboard, bridge, wheel and real touch page turns');
  if (await panel.getAttribute('aria-hidden') === 'false') await closeButton.click();
  for (const x of [100, 1050, 590]) {
    await openMenuPanel('font');
    await page.waitForTimeout(200);
    await page.mouse.click(x, x === 590 ? 60 : 250);
    assert.equal(await panel.getAttribute('aria-hidden'), 'true', 'An outside tap dismisses settings');
    assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), startCFI, 'Dismissal does not also turn the page');
  }
  await openMenuPanel('font');
  await page.waitForTimeout(200);
  await panel.locator('.panel-scroll').evaluate(el => { el.scrollTop = el.scrollHeight; });
  await page.screenshot({ path: 'output/playwright/reader-fixed-close-tablet.png' });
  await closeButton.click();
  await page.locator('[data-action="menu"]').click();
  await page.keyboard.press('ArrowRight');
  await page.mouse.click(100, 250);
  assert.equal(await page.locator('.view-menu').isVisible(), false);
  assert.equal(await page.locator('[data-action="menu"]').getAttribute('aria-expanded'), 'false');
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), startCFI);
  report.tests.push('Fixed panel close after scrolling, outside-tap dismissal without page turns, blocked touch/keyboard/wheel/bridge navigation, and floating-menu dismissal');
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
  const reduced = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 412, height: 780 } });
  const reducedPage = await reduced.newPage();
  await reducedPage.goto(`${origin}/reader/index.html`);
  await reducedPage.waitForFunction(() => window.readerTest);
  await reducedPage.evaluate(async url => {
    window.readerReceive({ version: 1, session: 'reduced', type: 'open', url });
    await window.readerTest.idle();
  }, `${origin}/books/alice.epub`);
  assert.equal(await reducedPage.evaluate(() => window.readerTest.getView().renderer.hasAttribute('animated')), false);
  assert.equal(await reducedPage.locator('.header-bar').evaluate(el => getComputedStyle(el).transitionDuration), '0s');
  await reduced.close();
  report.tests.push('Upstream page turns render intermediate frames; reduced motion disables page and toolbar animations');
  await command({ type: 'fonts', fonts: [{ family: 'Test Custom', style: 'normal', weight: '400', url: `${origin}/fonts/test.ttf` }] });
  await command({ type: 'appearance', settings: { fontSize: 20, minimumFontSize: 8, fontWeight: 400, overrideFont: false, useBookLayout: true } });
  await command({ type: 'open', url: `${origin}/books/styled.epub` });
  await command({ type: 'chrome', chrome: { controls: true, safeTop: 0, safeBottom: 0 } });
  const publisher = await page.evaluate(() => {
    const doc = window.readerTest.getView().renderer.getContents()[0].doc, p = doc.querySelector('#copy');
    const style = doc.defaultView.getComputedStyle(p); return { family: style.fontFamily, size: style.fontSize, margin: style.marginTop };
  });
  assert.equal(publisher.family, 'Georgia'); assert.equal(publisher.size, '12px'); assert.equal(publisher.margin, '3px');
  await openMenuPanel('font');
  await page.waitForTimeout(200);
  const phoneClose = page.locator('[data-panel="font"] [data-action="close"]');
  await page.locator('#reader-chrome').evaluate(async el => {
    await Promise.all(el.getAnimations({ subtree: true }).map(animation => animation.finished.catch(() => {})));
  });
  const phoneCloseBounds = await phoneClose.boundingBox();
  await page.locator('[data-panel="font"] .panel-scroll').evaluate(el => { el.scrollTop = el.scrollHeight; });
  assert.deepEqual(await phoneClose.boundingBox(), phoneCloseBounds, 'The phone close button also stays fixed after scrolling');
  await page.locator('[data-font-picker="serifFont"]').click();
  const fontPreview = page.locator('[data-font-setting="serifFont"][data-font-value="Test Custom"]');
  await fontPreview.scrollIntoViewIfNeeded();
  const previewFont = await fontPreview.evaluate(async el => {
    await document.fonts.ready;
    const family = getComputedStyle(el).fontFamily;
    const ctx = document.createElement('canvas').getContext('2d');
    ctx.font = `16px ${family}`; const actual = ctx.measureText(el.textContent).width;
    ctx.font = '16px Arial'; const expected = ctx.measureText(el.textContent).width;
    ctx.font = '16px monospace'; const fallback = ctx.measureText(el.textContent).width;
    return { family, actual, expected, fallback, loaded: Array.from(document.fonts).some(face => face.family.includes('Test Custom') && face.status === 'loaded') };
  });
  assert.ok(previewFont.family.includes('Test Custom')); assert.equal(previewFont.loaded, true);
  if (!process.env.READER_TEST_FONT && process.platform === 'win32') assert.equal(previewFont.actual, previewFont.expected);
  assert.notEqual(previewFont.actual, previewFont.fallback);
  assert.equal(await page.evaluate(() => window.readerTest.getSettings().serifFont), 'serif', 'Font previews load before selection');
  await page.screenshot({ path: 'output/playwright/reader-font-previews-phone.png' });
  await phoneClose.click();
  await openMenuPanel('font');
  assert.equal(await page.locator('#options-serifFont').isVisible(), false, 'Closing settings resets the expanded font list');
  await page.locator('[data-font-picker="serifFont"]').click();
  await page.keyboard.press('Home'); await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  assert.equal(await fontPreview.getAttribute('aria-selected'), 'true');
  report.tests.push('Real unselected font previews on phone, keyboard selection, a fixed close button, and dropdown reset when dismissed');
  await page.locator('[data-setting="overrideFont"]').check();
  await page.locator('[data-setting="fontSize"]').fill('26'); await page.locator('[data-setting="fontSize"]').dispatchEvent('change');
  await page.locator('[data-setting="minimumFontSize"]').fill('16'); await page.locator('[data-setting="minimumFontSize"]').dispatchEvent('change');
  await page.locator('[data-setting="fontWeight"]').fill('700'); await page.locator('[data-setting="fontWeight"]').dispatchEvent('change');
  await page.evaluate(() => window.readerTest.idle());
  await page.locator('[data-panel="font"] .panel-scroll').evaluate(element => { document.activeElement?.blur(); element.scrollTop = 0; });
  await page.screenshot({ path: 'output/playwright/reader-full-fonts-phone.png' });
  await page.locator('[data-font-tab="layout"]').click();
  assert.equal(await page.locator('#reader-line-height').isDisabled(), true);
  await page.locator('[data-setting="useBookLayout"]').uncheck(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('#reader-line-height').isDisabled(), false);
  const readingChanges = await page.evaluate(() => window.events.filter(e => e.type === 'position' && !e.restored).length);
  for (const [key, value] of Object.entries({ paragraphMargin: 1.5, wordSpacing: 1, letterSpacing: 0.5, textIndent: 2, marginLeftPx: 40,
    marginRightPx: 36, marginTopPx: 24, marginBottomPx: 28, columnGapPx: 48, maxColumnCount: 3, maxInlineSize: 500, maxBlockSize: 900 })) {
    const input = page.locator(`[data-setting="${key}"]`); await input.fill(String(value)); await input.dispatchEvent('change'); await page.evaluate(() => window.readerTest.idle());
  }
  await page.locator('[data-setting="fullJustification"]').check();
  await page.locator('[data-setting="hyphenation"]').uncheck(); await page.evaluate(() => window.readerTest.idle());
  await page.waitForTimeout(250);
  const typography = await page.evaluate(async () => {
    const renderer = window.readerTest.getView().renderer, doc = renderer.getContents()[0].doc;
    await doc.fonts.ready;
    const p = doc.defaultView.getComputedStyle(doc.querySelector('#copy')), tiny = doc.defaultView.getComputedStyle(doc.querySelector('#tiny'));
    return { family: p.fontFamily, size: p.fontSize, weight: p.fontWeight, margin: p.marginTop, word: p.wordSpacing, letter: p.letterSpacing,
      indent: p.textIndent, align: p.textAlign, hyphens: p.hyphens, tiny: tiny.fontSize,
      attributes: ['margin-left','margin-right','margin-top','margin-bottom','column-gap','max-column-count','max-inline-size','max-block-size'].map(key => renderer.getAttribute(key)),
      loaded: doc.fonts.check('26px "Test Custom"') };
  });
  assert.ok(typography.family.includes('Test Custom')); assert.equal(typography.loaded, true);
  assert.deepEqual([typography.size, typography.weight, typography.margin, typography.word, typography.letter, typography.indent, typography.align, typography.hyphens, typography.tiny],
    ['26px', '700', '39px', '1px', '0.5px', '52px', 'justify', 'none', '16px']);
  assert.deepEqual(typography.attributes, ['40px','36px','24px','28px','48px','3','500px','900px']);
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'position' && !e.restored).length), readingChanges, 'Relayout must not become a reading edit');
  await page.screenshot({ path: 'output/playwright/reader-full-layout-phone.png' });
  await page.locator('[data-setting="useBookLayout"]').check(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.evaluate(() => {
    const doc = window.readerTest.getView().renderer.getContents()[0].doc; return doc.defaultView.getComputedStyle(doc.querySelector('#copy')).marginTop;
  }), '3px');
  await page.locator('[data-setting="scrolled"]').check(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getAttribute('flow')), 'scrolled');
  assert.equal(await page.locator('[data-setting="maxColumnCount"]').isDisabled(), true);
  await page.setViewportSize({ width: 1180, height: 780 }); await page.screenshot({ path: 'output/playwright/reader-full-layout-tablet.png' });
  await command({ type: 'appearance', settings: { overrideFont: false, minimumFontSize: 8 } });
  assert.equal(await page.evaluate(() => {
    const doc = window.readerTest.getView().renderer.getContents()[0].doc; return doc.defaultView.getComputedStyle(doc.querySelector('#copy')).fontFamily;
  }), 'Georgia');
  report.tests.push('Full font and layout controls: real custom font rendering, publisher overrides, minimum size, weight, spacing, margins, columns, scroll flow, preserved publisher layout and no synthetic reading edits');
  const reopenSettings = await page.evaluate(() => ({ ...window.readerTest.getSettings(), themeMode: 'dark', themeColor: 'nord', serifFont: 'Test Custom', overrideFont: true }));
  await command({ type: 'close' });
  assert.equal(await page.evaluate(() => !!window.readerTest.getView()), false);
  await command({ session: 'reopened', type: 'open', url: `${origin}/books/styled.epub`, settings: reopenSettings });
  await assertBarsHidden(page, true);
  const reopened = await page.evaluate(async () => {
    await document.fonts.ready;
    const doc = window.readerTest.getView().renderer.getContents()[0].doc;
    await doc.fonts.ready;
    return { settings: window.readerTest.getSettings(), family: doc.defaultView.getComputedStyle(doc.querySelector('#copy')).fontFamily,
      chrome: getComputedStyle(document.querySelector('#reader-chrome')).fontFamily, loaded: document.fonts.check('14px "Test Custom"'),
      option: document.querySelector('[data-font-setting="serifFont"][data-font-value="Test Custom"]').style.fontFamily };
  });
  assert.equal(reopened.settings.themeMode, 'dark'); assert.equal(reopened.settings.themeColor, 'nord');
  assert.ok(reopened.family.includes('Test Custom')); assert.ok(reopened.chrome.includes('Test Custom'));
  assert.equal(reopened.loaded, true); assert.ok(reopened.option.includes('Test Custom'));
  await command({ session: 'reopened', type: 'fonts', fonts: ['Readest Serif', 'Readest Sans', 'Readest Mono'].map(family => ({ family, style: 'normal', weight: '400', url: `${origin}/fonts/test.ttf` })) });
  await command({ session: 'reopened', type: 'appearance', settings: { defaultFont: 'serif', serifFont: 'serif', sansSerifFont: 'sans-serif', monospaceFont: 'monospace', defaultCJKFont: '', overrideFont: true } });
  async function renderedBuiltin() {
    return page.evaluate(async () => {
      const doc = window.readerTest.getView().renderer.getContents()[0].doc;
      await doc.fonts.ready;
      return { family: doc.defaultView.getComputedStyle(doc.querySelector('#copy')).fontFamily,
        faces: Array.from(doc.fonts).map(face => ({ family: face.family, status: face.status })) };
    });
  }
  const serif = await renderedBuiltin();
  assert.ok(serif.family.includes('Readest Serif'));
  assert.ok(serif.faces.some(face => face.family.includes('Readest Serif') && face.status === 'loaded'));
  await command({ session: 'reopened', type: 'appearance', settings: { defaultFont: 'sans-serif' } });
  const sans = await renderedBuiltin();
  assert.ok(sans.family.includes('Readest Sans'));
  assert.ok(sans.faces.some(face => face.family.includes('Readest Sans') && face.status === 'loaded'));
  assert.equal(await page.locator('[data-font-setting="serifFont"][data-font-value="Readest Serif"]').count(), 0);
  report.tests.push('Generic serif and sans-serif selections load explicit native font files and change the rendered chapter family');
  await command({ session: 'reopened', type: 'close' });
  await command({ session: 'cached', type: 'open', url: `${origin}/books/continuous.epub` });
  await page.evaluate(() => {
    window.chapterParses = 0;
    for (const section of window.readerTest.getBook().sections) {
      const create = section.createDocument.bind(section);
      section.createDocument = (...args) => { window.chapterParses++; return create(...args); };
    }
  });
  for (const type of ['next', 'previous', 'next']) await command({ session: 'cached', type });
  assert.equal(await page.evaluate(() => window.chapterParses), 0, 'Page turns reuse the canonical chapter document');
  assert.ok(await page.evaluate(() => window.events.filter(e => e.session === 'cached' && e.type === 'position').at(-1).position.xpointer));
  await page.setViewportSize({ width: 412, height: 780 });
  await page.waitForTimeout(200);
  await command({ session: 'cached', type: 'chrome', chrome: { controls: true } });
  const annotationStart = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  await page.locator('.mobile-tools [data-action="bookmark"]').click(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('.mobile-tools [data-action="bookmark"]').getAttribute('aria-pressed'), 'true');
  await page.locator('.mobile-tools [data-action="bookmark"]').click(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('.mobile-tools [data-action="bookmark"]').getAttribute('aria-pressed'), 'false');
  await page.locator('.mobile-tools [data-action="bookmark"]').click(); await page.evaluate(() => window.readerTest.idle());
  await command({ session: 'cached', type: 'previous' });
  assert.equal(await page.locator('.mobile-tools [data-action="bookmark"]').getAttribute('aria-pressed'), 'false');
  await page.locator('.mobile-tools [data-action="highlights"]').click();
  await page.locator('[data-annotation-tab="bookmark"]').click();
  assert.equal(await page.locator('[data-annotation-tab="bookmark"]').getAttribute('aria-selected'), 'true');
  assert.equal(await page.locator('[data-annotation]').count(), 1);
  await page.locator('[data-annotation]').click(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('.mobile-tools [data-action="bookmark"]').getAttribute('aria-pressed'), 'true');
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), annotationStart);
  const selectPassage = async () => page.evaluate(() => {
    const { doc } = window.readerTest.getView().renderer.getContents()[0];
    const frame = doc.defaultView.frameElement.getBoundingClientRect();
    const word = [...doc.querySelectorAll('[data-word]')].find(element => {
      const bounds = element.getBoundingClientRect();
      return bounds.left + frame.left >= 0 && bounds.right + frame.left <= innerWidth && bounds.top + frame.top > 80 && bounds.bottom + frame.top < innerHeight - 80;
    });
    if (!word) throw Error('No visible annotation text');
    const range = doc.createRange(); range.selectNodeContents(word);
    const selection = doc.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    doc.dispatchEvent(new Event('selectionchange'));
  });
  await selectPassage();
  assert.equal(await page.locator('.selection-bar').isVisible(), true);
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-highlight-selection.png' });
  await page.locator('[data-highlight-color="#fff176"]').click(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('.selection-bar').isVisible(), false);
  assert.ok(await page.evaluate(() => window.readerTest.getView().renderer.getContents().some(item => item.overlayer.element.querySelector('g[fill="#fff176"]'))));
  await selectPassage(); await page.locator('[data-highlight-color="#90caf9"]').click(); await page.evaluate(() => window.readerTest.idle());
  const savedAnnotations = await page.evaluate(() => window.events.filter(e => e.session === 'cached' && e.type === 'annotationsChanged').at(-1).annotations);
  assert.equal(savedAnnotations.length, 2); assert.equal(savedAnnotations.find(item => item.kind === 'highlight').color, '#90caf9');
  assert.match(savedAnnotations.find(item => item.kind === 'highlight').text, /^word\d+/);
  const highlightedTap = await page.evaluate(() => {
    const { doc } = window.readerTest.getView().renderer.getContents()[0];
    const frame = doc.defaultView.frameElement.getBoundingClientRect();
    const word = [...doc.querySelectorAll('[data-word]')].find(element => {
      const bounds = element.getBoundingClientRect();
      const x = (bounds.left + bounds.right) / 2 + frame.left;
      return x > innerWidth / 3 && x < innerWidth * 2 / 3 && bounds.top + frame.top > 100 && bounds.bottom + frame.top < innerHeight - 100;
    });
    const range = doc.createRange(); range.selectNodeContents(word);
    const selection = doc.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    doc.dispatchEvent(new Event('selectionchange'));
    const bounds = word.getBoundingClientRect();
    return { x: (bounds.left + bounds.right) / 2 + frame.left, y: (bounds.top + bounds.bottom) / 2 + frame.top };
  });
  await page.locator('[data-highlight-color="#fff176"]').click(); await page.evaluate(() => window.readerTest.idle());
  const highlightedCFI = await page.evaluate(() => window.readerTest.getView().lastLocation.cfi);
  for (const hidden of [true, false, true, false]) {
    const toggles = await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length);
    await page.mouse.click(highlightedTap.x, highlightedTap.y);
    await assertBarsHidden(page, hidden);
    assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length), toggles + 1);
    assert.equal(await page.locator('.selection-bar').isVisible(), false);
    assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), highlightedCFI);
  }
  const highlightTouch = await page.context().newCDPSession(page);
  for (const hidden of [true, false, true, false]) {
    const toggles = await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length);
    await highlightTouch.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: highlightedTap.x, y: highlightedTap.y }] });
    await highlightTouch.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await page.waitForTimeout(350);
    await assertBarsHidden(page, hidden);
    assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length), toggles + 1);
    assert.equal(await page.locator('.selection-bar').isVisible(), false);
    assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), highlightedCFI);
  }
  await selectPassage();
  assert.equal(await page.locator('.selection-bar').isVisible(), true);
  const beforeDismiss = await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length);
  await page.mouse.click(highlightedTap.x, highlightedTap.y);
  assert.equal(await page.locator('.selection-bar').isVisible(), false);
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length), beforeDismiss, 'Dismissing a highlight selection must not also toggle reader bars');
  await assertBarsHidden(page, false);
  await page.mouse.click(highlightedTap.x, highlightedTap.y);
  await assertBarsHidden(page, true);
  await selectPassage();
  const beforeTouchDismiss = await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length);
  await highlightTouch.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: highlightedTap.x, y: highlightedTap.y }] });
  await highlightTouch.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForTimeout(350);
  await assertBarsHidden(page, true);
  assert.equal(await page.locator('.selection-bar').isVisible(), false);
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'toggleControls').length), beforeTouchDismiss);
  assert.equal(await page.evaluate(() => window.readerTest.getView().lastLocation.cfi), highlightedCFI);
  await highlightTouch.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: highlightedTap.x, y: highlightedTap.y }] });
  await highlightTouch.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForTimeout(350);
  await assertBarsHidden(page, false);
  await highlightTouch.detach();
  report.tests.push('Mouse and touch taps on saved highlights toggle bars once without moving the page; selection-dismissal taps close the picker without toggling bars, and the next tap toggles normally');
  const extra = await page.evaluate(() => window.events.filter(e => e.session === 'cached' && e.type === 'annotationsChanged').at(-1).annotations);
  await command({ session: 'cached', type: 'removeAnnotation', id: extra.find(item => item.kind === 'highlight' && item.color === '#fff176').id });
  const highlightsBeforeStale = savedAnnotations.length;
  await command({ session: 'other-book', type: 'bookmark' });
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'annotationsChanged').at(-1).annotations.length), highlightsBeforeStale);
  await command({ session: 'cached', type: 'open', url: `${origin}/books/continuous.epub`, cfi: annotationStart, annotations: savedAnnotations });
  await assertBarsHidden(page, true);
  await command({ session: 'cached', type: 'chrome', chrome: { controls: true } });
  assert.equal(await page.locator('.mobile-tools [data-action="bookmark"]').getAttribute('aria-pressed'), 'true');
  await page.waitForFunction(() => window.readerTest.getView().renderer.getContents().some(item => item.overlayer.element.querySelector('g[fill="#90caf9"]')));
  await page.locator('.mobile-tools [data-action="highlights"]').click(); await page.locator('[data-annotation-tab="highlight"]').click();
  assert.equal(await page.locator('[data-annotation-tab="highlight"]').getAttribute('aria-selected'), 'true');
  assert.equal(await page.locator('[data-annotation]').count(), 1);
  await page.waitForTimeout(200);
  const annotationTools = await page.locator('.mobile-tools').evaluate(element => {
    const bounds = element.getBoundingClientRect();
    const button = element.querySelector('button'), buttonBounds = button.getBoundingClientRect();
    const target = document.elementFromPoint(buttonBounds.left + buttonBounds.width / 2, buttonBounds.top + buttonBounds.height / 2);
    return { top: bounds.top, bottom: bounds.bottom, height: bounds.height, viewport: innerHeight,
      accessible: !!target?.closest('.mobile-tools'), target: target?.outerHTML.slice(0, 250) };
  });
  assert.ok(annotationTools.height > 0 && annotationTools.bottom <= annotationTools.viewport, `Annotation controls stay on screen: ${JSON.stringify(annotationTools)}`);
  assert.equal(annotationTools.accessible, true, `Annotation panel cannot cover toolbar buttons: ${JSON.stringify(annotationTools)}`);
  await page.screenshot({ path: 'output/playwright/reader-highlights-phone.png' });
  await page.locator('[data-remove-annotation]').click(); await page.evaluate(() => window.readerTest.idle());
  assert.equal(await page.locator('[data-annotation]').count(), 0);
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getContents().some(item => item.overlayer.element.querySelector('g[fill="#90caf9"]'))), false);
  await command({ session: 'cached', type: 'back' });
  await page.locator('[data-action="menu"]').click();
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-menu-phone.png' });
  await page.setViewportSize({ width: 1180, height: 780 });
  await page.waitForTimeout(200);
  await page.screenshot({ path: 'output/playwright/reader-menu-tablet.png' });
  assert.equal(await page.locator('.header-bar [data-action="bookmark"]').isVisible(), true);
  await page.locator('[data-action="share"]').click();
  assert.equal(await page.evaluate(() => window.events.filter(e => e.type === 'readerAction').at(-1).action), 'share');
  report.tests.push('Bookmarks toggle and navigate; highlights capture selected text, recolor, render, survive reopening, delete, and reject stale sessions; phone/tablet menus contain Theme, Font & Layout, Share and one Sync action');
  const beforeCloudAnnotations = await page.evaluate(() => ({ cfi: window.readerTest.getView().lastLocation.cfi,
    edits: window.events.filter(e => e.type === 'annotationsChanged').length }));
  await command({ session: 'cached', type: 'annotations', annotations: savedAnnotations });
  await page.waitForFunction(() => window.readerTest.getView().renderer.getContents().some(item => item.overlayer.element.querySelector('g[fill="#90caf9"]')));
  assert.equal(await page.locator('.header-bar [data-action="bookmark"]').getAttribute('aria-pressed'), 'true');
  await command({ session: 'stale', type: 'annotations', annotations: [] });
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getContents().some(item => item.overlayer.element.querySelector('g[fill="#90caf9"]'))), true);
  await command({ session: 'cached', type: 'annotations', annotations: [] });
  assert.equal(await page.evaluate(() => window.readerTest.getView().renderer.getContents().some(item => item.overlayer.element.querySelector('g[fill="#90caf9"]'))), false);
  assert.equal(await page.locator('.header-bar [data-action="bookmark"]').getAttribute('aria-pressed'), 'false');
  assert.deepEqual(await page.evaluate(() => ({ cfi: window.readerTest.getView().lastLocation.cfi,
    edits: window.events.filter(e => e.type === 'annotationsChanged').length })), beforeCloudAnnotations);
  report.tests.push('Remote annotation updates refresh highlights/bookmarks without changing the reading position or echoing local edits; stale sessions cannot delete them');
  await command({ session: 'cached', type: 'close' });
  report.tests.push('Reopen applies native settings with a new session; custom fonts render in chrome and font items; page turns reuse canonical chapter documents and close releases the renderer');
  const startup = await browser.newPage({ viewport: { width: 1180, height: 780 } });
  startup.on('pageerror', error => report.consoleErrors.push(error.message));
  await startup.addInitScript(() => {
    if (window !== window.top) return;
    window.events = []; window.HarmonyReader = { post: value => window.events.push(JSON.parse(value)) };
    const ready = Object.getOwnPropertyDescriptor(FontFaceSet.prototype, 'ready').get;
    const gate = new Promise(resolve => { window.releaseStartupFonts = resolve; });
    Object.defineProperty(document.fonts, 'ready', { configurable: true, get() {
      window.startupFontsPending = true;
      return Promise.all([ready.call(this), gate]);
    } });
  });
  await startup.goto(`${origin}/reader/index.html`);
  await startup.waitForFunction(() => window.readerTest && window.events.some(e => e.type === 'ready'));
  await startup.evaluate(origin => {
    window.readerReceive({ version: 1, session: 'startup', type: 'fonts',
      fonts: [{ family: 'Startup Font', style: 'normal', weight: '400', url: `${origin}/fonts/test.ttf` }] });
    window.readerReceive({ version: 1, session: 'startup', type: 'open', url: `${origin}/books/styled.epub`,
      settings: { serifFont: 'Startup Font', overrideFont: true } });
  }, origin);
  await startup.waitForFunction(() => window.startupFontsPending);
  assert.equal(await startup.locator('foliate-view').evaluate(el => getComputedStyle(el).opacity), '0');
  assert.equal(await startup.locator('#reader-chrome').isVisible(), false);
  assert.equal(await startup.evaluate(() => window.events.some(e => e.type === 'opened')), false);
  await startup.evaluate(async () => { window.releaseStartupFonts(); await window.readerTest.idle(); });
  const firstVisible = await startup.evaluate(() => {
    const view = window.readerTest.getView(), doc = view.renderer.getContents()[0].doc;
    return { opacity: getComputedStyle(view).opacity, inert: view.inert,
      chapter: doc.fonts.check('20px "Startup Font"'), chrome: document.fonts.check('14px "Startup Font"'),
      family: doc.defaultView.getComputedStyle(doc.querySelector('#copy')).fontFamily };
  });
  assert.deepEqual(firstVisible, { opacity: '1', inert: false, chapter: true, chrome: true, family: '"Startup Font", serif' });
  await assertBarsHidden(startup, true);
  await startup.mouse.click(590, 250);
  await assertBarsHidden(startup, false);
  await startup.close();
  report.tests.push('Cold reader open with delayed font readiness keeps text and controls hidden until configured chapter/chrome fonts load, then reveals text while bars stay hidden until a center tap');
  assert.deepEqual(report.consoleErrors, []);
  await mkdir('output/playwright', { recursive: true });
  await writeFile('output/playwright/browser-results.json', JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
