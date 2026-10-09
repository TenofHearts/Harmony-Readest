import assert from 'node:assert/strict';

const xhtml = body => `<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>References</title><style>html{font-family:Georgia}a{color:#0066cc}</style></head><body>${body}</body></html>`;
export const referenceFiles = {
  'book.opf': '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">references</dc:identifier><dc:title>Reference previews</dc:title><dc:language>en</dc:language></metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="n" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/><itemref idref="n"/></spine></package>',
  'chapter.xhtml': xhtml(`<h1>Reference previews</h1>
    <p>Read a note without losing your place.<sup><a id="semantic" epub:type="noteref" href="notes.xhtml#short">1</a></sup></p>
    <p>Bibliography <a id="bibliography" role="doc-biblioref" href="notes.xhtml#bibliography">[2]</a></p>
    <p>Definition <a id="glossary" epub:type="glossref" href="notes.xhtml#term">term</a></p>
    <p>Inline <a id="inline" role="doc-noteref" href="#hidden">3</a></p>
    <p>Long note <a id="long" class="footnote-ref" href="notes.xhtml#long">4</a></p>
    <p>Superscript <sup><a id="superscript" href="notes.xhtml#short">5</a></sup></p>
    <p>Plain numeric note <a id="numeric" href="notes.xhtml#short">[6]</a></p>
    <p>Missing <a id="missing" epub:type="noteref" href="notes.xhtml#missing">7</a></p>
    <p><a id="ordinary" href="notes.xhtml">Open notes chapter</a></p>
    <p style="position:fixed;bottom:24px;right:24px"><a id="bottom" epub:type="noteref" href="notes.xhtml#short">Bottom reference</a></p>
    <aside id="hidden" epub:type="footnote" style="display:none">Hidden inline note is readable here.</aside>`),
  'notes.xhtml': xhtml(`<ol><li id="short" role="doc-endnote"><strong>A short reference.</strong> This note lives in another chapter.
    <a id="nested" epub:type="noteref" href="#second">Another reference</a> <a role="doc-backlink" href="chapter.xhtml#semantic">Return</a></li>
    <li id="second">A nested reference with its own content.</li>
    <li id="bibliography" role="doc-biblioentry">Example Author. <em>A reference book.</em> 2026.</li>
    <li id="long">${Array.from({ length: 70 }, (_, i) => `<p>Long reference paragraph ${i}. Notes remain scrollable without moving the main book.</p>`).join('')}</li></ol>
    <dl><dt id="term">Reference</dt><dd>A note linked from the text.</dd></dl>`)
};

