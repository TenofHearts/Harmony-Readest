import { EPUB } from '../../vendor/foliate-js/epub.js';
import '../../vendor/foliate-js/view.js';
// The JS codec is bundled locally; it does not fetch/compile an inline WASM
// module or rely on ArkWeb's optional native compression APIs.
import { BlobReader, BlobWriter, TextWriter, ZipReader, configure } from '@zip.js/zip.js/index-native.js';
import { partialMD5 } from '../../vendor/readest/apps/readest-app/src/utils/md5';
import { getCFIFromXPointer, getXPointerFromCFI, XCFI } from '../../vendor/readest/apps/readest-app/src/utils/xcfi';
import { createChrome } from './chrome';
import { palette, themeIsDark } from './palette';
import { defaultTypography, typographyStyles, fontFaceStyles, builtinFontFamilies, enforceMinimumFont, restoreMinimumFont, type ReaderFont } from './typography';
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
const locatorDocuments = new Map<number, Document>();
let userActionUntil = 0;
let lastTapTurnAt = 0;
let settings = { ...defaultTypography };
let fonts: ReaderFont[] = [];
const fontSources = new Map<string, string>();
const chromeFonts = document.createElement('style'); document.head.append(chromeFonts);
async function loadSelectedFonts() {
  const selected = [settings.defaultFont === 'sans-serif' ? settings.sansSerifFont : settings.serifFont, settings.monospaceFont, settings.defaultCJKFont];
  const families = selected.map(name => builtinFontFamilies[name] && fonts.some(face => face.family === builtinFontFamilies[name]) ? builtinFontFamilies[name] : name);
  for (const face of fonts) if (families.includes(face.family) && !fontSources.has(face.url)) {
    const response = await fetch(face.url); if (!response.ok) throw Error('INVALID_FONT');
    fontSources.set(face.url, URL.createObjectURL(await response.blob()));
  }
}
let safeTop = 0, safeBottom = 0;
const systemMedia = window.matchMedia('(prefers-color-scheme: dark)');
let nativeSystemDark: boolean | undefined;
const systemDark = () => nativeSystemDark ?? systemMedia.matches;
const chrome = createChrome({ emit, getView: () => view, getSettings: () => settings,
  getSystemDark: systemDark,
  getFonts: () => fonts,
  command: command => (window as any).readerReceive({ version: 1, session, ...command, fromChrome: true }) });
