import layout from './chrome.css';
import motion from './readest-motion.css';
import { BUILTIN_THEMES, palette, themeIsDark } from './palette';

type Appearance = { fontSize: number; lineHeight: number; themeMode: string; themeColor: string };
type TocItem = { label: string; href: string; depth: number };
type ChromeHost = {
  command: (command: any) => void;
  emit: (type: string, data?: object) => void;
  getView: () => any;
  getSettings: () => Appearance;
  getSystemDark: () => boolean;
};

// Readest HeaderBar / MobileFooterBar / DesktopFooterBar adapted to the
// offline bridge. Actions/panels are registered here without touching layout
// or motion. Unsupported Readest features are omitted from the toolbar.
const icons: Record<string, string> = {
  library: '<path d="M4 4h4v16H4zM10 4h4v16h-4zM16 5l4-1 3 15-4 1z"/>',
  toc: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
  color: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5"/>',
  progress: '<path d="M3 7h18M3 17h18M8 4v6M16 14v6"/>',
  font: '<path d="M3 19L9 5l6 14M5 15h8M16 11h5M18.5 11v8"/>',
  menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  close: '<path d="M6 6l12 12M6 18L18 6"/>',
  previous: '<path d="M15 5l-7 7 7 7"/>', next: '<path d="M9 5l7 7-7 7"/>',
  previousSection: '<path d="M12 5l-7 7 7 7M19 5l-7 7 7 7"/>',
  nextSection: '<path d="M5 5l7 7-7 7M12 5l7 7-7 7"/>',
  historyBack: '<path d="M9 4L4 9l5 5M4 9h10a6 6 0 010 12"/>',
  historyForward: '<path d="M15 4l5 5-5 5M20 9H10a6 6 0 000 12"/>',
  decrease: '<path d="M5 12h14"/>', increase: '<path d="M5 12h14M12 5v14"/>',
  auto: '<circle cx="12" cy="12" r="8"/><path d="M12 4v16"/>',
  light: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5"/>',
  dark: '<path d="M20 14a8 8 0 01-10-10 8 8 0 1010 10z"/>'
};
const english: Record<string, string> = {
  library: 'Bookshelf', toc: 'Contents', color: 'Theme', progress: 'Reading progress', font: 'Font & Layout', menu: 'View', close: 'Close',
  previous: 'Previous page', next: 'Next page', previousSection: 'Previous section', nextSection: 'Next section',
  historyBack: 'Go back', historyForward: 'Go forward', decrease: 'Decrease font size', increase: 'Increase font size',
  fontSize: 'Font size', lineHeight: 'Line spacing', light: 'Light', sepia: 'Sepia', dark: 'Dark',
  settings: 'Settings', upload: 'Send progress', reconcile: 'Check remote', status: 'Offline ready',
  auto: 'System', themeMode: 'Theme mode', themeColor: 'Color scheme', scopeReader: 'Reader',
  default: 'Default', gray: 'Gray', grass: 'Grass', cherry: 'Cherry', sky: 'Sky', solarized: 'Solarized', gruvbox: 'Gruvbox', nord: 'Nord', contrast: 'Contrast', sunset: 'Sunset'
};