export async function checkReferences({ page, command, origin, report }) {
  await page.setViewportSize({ width: 412, height: 780 });
  await command({ type: 'open', url: `${origin}/books/references.epub`, settings: { fontSize: 18, themeMode: 'light' } });
  const popup = page.locator('#reference-popup');
  const referenceState = () => page.evaluate(() => {
    const view = document.querySelector('#reference-popup foliate-view');
    const doc = view?.renderer?.getContents()[0]?.doc;
    return { text: doc?.body.textContent, cfi: window.readerTest.getView().lastLocation.cfi,
      positionEvents: window.events.filter(e => e.type === 'position').length,
      family: doc && doc.defaultView.getComputedStyle(doc.body).fontFamily,
      fontSize: doc && doc.defaultView.getComputedStyle(doc.body).fontSize,
      sandbox: doc?.defaultView.frameElement.getAttribute('sandbox') };
  });
  const initial = await referenceState();
  const marker = id => page.evaluate(id => {
    const doc = window.readerTest.getView().renderer.getContents()[0].doc;
    const a = doc.getElementById(id), rect = a.getBoundingClientRect(), frame = doc.defaultView.frameElement.getBoundingClientRect();
    return { x: rect.left + frame.left + rect.width / 2, y: rect.top + frame.top + rect.height / 2, bottom: rect.bottom + frame.top };
  }, id);
  const clickMarker = async id => {
    const point = await marker(id); await page.mouse.click(point.x, point.y);
    try { await popup.waitFor({ state: 'visible', timeout: 5000 }); }
    catch (error) {
      console.log('Reference failed', id, point, await page.locator('#reference-layer').evaluate(el => el.outerHTML), await referenceState()); throw error;
    }
    await page.waitForFunction(() => document.querySelector('#reference-popup').style.visibility === 'visible');
    await page.waitForTimeout(100); // Foliate's container finishes its 50ms reveal transition.
    return point;
  };
  const link = await clickMarker('semantic');
  const state = await referenceState();
  assert.match(state.text, /A short reference/); assert.doesNotMatch(state.text, /A nested reference with its own content/);
  assert.equal(state.cfi, initial.cfi); assert.equal(state.positionEvents, initial.positionEvents);
  assert.equal(state.fontSize, '18px'); assert.match(state.family, /Georgia/); assert.equal(state.sandbox, 'allow-same-origin');
  assert.equal(await popup.evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(224, 224, 224)');
  const bounds = await popup.boundingBox();
  assert.ok(bounds.y > link.bottom && bounds.x >= 10 && bounds.x + bounds.width <= 402);
  await page.screenshot({ path: 'output/playwright/reader-reference-phone.png' });
  await page.keyboard.press('ArrowRight'); await command({ type: 'next' });
  assert.equal((await referenceState()).cfi, initial.cfi);
  // A link inside a reference stays inside the popup, with local back history.
  const popupFrame = await page.locator('#reference-popup iframe').elementHandle().then(handle => handle.contentFrame());
  await popupFrame.locator('#nested').click();
  await page.waitForFunction(() => document.querySelector('#reference-popup foliate-view')?.renderer?.getContents()[0]?.doc.body.textContent.includes('A nested reference with its own content'));
  await page.locator('[data-reference-back]').click();
  await page.waitForFunction(() => document.querySelector('#reference-popup foliate-view')?.renderer?.getContents()[0]?.doc.body.textContent.includes('A short reference'));
  assert.equal((await referenceState()).cfi, initial.cfi);
  await page.mouse.click(10, 700); await page.locator('#reference-layer').waitFor({ state: 'hidden' });
  assert.equal((await referenceState()).cfi, initial.cfi);
  for (const [id, expected] of [['bibliography', 'Example Author'], ['glossary', 'A note linked from the text'], ['inline', 'Hidden inline note'], ['superscript', 'A short reference'], ['numeric', 'A short reference']]) {
    await clickMarker(id); assert.ok((await referenceState()).text.includes(expected), id);
    assert.equal((await referenceState()).cfi, initial.cfi, id);
    if (id === 'inline') assert.equal(await page.locator('[data-reference-jump]').isVisible(), false);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#reference-layer').isVisible(), false);
  }
  report.tests.push('Reference popup handles EPUB/ARIA footnotes, bibliography, glossary, hidden inline notes, superscripts and numeric markers; retains CFI/progress, book fonts, sandbox and local link history');
  await clickMarker('long');
  const longFrame = await page.locator('#reference-popup iframe').elementHandle().then(handle => handle.contentFrame());
  const scrolling = await longFrame.evaluate(() => ({ text: document.body.textContent, height: document.documentElement.scrollHeight, width: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth }));
  assert.match(scrolling.text, /Long reference paragraph 69/);
  assert.ok(scrolling.height > (await popup.boundingBox()).height);
  assert.ok(scrolling.width <= scrolling.clientWidth + 1);
  const beforeScroll = (await referenceState()).cfi;
  await page.mouse.move(200, (await popup.boundingBox()).y + 80); await page.mouse.wheel(0, 800);
  await page.waitForFunction(() => document.querySelector('#reference-popup foliate-view').renderer.start > 0);
  assert.equal((await referenceState()).cfi, beforeScroll);
  await command({ type: 'back' }); assert.equal(await popup.isVisible(), false);
  await clickMarker('missing');
  assert.match(await popup.textContent(), /Unable to load this reference/);
  assert.equal((await referenceState()).cfi, initial.cfi);
  await page.locator('[data-reference-close]').click();
  const bottomLink = await clickMarker('bottom');
  const bottomBox = await popup.boundingBox();
  assert.ok(bottomBox.y + bottomBox.height < bottomLink.y);
  assert.equal(await popup.getAttribute('data-above'), '');
  await command({ type: 'back' });
  const fastLink = await marker('semantic'); await page.mouse.click(fastLink.x, fastLink.y); await command({ type: 'back' });
  await page.waitForTimeout(100);
  assert.equal(await popup.isVisible(), false); assert.equal(await page.locator('#reference-popup foliate-view').count(), 0);
  report.tests.push('Long references scroll in one axis; outside taps, Escape, native Back and close dismiss without page turns; unresolved references remain in place');
  await command({ type: 'appearance', settings: { scrolled: true, overrideFont: true, serifFont: 'sans-serif', themeMode: 'dark', themeColor: 'nord' } });
  await clickMarker('semantic');
  assert.equal((await referenceState()).family, await page.evaluate(() => {
    const doc = window.readerTest.getView().renderer.getContents().find(c => c.doc.getElementById('semantic')).doc;
    return doc.defaultView.getComputedStyle(doc.body).fontFamily;
  }));
  assert.equal(await popup.evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(46, 52, 64)');
  assert.equal(await page.locator('#reference-popup iframe').elementHandle().then(async handle => (await handle.contentFrame()).evaluate(() => getComputedStyle(document.body).color)), 'rgb(216, 222, 233)');
  await page.screenshot({ path: 'output/playwright/reader-reference-dark.png' });
  await page.setViewportSize({ width: 1180, height: 780 }); await popup.waitFor({ state: 'hidden' });
  await command({ type: 'navigate', href: 'chapter.xhtml#semantic' });
  await clickMarker('semantic'); await page.screenshot({ path: 'output/playwright/reader-reference-tablet.png' });
  await page.locator('[data-reference-jump]').click(); await page.evaluate(() => window.readerTest.idle());
  await page.waitForFunction(() => { const view = window.readerTest.getView(); return view.resolveCFI(view.lastLocation.cfi).index === 1; });
  await command({ type: 'navigate', href: 'chapter.xhtml#ordinary' });
  const ordinary = await marker('ordinary'); await page.mouse.click(ordinary.x, ordinary.y);
  await page.waitForFunction(() => { const view = window.readerTest.getView(); return view.resolveCFI(view.lastLocation.cfi).index === 1; });
  assert.equal(await popup.isVisible(), false);
  await command({ type: 'navigate', href: 'chapter.xhtml#semantic' });
  await clickMarker('semantic'); await command({ type: 'close' });
  assert.equal(await popup.isVisible(), false); assert.equal(await page.locator('#reference-popup foliate-view').count(), 0);
  report.tests.push('Reference themes/font overrides update in scrolled mode and on tablets; resize and book close clean up; explicit jump and ordinary chapter links still navigate');
}
