import { EPUB } from '../../vendor/foliate-js/epub.js';
import '../../vendor/foliate-js/view.js';
// The JS codec is bundled locally; it does not fetch/compile an inline WASM
// module or rely on ArkWeb's optional native compression APIs.
import { BlobReader, BlobWriter, TextWriter, ZipReader, configure } from '@zip.js/zip.js/index-native.js';
import { partialMD5 } from '../../vendor/readest/apps/readest-app/src/utils/md5';
import { getCFIFromXPointer, getXPointerFromCFI, XCFI } from '../../vendor/readest/apps/readest-app/src/utils/xcfi';
declare const __READER_TEST__: boolean;

// Only this trusted top-level page can send native events. EPUB frames are script-disabled.
const emit = (type: string, data: object = {}) => {
  const message = JSON.stringify({ version: 1, session, type, ...data });
  if ((window as any).HarmonyReader) (window as any).HarmonyReader.post(message);
  else window.dispatchEvent(new CustomEvent('reader-event', { detail: JSON.parse(message) }));
};
let session = '';
let view: any;
let book: any;
let archive: ZipReader<any> | undefined;
let suppress = 0;
let lastPosition: any;
let eventQueue = Promise.resolve();
let userActionUntil = 0;
let lastTapTurnAt = 0;
let settings = { fontSize: 20, lineHeight: 1.7, theme: 'light' };
const themes = { light: ['#faf8f2', '#252b29'], dark: ['#192321', '#e3e8df'], sepia: ['#f1e5cf', '#433a2e'] };
const unsafeURL = (value: string) => /^(?:https?:|ftp:|javascript:|\/\/)/i.test(value.trim());
const offlineCSS = (value: string) => value
  .replace(/url\(\s*(['"]?)(?:https?:|ftp:|\/\/)[^)]*\)/gi, 'none')
  .replace(/@import\s+(?:url\([^)]*\)|['"][^'"]*['"])[^;]*;?/gi, '');

export async function loadEPUB(file: File) {
  configure({ useWebWorkers: false, useCompressionStream: false });
  const zip = new ZipReader(new BlobReader(file));
  try {
    const entries = await zip.getEntries();
    if (entries.some(e => e.encrypted)) throw Error('DRM_OR_ENCRYPTED');
    if (entries.reduce((sum, e) => sum + e.uncompressedSize, 0) > 512 * 1024 * 1024) throw Error('BOOK_TOO_LARGE');
    const map = new Map(entries.map(e => [e.filename, e]));
    if (!map.has('META-INF/container.xml')) throw Error('INVALID_EPUB');
    const loader = {
      entries,
      loadText: (name: string) => map.get(name)?.getData(new TextWriter()) ?? null,
      loadBlob: (name: string, type?: string) => map.get(name)?.getData(new BlobWriter(type)) ?? null,
      getSize: (name: string) => map.get(name)?.uncompressedSize ?? 0
    };
    const encryption = await loader.loadText('META-INF/encryption.xml');
    if (encryption) {
      const document = new DOMParser().parseFromString(encryption, 'application/xml');
      if (document.querySelector('parsererror')) throw Error('INVALID_EPUB');
      for (const method of document.getElementsByTagNameNS('*', 'EncryptionMethod')) {
        if (!['http://www.idpf.org/2008/embedding', 'http://ns.adobe.com/pdf/enc#RC'].includes(method.getAttribute('Algorithm') || '')) {
          throw Error('DRM_OR_ENCRYPTED');
        }
      }
    }
    const epub = await new EPUB(loader).init();
    if (epub.rendition?.layout === 'pre-paginated') throw Error('FIXED_LAYOUT_UNSUPPORTED');
    // Each chapter is a blob document: give it its own policy before it is loaded.
    // Adding a head-only meta element preserves the body DOM used by XPointer conversion.
    epub.transformTarget.addEventListener('data', ({ detail }: any) => {
      if (detail.type === 'text/css') { detail.data = Promise.resolve(detail.data).then(offlineCSS); return; }
      if (!['application/xhtml+xml', 'text/html', 'image/svg+xml'].includes(detail.type)) return;
      detail.data = Promise.resolve(detail.data).then((data: string) => {
        const doc = new DOMParser().parseFromString(data, detail.type === 'text/html' ? 'text/html' : 'application/xhtml+xml');
        const head = doc.querySelector('head');
        for (const element of doc.querySelectorAll('*')) {
          for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name.toLowerCase();
            if (name === 'style') element.setAttribute(name, offlineCSS(attribute.value));
            if (['src', 'srcset', 'poster', 'data', 'background', 'xlink:href'].includes(name) &&
              (name === 'srcset' || unsafeURL(attribute.value))) element.removeAttribute(attribute.name);
            if (name === 'href' && element.localName !== 'a' && unsafeURL(attribute.value)) element.removeAttribute(name);
            if (name.startsWith('on')) element.removeAttribute(attribute.name);
          }
        }
        for (const style of doc.querySelectorAll('style')) style.textContent = offlineCSS(style.textContent || '');
        if (head) {
          const meta = doc.createElementNS('http://www.w3.org/1999/xhtml', 'meta');
          meta.setAttribute('http-equiv', 'Content-Security-Policy');
          meta.setAttribute('content', "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' blob: data:; img-src blob: data:; font-src blob: data:; media-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'");
          head.prepend(meta);
        }
        return new XMLSerializer().serializeToString(doc);
      });
    });
    return { book: epub, archive: zip };
  } catch (error) { await zip.close(); throw error; }
}

const simpleText = (value: any): string => typeof value === 'string' ? value :
  Array.isArray(value) ? value.map(simpleText).join(', ') : value?.name ? simpleText(value.name) :
    value && typeof value === 'object' ? simpleText(Object.values(value)[0]) : '';
const flattenTOC = (items: any[], depth = 0): any[] => items.flatMap(item => [
  { label: simpleText(item.label), href: item.href, depth }, ...flattenTOC(item.subitems ?? [], depth + 1)
]);

function appearance() {
  const [bg, fg] = themes[settings.theme as keyof typeof themes] ?? themes.light;
  document.body.style.background = bg;
  view?.renderer?.setStyles(`:root{color-scheme:${settings.theme === 'dark' ? 'dark' : 'light'}}
    html,body{background:${bg}!important;color:${fg}!important}
    body{font-size:${settings.fontSize}px!important;line-height:${settings.lineHeight}!important}
    p,div,li{line-height:${settings.lineHeight}!important}a{color:inherit}`);
}

function bindGestures(doc: Document) {
  let downX = 0, downY = 0, downAt = 0;
  const point = (event: PointerEvent) => {
    const frame = doc.defaultView?.frameElement?.getBoundingClientRect();
    // EPUB iframes can span many off-screen columns. Their document width is
    // not the visible screen width, and must not determine tap zones.
    return { x: event.clientX + (frame?.left ?? 0), y: event.clientY + (frame?.top ?? 0) };
  };
  doc.addEventListener('pointerdown', (event: PointerEvent) => {
    const p = point(event); downX = p.x; downY = p.y; downAt = Date.now();
    userActionUntil = Date.now() + 3000;
  });
  doc.addEventListener('pointerup', (event: PointerEvent) => {
    if (suppress || !view || event.button !== 0) return;
    if (doc.getSelection()?.toString() || (event.target as Element)?.closest?.('a')) return;
    const p = point(event), dx = p.x - downX, dy = p.y - downY;
    // Foliate handles touch swipes, including movement that emits pointercancel.
    // These listeners only handle deliberate, stationary taps.
    if (Date.now() - downAt > 500 || Math.abs(dx) > 10 || Math.abs(dy) > 10) return;
    const ratio = p.x / window.innerWidth;
    if (ratio >= 1 / 3 && ratio <= 2 / 3) { emit('toggleControls'); return; }
    if (ratio < 0 || ratio > 1 || Date.now() - lastTapTurnAt < 300) return;
    lastTapTurnAt = Date.now(); userActionUntil = Date.now() + 3000;
    void (ratio < 1 / 3 ? view.prev() : view.next());
  });
}

// Also handle taps on the page gutters outside chapter iframes.
bindGestures(document);

async function snapshot(location: any, capturedSession: string, restored: boolean) {
  if (!location?.cfi || capturedSession !== session) return;
  let xpointer = '';
  try { xpointer = (await getXPointerFromCFI(location.cfi, undefined, undefined, book)).xpointer; } catch {}
  if (capturedSession !== session) return;
  const fraction = Math.max(0, Math.min(1, location.fraction ?? 0));
  lastPosition = { cfi: location.cfi, xpointer, percentage: fraction, chapter: simpleText(location.tocItem?.label) };
  emit('position', { position: lastPosition, restored });
}

async function close() {
  suppress++;
  view?.close(); view?.remove(); view = undefined;
  book?.destroy?.(); book = undefined;
  await archive?.close(); archive = undefined;
  lastPosition = undefined;
  suppress--;
}

async function open(command: any) {
  await close();
  session = command.session;
  suppress++;
  try {
    document.getElementById('error')!.textContent = '';
    const response = await fetch(command.url);
    if (!response.ok) throw Error('BOOK_NOT_FOUND');
    const file = new File([await response.blob()], 'book.epub', { type: 'application/epub+zip' });
    const loaded = await loadEPUB(file);
    book = loaded.book; archive = loaded.archive;
    emit('metadata', { metadata: { title: simpleText(book.metadata.title), author: simpleText(book.metadata.author),
      hash: await partialMD5(file), toc: flattenTOC(book.toc ?? []) } });
    const cover = await book.getCover();
    if (cover && cover.size < 4 * 1024 * 1024) {
      const base64 = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader(); reader.onload = () => resolve(String(reader.result));
        reader.onerror = reject; reader.readAsDataURL(cover);
      });
      emit('cover', { cover: base64 });
    }
    // Import runs behind the native bookshelf. Extracting metadata must not
    // depend on an iframe loading or a hidden renderer producing a page.
    if (command.metadataOnly) { emit('opened'); return; }
    view = document.createElement('foliate-view');
    document.body.append(view);
    view.addEventListener('load', ({ detail: { doc } }: any) => bindGestures(doc));
    view.addEventListener('external-link', (event: Event) => event.preventDefault());
    view.addEventListener('link', () => { userActionUntil = Date.now() + 1500; });
    await view.open(book);
    view.renderer.addEventListener('relocate', (event: CustomEvent) => {
      const captured = session;
      const intentional = ['page', 'snap', 'scroll', 'navigation', 'selection'].includes(event.detail.reason);
      const restored = suppress > 0 || !intentional || Date.now() > userActionUntil;
      const location = view.lastLocation;
      eventQueue = eventQueue.then(() => snapshot(location, captured, restored)).catch(() => {});
    });
    view.renderer.setAttribute('gap', '4%');
    view.renderer.setAttribute('column-gap', '32px');
    // Foliate accepts per-side margins; a generic "margin" attribute is ignored.
    for (const side of ['top', 'bottom']) view.renderer.setAttribute(`margin-${side}`, '12px');
    for (const side of ['left', 'right']) view.renderer.setAttribute(`margin-${side}`, '24px');
    view.renderer.setAttribute('max-column-count', '2');
    view.renderer.setAttribute('max-inline-size', '720px');
    appearance();
    await view.init({ lastLocation: command.cfi || undefined });
    await eventQueue;
    emit('opened');
  } finally { suppress--; }
}