export function createChrome(host: ChromeHost) {
  const style = document.createElement('style'); style.textContent = `${layout}\n${motion}`; document.head.append(style);
  const root = document.createElement('div'); root.id = 'reader-chrome'; root.hidden = true; document.body.append(root);
  let labels = { ...english }, visible = true, panel = '', title = '', toc: TocItem[] = [];
  let progress = 0, chapter = '', syncEnabled = false, busy = false;
  const text = (value: string) => value.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
  const button = (action: string, extra = '') => `<button class="icon-button ${extra}" type="button" data-action="${action}" aria-label="${text(labels[action])}" title="${text(labels[action])}"><svg viewBox="0 0 24 24" aria-hidden="true">${icons[action]}</svg></button>`;
  const navigation = () => ['previousSection', 'previous', 'historyBack', 'historyForward', 'next', 'nextSection'].map(a => button(a)).join('');
  const range = () => `<input type="range" min="0" max="100" step="0.1" value="${progress}" aria-label="${text(labels.progress)}" data-progress>`;
  // Each panel is a separate extension point, matching Readest's footer panels.
  const panels: Record<string, () => string> = {
    progress: () => `<div class="progress-caption"><span class="chapter-label">${text(chapter || title)}</span><output class="percentage">${Math.round(progress)}%</output></div>${range()}<div class="navigation-actions">${navigation()}</div>`,
    font: () => `<div class="settings-row"><label>${text(labels.fontSize)}</label>${button('decrease')}<output data-font-size></output>${button('increase')}</div><div class="settings-row"><label for="reader-line-height">${text(labels.lineHeight)}</label><output data-line-height></output></div><input id="reader-line-height" type="range" min="1.2" max="2.4" step="0.1" aria-label="${text(labels.lineHeight)}">`,
    color: () => `<div class="settings-row"><label>${text(labels.themeMode)}</label><div class="theme-modes" role="radiogroup" aria-label="${text(labels.themeMode)}">${['auto', 'light', 'dark'].map(m => `<button class="icon-button" type="button" role="radio" data-mode="${m}" aria-label="${text(labels[m])}" title="${text(labels[m])}"><svg viewBox="0 0 24 24" aria-hidden="true">${icons[m]}</svg></button>`).join('')}</div></div><div class="theme-color-label">${text(labels.themeColor)}</div><div class="theme-options" role="group" aria-label="${text(labels.themeColor)}">${BUILTIN_THEMES.map(t => `<button class="theme-option" type="button" data-theme="${t.name}" aria-label="${text(labels[t.name] || t.label)}"><span class="theme-sample">Aa</span><span class="theme-name">${text(labels[t.name] || t.label)}</span></button>`).join('')}</div>`,
    toc: () => toc.map((item, i) => `<button class="toc-item" type="button" data-toc="${i}" style="padding-inline-start:${12 + item.depth * 16}px">${text(item.label)}</button>`).join('')
  };
  function render() {
    root.innerHTML = `<header class="header-bar" aria-label="${text(title)}" aria-hidden="${!visible}">${button('library')}${button('toc', 'desktop-only')}<div class="header-title">${text(title)}</div><div class="header-end">${button('color', 'desktop-only')}${button('font', 'desktop-only')}${button('menu')}</div></header>
      <footer class="footer-bar" aria-hidden="${!visible}">
        ${Object.keys(panels).map(key => `<section class="footer-panel" data-panel="${key}" aria-label="${text(labels[key])}" aria-hidden="${panel !== key}"><div class="panel-content"><div class="panel-heading"><span>${text(labels[key])}</span>${button('close')}</div>${panels[key]()}</div></section>`).join('')}
        <nav class="mobile-tools" aria-label="${text(labels.menu)}">${['toc', 'color', 'progress', 'font'].map(a => button(a)).join('')}</nav>
        <nav class="desktop-tools" aria-label="${text(labels.progress)}">${button('previousSection')}${button('previous')}${button('historyBack')}${button('historyForward')}<output class="percentage">${Math.round(progress)}%</output>${range()}${button('next')}${button('nextSection')}</nav>
      </footer><div class="view-menu" hidden>${['settings', 'upload', 'reconcile'].map(a => `<button type="button" class="menu-action" data-action="${a}">${text(labels[a])}</button>`).join('')}<div class="sync-status" role="status"></div></div>`;
    syncVisibility(); updateAppearance(); updatePosition();
  }
  function syncVisibility() {
    for (const bar of root.querySelectorAll<HTMLElement>('.header-bar,.footer-bar')) {
      bar.setAttribute('aria-hidden', String(!visible)); (bar as any).inert = !visible;
    }
    for (const section of root.querySelectorAll<HTMLElement>('[data-panel]')) {
      const active = visible && section.dataset.panel === panel;
      section.setAttribute('aria-hidden', String(!active)); (section as any).inert = !active;
    }
    for (const item of root.querySelectorAll<HTMLElement>('[data-action]')) {
      if (panels[item.dataset.action!]) item.setAttribute('aria-expanded', String(panel === item.dataset.action));
    }
    if (!visible) { root.querySelector<HTMLElement>('.view-menu')!.hidden = true; panel = ''; }
    if (!visible && root.contains(document.activeElement)) (document.activeElement as HTMLElement).blur();
  }
  function setVisible(value: boolean) { visible = value; if (!visible) panel = ''; syncVisibility(); }
  function updatePosition() {
    for (const range of root.querySelectorAll<HTMLInputElement>('[data-progress]')) if (document.activeElement !== range) range.value = String(progress);
    for (const value of root.querySelectorAll<HTMLElement>('.percentage')) value.textContent = `${Math.round(progress)}%`;
    root.querySelector<HTMLElement>('.chapter-label')!.textContent = chapter || title;
    for (const action of ['historyBack', 'historyForward']) for (const b of root.querySelectorAll<HTMLButtonElement>(`[data-action='${action}']`)) b.disabled = !host.getView()?.history?.[action === 'historyBack' ? 'canGoBack' : 'canGoForward'];
  }
  function updateAppearance() {
    const settings = host.getSettings();
    const dark = themeIsDark(settings.themeMode, host.getSystemDark());
    const theme = palette(settings.themeColor, dark);
    const colors = [theme.bg, theme.inset, theme.fg, theme.muted, theme.line];
    ['surface', 'inset', 'fg', 'muted', 'line'].forEach((name, i) => root.style.setProperty(`--reader-${name}`, colors[i]));
    root.querySelector<HTMLElement>('[data-font-size]')!.textContent = String(settings.fontSize);
    root.querySelector<HTMLElement>('[data-line-height]')!.textContent = settings.lineHeight.toFixed(1);
    root.querySelector<HTMLInputElement>('#reader-line-height')!.value = String(settings.lineHeight);
    for (const b of root.querySelectorAll<HTMLElement>('[data-theme]')) {
      const colors = palette(b.dataset.theme!, dark);
      b.style.background = colors.bg; b.style.color = colors.fg;
      b.setAttribute('aria-pressed', String(settings.themeColor === b.dataset.theme));
    }
    for (const b of root.querySelectorAll<HTMLElement>('[data-mode]')) b.setAttribute('aria-checked', String(settings.themeMode === b.dataset.mode));
    (root.querySelector('[data-action="decrease"]') as HTMLButtonElement).disabled = settings.fontSize <= 12;
    (root.querySelector('[data-action="increase"]') as HTMLButtonElement).disabled = settings.fontSize >= 40;
  }
  function appearance(settings: Appearance) {
    host.command({ type: 'appearance', settings }); host.emit('appearanceChanged', { settings });
  }
  root.addEventListener('click', event => {
    const target = (event.target as Element).closest<HTMLButtonElement>('button');
    if (!target || target.disabled) return;
    const action = target.dataset.action;
    if (target.dataset.toc !== undefined) { host.command({ type: 'navigate', href: toc[Number(target.dataset.toc)].href }); panel = ''; syncVisibility(); }
    else if (target.dataset.theme) appearance({ ...host.getSettings(), themeColor: target.dataset.theme });
    else if (target.dataset.mode) appearance({ ...host.getSettings(), themeMode: target.dataset.mode });
    else if (action === 'menu') { const menu = root.querySelector<HTMLElement>('.view-menu')!; menu.hidden = !menu.hidden; target.setAttribute('aria-expanded', String(!menu.hidden)); }
    else if (action && panels[action]) { panel = panel === action ? '' : action; root.querySelector<HTMLElement>('.view-menu')!.hidden = true; syncVisibility(); }
    else if (action === 'close') { panel = ''; syncVisibility(); }
    else if (action === 'decrease' || action === 'increase') appearance({ ...host.getSettings(), fontSize: Math.max(12, Math.min(40, host.getSettings().fontSize + (action === 'increase' ? 2 : -2))) });
    else if (['library', 'settings', 'upload', 'reconcile'].includes(action!)) { root.querySelector<HTMLElement>('.view-menu')!.hidden = true; host.emit('readerAction', { action }); }
    else if (action) host.command({ type: action });
  });
  root.addEventListener('input', event => {
    const target = event.target as HTMLInputElement;
    if (target.matches('[data-progress]')) for (const output of root.querySelectorAll<HTMLElement>('.percentage')) output.textContent = `${Math.round(Number(target.value))}%`;
    if (target.id === 'reader-line-height') root.querySelector<HTMLElement>('[data-line-height]')!.textContent = Number(target.value).toFixed(1);
  });
  root.addEventListener('change', event => {
    const target = event.target as HTMLInputElement;
    if (target.matches('[data-progress]')) host.command({ type: 'fraction', percentage: Number(target.value) / 100 });
    else if (target.id === 'reader-line-height') appearance({ ...host.getSettings(), lineHeight: Number(target.value) });
  });
  document.addEventListener('keydown', event => {
    if (root.hidden) return;
    if (event.key === 'Escape') { event.preventDefault(); back(); }
    else if (!root.contains(document.activeElement) && ['ArrowLeft', 'ArrowRight'].includes(event.key)) { event.preventDefault(); host.command({ type: event.key === 'ArrowLeft' ? 'previous' : 'next' }); }
  });
  function back() {
    const menu = root.querySelector<HTMLElement>('.view-menu')!;
    if (!menu.hidden) menu.hidden = true;
    else if (panel) { panel = ''; syncVisibility(); }
    else host.emit('readerAction', { action: 'library' });
  }
  render();
  return {
    open(bookTitle: string, items: TocItem[]) { title = bookTitle; toc = items; panel = ''; visible = true; render(); root.hidden = false; },
    close() { root.hidden = true; panel = ''; },
    toggle() { setVisible(!visible); host.emit('toggleControls'); },
    back,
    appearance: updateAppearance,
    position(value: { percentage: number; chapter: string }) { progress = value.percentage * 100; chapter = value.chapter; updatePosition(); },
    state(value: any) {
      root.style.setProperty('--safe-top', `${Math.max(0, value.safeTop || 0)}px`);
      root.style.setProperty('--safe-bottom', `${Math.max(0, value.safeBottom || 0)}px`);
      if (value.labels && Object.keys(value.labels).some(k => labels[k] !== value.labels[k])) { labels = { ...labels, ...value.labels }; render(); }
      syncEnabled = !!value.syncEnabled; busy = !!value.busy;
      setVisible(value.controls !== false);
      root.querySelector<HTMLElement>('.sync-status')!.textContent = value.status || labels.status;
      for (const action of ['upload', 'reconcile']) root.querySelector<HTMLButtonElement>(`[data-action='${action}']`)!.disabled = !syncEnabled || busy;
    }
  };
}
