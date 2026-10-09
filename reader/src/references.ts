import { FootnoteHandler } from '../../vendor/foliate-js/footnotes.js';
import layout from './references.css';
import { palette, themeIsDark } from './palette';
import { typographyStyles, enforceMinimumFont, type Appearance, type ReaderFont } from './typography';

type Link = { a: HTMLAnchorElement; href: string; follow?: boolean; check?: boolean };
type ReferenceHost = {
  getBook: () => any;
  getSettings: () => Appearance;
  getFonts: () => ReaderFont[];
  getFontSources: () => Map<string, string>;
  getSystemDark: () => boolean;
  getInsets: () => { top: number; bottom: number };
  navigate: (href: string) => void;
  clearSelection: () => void;
  setBlocked: (blocked: boolean) => void;
};

// Readest's FootnotePopup/Popup adapted to the offline reader. Foliate owns
// extraction and rendering; the main view never navigates to preview a note.
export function createReferences(host: ReferenceHost) {
  const style = document.createElement('style'); style.textContent = layout; document.head.append(style);
  const root = document.createElement('div'); root.id = 'reference-layer'; root.hidden = true;
  root.innerHTML = `<div class="reference-backdrop"></div><div id="reference-popup" role="dialog" aria-modal="true" tabindex="-1">
    <div class="reference-content"></div><div class="reference-actions">
    <button type="button" data-reference-back><svg viewBox="0 0 24 24"><path d="M19 12H5M12 5l-7 7 7 7"/></svg></button>
    <button type="button" data-reference-jump><svg viewBox="0 0 24 24"><path d="M7 17L17 7M7 7h10v10"/></svg></button>
    <button type="button" data-reference-close><svg viewBox="0 0 24 24"><path d="M6 6l12 12M6 18L18 6"/></svg></button>
    </div></div>`;
  document.body.append(root);
  const box = root.querySelector<HTMLElement>('#reference-popup')!;
  const content = root.querySelector<HTMLElement>('.reference-content')!;
  const back = root.querySelector<HTMLButtonElement>('[data-reference-back]')!;
  const jump = root.querySelector<HTMLButtonElement>('[data-reference-jump]')!;
  const closeButton = root.querySelector<HTMLButtonElement>('[data-reference-close]')!;
  let labels = { reference: 'Reference', referenceError: 'Unable to load this reference.', referenceBack: 'Back', referenceJump: 'Jump to Location', close: 'Close' };
  let popupView: any, observer: ResizeObserver | undefined, frame = 0, request = 0;
  let anchorRect: { left: number; right: number; top: number; bottom: number } | undefined;
  let sourceAnchor: HTMLAnchorElement | undefined;
  let history: Link[] = [];
  const active = () => !root.hidden;
  function localize(value: any = {}) {
    labels = { ...labels, ...value };
    box.setAttribute('aria-label', labels.reference);
    for (const [button, label] of [[back, labels.referenceBack], [jump, labels.referenceJump], [closeButton, labels.close]] as const) {
      button.setAttribute('aria-label', label); button.title = label;
    }
  }
  localize();
  function releaseView() {
    observer?.disconnect(); observer = undefined;
    cancelAnimationFrame(frame);
    popupView?.close(); popupView?.remove(); popupView = undefined;
    content.replaceChildren();
  }
  function dismiss() {
    request++; releaseView(); root.hidden = true; history = []; anchorRect = undefined;
    host.setBlocked(false);
    sourceAnchor?.focus({ preventScroll: true }); sourceAnchor = undefined;
  }
  function fit() {
    if (!active() || !anchorRect) return;
    const { top, bottom } = host.getInsets();
    const minY = top + 10, maxY = innerHeight - bottom - 10;
    const width = Math.max(1, Math.min(Math.max(360, innerWidth / 4), 720, innerWidth - 20));
    const left = Math.max(10, Math.min((anchorRect.left + anchorRect.right - width) / 2, innerWidth - width - 10));
    const below = maxY - anchorRect.bottom - 10, above = anchorRect.top - 10 - minY;
    const useAbove = below < Math.min(120, maxY - minY) && above > below;
    const available = Math.max(1, useAbove ? above : below);
    const measured = popupView?.renderer?.viewSize || content.querySelector('.reference-error')?.getBoundingClientRect().height || 86;
    const height = Math.min(available, Math.max(88, measured + 2));
    box.style.width = `${width}px`; box.style.height = `${height}px`;
    box.style.left = `${left}px`;
    box.style.top = `${useAbove ? anchorRect.top - 10 - height : anchorRect.bottom + 10}px`;
    box.toggleAttribute('data-above', useAbove);
    box.style.setProperty('--reference-pointer', `${Math.max(16, Math.min(width - 16, (anchorRect.left + anchorRect.right) / 2 - left))}px`);
  }
  function appearance() {
    const settings = host.getSettings(), dark = themeIsDark(settings.themeMode, host.getSystemDark());
    // Popup.tsx uses base-300 in light mode and base-100 in dark mode.
    const theme = palette(settings.themeColor, dark), bg = dark ? theme.bg : theme.line;
    root.style.setProperty('--reference-bg', bg); root.style.setProperty('--reference-fg', theme.fg);
    root.style.setProperty('--reference-line', `${theme.fg}33`); root.style.setProperty('--reference-button', theme.inset);
    popupView?.renderer?.setStyles(`:root{color-scheme:${dark ? 'dark' : 'light'}}
      html,body{background:${bg}!important;color:${theme.fg}!important}a{color:inherit}
      ${typographyStyles(settings, host.getFonts(), host.getFontSources())}
      body{padding:1em!important;padding-bottom:56px!important;overflow-wrap:break-word}
      a:any-link{text-decoration:none;padding:unset;margin:unset}
      ol{margin:0;padding:0}p,li,blockquote,dd{margin:unset!important;text-indent:unset!important}
      div{margin:unset!important;padding:unset!important}dt{font-weight:bold;line-height:1.6}
      .duokan-footnote-content,.duokan-footnote-item,.epubtype-footnote{display:block!important}
      img,svg{max-width:100%!important;height:auto}`);
    for (const { doc } of popupView?.renderer?.getContents() || []) enforceMinimumFont(doc, settings.minimumFontSize);
    fit();
  }
  function show(detail: Link) {
    const id = ++request, book = host.getBook();
    releaseView(); box.style.visibility = 'hidden'; back.hidden = history.length < 2; jump.hidden = false;
    root.hidden = false; host.setBlocked(true); appearance(); fit();
    const handler = new FootnoteHandler();
    let candidate: any;
    let extracted = false;
    let reveal = () => {};
    const fail = () => {
      if (id !== request) { candidate?.close(); candidate?.remove(); return; }
      releaseView(); jump.hidden = true;
      const error = document.createElement('p'); error.className = 'reference-error'; error.textContent = labels.referenceError;
      content.append(error); fit(); box.style.visibility = 'visible'; box.focus({ preventScroll: true });
    };
    handler.addEventListener('before-render', ({ detail: { view } }: any) => {
      candidate = view;
      if (id !== request) { view.close(); view.remove(); return; }
      popupView = view; content.replaceChildren(view);
      const renderer = view.renderer;
      renderer.setAttribute('flow', 'scrolled'); renderer.setAttribute('no-preload', ''); renderer.setAttribute('no-background', '');
      for (const side of ['top', 'right', 'bottom', 'left']) renderer.setAttribute(`margin-${side}`, '0px');
      renderer.setAttribute('gap', '0%');
      appearance();
      view.addEventListener('external-link', (event: Event) => event.preventDefault());
      view.addEventListener('link', (event: CustomEvent<Link>) => {
        event.preventDefault();
        // A backlink to the marker is an explicit request to return to the book.
        if (event.detail.a.getAttribute('role')?.split(/\s+/).includes('doc-backlink') ||
          event.detail.a.getAttribute('epub:type')?.split(/\s+/).includes('backlink')) { dismiss(); return; }
        history.push(event.detail); show({ ...event.detail, follow: true });
      });
      reveal = () => {
        if (id !== request || !extracted) return;
        const first = box.style.visibility === 'hidden';
        fit(); box.style.visibility = 'visible'; if (first) box.focus({ preventScroll: true });
      };
      view.addEventListener('relocate', reveal);
      view.addEventListener('load', ({ detail: { doc } }: any) => {
        if (id !== request) return;
        enforceMinimumFont(doc, host.getSettings().minimumFontSize);
        doc.addEventListener('keydown', keydown);
        observer = new ResizeObserver(() => { cancelAnimationFrame(frame); frame = requestAnimationFrame(reveal); });
        observer.observe(doc.documentElement);
      });
    });
    handler.addEventListener('render', ({ detail: rendered }: any) => {
      if (id !== request) { rendered.view.close(); rendered.view.remove(); return; }
      if (detail.href.includes('#') && !rendered.target) { queueMicrotask(fail); return; }
      extracted = true;
      frame = requestAnimationFrame(reveal);
      // An inline hidden note has no visible source location to jump to.
      jump.hidden = !!rendered.hidden;
    });
    const event = new CustomEvent('link', { detail, cancelable: true });
    Promise.resolve(handler.handle(book, event)).catch(fail);
  }
  function handle(event: CustomEvent<Link>) {
    const { a } = event.detail;
    const types = `${a.getAttribute('epub:type') || a.getAttributeNS('http://www.idpf.org/2007/ops', 'type') || ''} ${a.getAttribute('role') || ''}`.split(/\s+/);
    if (types.some(type => ['backlink', 'doc-backlink'].includes(type))) return;
    const semantic = types.some(type => ['noteref', 'biblioref', 'glossref', 'doc-noteref', 'doc-biblioref', 'doc-glossref'].includes(type));
    const styled = ['duokan-footnote', 'footnote-link', 'footnote', 'footnote-ref'].some(name => a.classList.contains(name));
    const superScript = [a, a.parentElement, ...a.children].some(el => el && (el.localName === 'sup' || el.ownerDocument.defaultView?.getComputedStyle(el).verticalAlign === 'super'));
    const numeric = /^.{0,2}\d+[\])]?$/.test(a.textContent?.trim() || '') && !a.closest('nav') &&
      Array.from((a.closest('p,li,div,section') || a.parentElement)?.querySelectorAll('a') || []).filter(link => /^.{0,2}\d+[\])]?$/.test(link.textContent?.trim() || '')).length < 3;
    if (!semantic && !styled && !superScript && !numeric) return;
    event.preventDefault(); host.clearSelection();
    const rect = a.getBoundingClientRect(), frame = a.ownerDocument.defaultView?.frameElement?.getBoundingClientRect();
    anchorRect = { left: rect.left + (frame?.left || 0), right: rect.right + (frame?.left || 0), top: rect.top + (frame?.top || 0), bottom: rect.bottom + (frame?.top || 0) };
    sourceAnchor = a; history = [event.detail];
    show({ ...event.detail, follow: semantic || styled || superScript, check: !semantic && !styled && !superScript });
  }
  function keydown(event: KeyboardEvent) {
    if (!active()) return;
    if (event.key === 'Escape') { event.preventDefault(); event.stopImmediatePropagation(); dismiss(); }
    else if (['ArrowLeft', 'ArrowRight'].includes(event.key)) event.stopImmediatePropagation();
  }
  document.addEventListener('keydown', keydown, true);
  root.querySelector('.reference-backdrop')!.addEventListener('click', dismiss);
  closeButton.addEventListener('click', dismiss);
  back.addEventListener('click', () => { if (history.length > 1) { history.pop(); show({ ...history.at(-1)!, follow: true }); } });
  jump.addEventListener('click', () => { const href = history.at(-1)?.href; dismiss(); if (href) host.navigate(href); });
  window.addEventListener('resize', dismiss);
  return { handle, dismiss, active, appearance, state(value: any) { localize(value?.labels); if (active()) fit(); } };
}
