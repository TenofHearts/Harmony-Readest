import assert from 'node:assert/strict';
import { BlobReader, BlobWriter, TextReader, ZipWriter } from '@zip.js/zip.js';
import sharp from 'sharp';

const color = { r: 25, g: 100, b: 180 };
export async function makeCoverEPUBs() {
  const png = await sharp({ create: { width: 240, height: 360, channels: 3, background: color } }).png().toBuffer();
  const books = new Map();
  for (const format of ['href', 'xlink', 'both', 'img']) {
    const src = '../Images/cover%20art.png';
    const image = format === 'img' ? `<img src="${src}" alt="Cover"/>` :
      `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="240" height="360" viewBox="0 0 240 360"><image width="240" height="360" ${format !== 'xlink' ? `href="${src}"` : ''} ${format !== 'href' ? `xlink:href="${src}"` : ''}/></svg>`;
    const writer = new ZipWriter(new BlobWriter('application/epub+zip'));
    const files = {
      mimetype: 'application/epub+zip',
      'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      'OPS/book.opf': '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">cover</dc:identifier><dc:title>Reader cover</dc:title><dc:language>en</dc:language></metadata><manifest><item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/><item id="art" href="Images/cover%20art.png" media-type="image/png" properties="cover-image"/><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="cover"/><itemref idref="chapter"/></spine></package>',
      'OPS/Text/cover.xhtml': `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head><body>${image}</body></html>`,
      'OPS/Text/chapter.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head><body><p>After the cover.</p></body></html>'
    };
    for (const [name, text] of Object.entries(files)) await writer.add(name, new TextReader(text));
    await writer.add('OPS/Images/cover art.png', new BlobReader(new Blob([png])));
    books.set(`/books/cover-${format}.epub`, Buffer.from(await (await writer.close()).arrayBuffer()));
  }
  return books;
}

export async function checkCovers({ page, command, origin, report }) {
  await page.setViewportSize({ width: 412, height: 780 });
  for (const format of ['href', 'xlink', 'both', 'img']) {
    await command({ type: 'open', url: `${origin}/books/cover-${format}.epub`, settings: { themeMode: 'light' } });
    const rendered = await page.evaluate(async () => {
      const doc = window.readerTest.getView().renderer.getContents()[0].doc;
      const element = doc.querySelector('image, img');
      const urls = ['src', 'href'].map(attr => element.getAttribute(attr)).filter(Boolean);
      const xlink = element.getAttributeNS('http://www.w3.org/1999/xlink', 'href');
      if (xlink) urls.push(xlink);
      const sizes = await Promise.all(urls.map(async url => {
        const image = new Image(); image.src = url; await image.decode();
        return [image.naturalWidth, image.naturalHeight];
      }));
      return { urls, sizes, cfi: window.readerTest.getView().lastLocation.cfi,
        sandbox: doc.defaultView.frameElement.getAttribute('sandbox') };
    });
    assert.ok(rendered.urls.every(url => url.startsWith('blob:')), `Reader ${format} cover must resolve archive URLs: ${JSON.stringify(rendered)}`);
    for (const size of rendered.sizes) assert.deepEqual(size, [240, 360]);
    assert.equal(rendered.sandbox, 'allow-same-origin');
    const assertPainted = async suffix => {
      const screenshot = await page.screenshot({ path: `output/playwright/reader-cover-${format}${suffix}.png` });
      const { data, info } = await sharp(screenshot).removeAlpha().raw().toBuffer({ resolveWithObject: true });
      let painted = 0;
      for (let i = 0; i < data.length; i += info.channels) {
        if (data[i] === color.r && data[i + 1] === color.g && data[i + 2] === color.b) painted++;
      }
      assert.ok(painted > 10000, `Reader ${format} cover must paint its image, got ${painted} pixels`);
    };
    await assertPainted('');
    await command({ type: 'navigate', href: 'OPS/Text/chapter.xhtml' });
    await command({ type: 'restore', cfi: rendered.cfi, requestId: `cover-${format}` });
    await assertPainted('-returned');
  }
  report.tests.push('Reader cover images paint with SVG href, xlink:href, both attributes and ordinary img, including encoded paths and returning from a chapter; script-disabled sandbox stays intact');
}