async function receive(command: any) {
  if (command.version !== 1 || typeof command.session !== 'string') return;
  if (command.type !== 'open' && command.session !== session) return;
  try {
    if (['next', 'previous', 'navigate', 'fraction'].includes(command.type)) userActionUntil = Date.now() + 1500;
    if (command.type === 'open') await open(command);
    else if (command.type === 'close') { await eventQueue; emit('closed', { position: lastPosition }); await close(); }
    else if (command.type === 'next') await view?.next();
    else if (command.type === 'previous') await view?.prev();
    else if (command.type === 'appearance') {
      suppress++;
      try { settings = { ...settings, ...command.settings }; appearance(); await eventQueue; }
      finally { suppress--; }
    }
    else if (command.type === 'navigate') await view?.goTo(command.href || command.cfi);
    else if (command.type === 'fraction') await view?.goToFraction(command.percentage);
    else if (command.type === 'restore') {
      suppress++;
      try {
        let cfi = command.cfi;
        if (command.xpointer) cfi = await getCFIFromXPointer(command.xpointer, undefined, undefined, book);
        if (!cfi || !view.resolveCFI(cfi)) throw Error('UNRESOLVED_POSITION');
        await view.goTo(cfi); await eventQueue;
        emit('restored', { requestId: command.requestId, position: lastPosition });
      } finally { suppress--; }
    }
  } catch (error) {
    console.error('EPUB operation failed:', String((error as Error).message));
    emit('error', { requestId: command.requestId, message: String((error as Error).message) });
    if (command.type === 'open') { await close(); document.getElementById('error')!.textContent = String((error as Error).message); }
  }
}

let commandQueue = Promise.resolve();
(window as any).readerReceive = (command: any) => {
  commandQueue = commandQueue.then(() => receive(command));
};
// Browser tests exercise the same parser, converter and bridge as the HAP.
if (__READER_TEST__) (window as any).readerTest = { loadEPUB, XCFI, getCFIFromXPointer, getXPointerFromCFI, partialMD5,
  getView: () => view, getBook: () => book, idle: () => commandQueue.then(() => eventQueue) };
emit('ready');