systemMedia.addEventListener('change', () => appearance());
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
  chromeFonts.textContent = fontFaceStyles(fonts, fontSources, true);
  const dark = themeIsDark(settings.themeMode, systemDark());
  const { bg, fg } = palette(settings.themeColor, dark);
  document.body.style.background = bg;
  document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
  restoreMinimumFont();
  view?.renderer?.setStyles(`:root{color-scheme:${dark ? 'dark' : 'light'}}
    html,body{background:${bg}!important;color:${fg}!important}
    a{color:inherit}${typographyStyles(settings, fonts, fontSources)}`);
  for (const { doc } of view?.renderer?.getContents() || []) enforceMinimumFont(doc, settings.minimumFontSize);
  const attributes = {
    'gap': `${settings.gapPercent}%`, 'column-gap': `${settings.columnGapPx}px`,
    'margin-top': `${settings.marginTopPx + safeTop}px`, 'margin-bottom': `${settings.marginBottomPx + safeBottom}px`,
    'margin-left': `${settings.marginLeftPx}px`, 'margin-right': `${settings.marginRightPx}px`,
    'max-column-count': String(settings.maxColumnCount), 'max-inline-size': `${settings.maxInlineSize}px`,
    'max-block-size': `${settings.maxBlockSize}px`, 'flow': settings.scrolled ? 'scrolled' : 'paginated'
  };
  for (const [key, value] of Object.entries(attributes)) if (view?.renderer?.getAttribute(key) !== value) view?.renderer?.setAttribute(key, value);
  chrome.appearance();
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
    if (chrome.hasOverlay() || (event.target as Element)?.closest?.('#reader-chrome')) return;
    const p = point(event); downX = p.x; downY = p.y; downAt = Date.now();
    userActionUntil = Date.now() + 3000;
  });
  doc.addEventListener('pointerup', (event: PointerEvent) => {
    if (suppress || !view || chrome.hasOverlay() || event.button !== 0) return;
    if ((event.target as Element)?.closest?.('#reader-chrome')) return;
    if (doc.getSelection()?.toString() || (event.target as Element)?.closest?.('a')) return;
    const p = point(event), dx = p.x - downX, dy = p.y - downY;
    // Foliate handles touch swipes, including movement that emits pointercancel.
    // These listeners only handle deliberate, stationary taps.
    if (Date.now() - downAt > 500 || Math.abs(dx) > 10 || Math.abs(dy) > 10) return;
    const ratio = p.x / window.innerWidth;
    if (ratio >= 1 / 3 && ratio <= 2 / 3) { chrome.toggle(); return; }
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
  try {
    const index = XCFI.extractSpineIndex(location.cfi);
    let doc = locatorDocuments.get(index);
    if (!doc) {
      doc = await book.sections[index].createDocument();
      if (capturedSession !== session) return;
      locatorDocuments.set(index, doc!);
      // Reuse canonical chapter DOMs for page turns without retaining an entire book.
      if (locatorDocuments.size > 2) locatorDocuments.delete(locatorDocuments.keys().next().value!);
    }
    xpointer = (await getXPointerFromCFI(location.cfi, doc, index, book)).xpointer;
  } catch {}
  if (capturedSession !== session) return;
  const fraction = Math.max(0, Math.min(1, location.fraction ?? 0));
  lastPosition = { cfi: location.cfi, xpointer, percentage: fraction, chapter: simpleText(location.tocItem?.label) };
  chrome.position(lastPosition);
  emit('position', { position: lastPosition, restored });
}

async function close() {
  suppress++;
  restoreMinimumFont();
  locatorDocuments.clear();
  chrome.close();
  view?.close(); view?.remove(); view = undefined;
  book?.destroy?.(); book = undefined;
  await archive?.close(); archive = undefined;
  lastPosition = undefined;
  suppress--;
}

async function open(command: any) {
  await close();
  session = command.session;
  if (command.settings) { settings = { ...defaultTypography, ...command.settings }; await loadSelectedFonts(); }
  suppress++;
  try {
    document.getElementById('error')!.textContent = '';
    const response = await fetch(command.url);
    if (!response.ok) throw Error('BOOK_NOT_FOUND');
    const file = new File([await response.blob()], 'book.epub', { type: 'application/epub+zip' });
    const loaded = await loadEPUB(file);
    book = loaded.book; archive = loaded.archive;
    emit('metadata', { metadata: { title: simpleText(book.metadata.title), author: simpleText(book.metadata.author),
      hash: await partialMD5(file), metadataJSON: JSON.stringify(book.metadata), toc: flattenTOC(book.toc ?? []) } });
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
    view.addEventListener('load', ({ detail: { doc } }: any) => { bindGestures(doc); enforceMinimumFont(doc, settings.minimumFontSize); });
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
    view.renderer.setAttribute('margin-top', `${12 + safeTop}px`);
    view.renderer.setAttribute('margin-bottom', `${12 + safeBottom}px`);
    for (const side of ['left', 'right']) view.renderer.setAttribute(`margin-${side}`, '24px');
    view.renderer.setAttribute('max-column-count', '2');
    view.renderer.setAttribute('max-inline-size', '720px');
    // Readest FoliateViewer.tsx enables this exact vendored animation; push
    // is Readest's default. No wrapper animation or replacement page layer.
    view.renderer.setAttribute('turn-style', 'push');
    if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) view.renderer.setAttribute('animated', '');
    chrome.open(simpleText(book.metadata.title), flattenTOC(book.toc ?? []));
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
    if (typeof command.systemDark === 'boolean' && command.systemDark !== nativeSystemDark) {
      nativeSystemDark = command.systemDark; appearance();
    }
    if (['next', 'previous', 'navigate', 'fraction', 'nextSection', 'previousSection', 'historyBack', 'historyForward'].includes(command.type)) {
      if (chrome.hasOverlay() && !command.fromChrome) return;
      userActionUntil = Date.now() + 3000;
    }
    if (command.type === 'open') await open(command);
    else if (command.type === 'close') { await eventQueue; await close(); emit('closed'); session = ''; }
    else if (command.type === 'next') await view?.next();
    else if (command.type === 'previous') await view?.prev();
    else if (command.type === 'nextSection') await view?.renderer?.nextSection?.();
    else if (command.type === 'previousSection') await view?.renderer?.prevSection?.();
    else if (command.type === 'historyBack') await view?.history.back();
    else if (command.type === 'historyForward') await view?.history.forward();
    else if (command.type === 'chrome') {
      chrome.state(command.chrome);
      const top = Math.max(0, command.chrome?.safeTop ?? 0), bottom = Math.max(0, command.chrome?.safeBottom ?? 0);
      if (top !== safeTop || bottom !== safeBottom) {
        safeTop = top; safeBottom = bottom;
        view?.renderer?.setAttribute('margin-top', `${settings.marginTopPx + safeTop}px`);
        view?.renderer?.setAttribute('margin-bottom', `${settings.marginBottomPx + safeBottom}px`);
      }
    }
    else if (command.type === 'systemTheme') { /* Theme already applied above, without persisting a user choice. */ }
    else if (command.type === 'fonts') {
      userActionUntil = 0;
      fonts = command.fonts || [];
      await loadSelectedFonts();
      appearance();
      for (const [url, blob] of fontSources) if (!fonts.some(face => face.url === url)) { URL.revokeObjectURL(blob); fontSources.delete(url); }
      chrome.fontsChanged();
    }
    else if (command.type === 'back') chrome.back();
    else if (command.type === 'appearance') {
      userActionUntil = 0;
      suppress++;
      try { settings = { ...settings, ...command.settings }; await loadSelectedFonts(); appearance(); await eventQueue; }
      finally { suppress--; }
    }
    else if (command.type === 'navigate') await view?.goTo(command.href || command.cfi);
    else if (command.type === 'fraction') await view?.goToFraction(command.percentage);
    else if (command.type === 'inspect') {
      const cfi = command.cfi || await getCFIFromXPointer(command.xpointer, undefined, undefined, book);
      if (!cfi || !view.resolveCFI(cfi)) throw Error('UNRESOLVED_POSITION');
      const progress = await view.getCFIProgress(cfi);
      if (!progress || !Number.isFinite(progress.fraction)) throw Error('UNRESOLVED_POSITION');
      const tocItem = await view.getTOCItemOf(cfi);
      emit('inspected', { requestId: command.requestId, position: {
        cfi, xpointer: command.xpointer, percentage: Math.max(0, Math.min(1, progress.fraction)), chapter: simpleText(tocItem?.label)
      } });
    }
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
  getView: () => view, getBook: () => book, getSettings: () => ({ ...settings }), idle: () => commandQueue.then(() => eventQueue) };
emit('ready');
