import layout from './chrome.css';
import { cssFamily, resolvedFontFamily, builtinFontFamilies } from './typography';
import motion from './readest-motion.css';
import { BUILTIN_THEMES, palette, themeIsDark } from './palette';
import { type Appearance, type ReaderFont } from './typography';

type TocItem = { label: string; href: string; depth: number };
type ChromeHost = {
  command: (command: any) => void;
  emit: (type: string, data?: object) => void;
  getView: () => any;
  getSettings: () => Appearance;
  getSystemDark: () => boolean;
  getFonts: () => ReaderFont[];
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
  "fontSize": "Font Size",
  "minimumFontSize": "Minimum Font Size",
  "fontWeight": "Font Weight",
  "lineHeight": "Line Spacing",
  "paragraphMargin": "Paragraph Margin",
  "wordSpacing": "Word Spacing (px)",
  "letterSpacing": "Letter Spacing (px)",
  "textIndent": "Text Indent (em)",
  "marginTopPx": "Top Margin (px)",
  "marginBottomPx": "Bottom Margin (px)",
  "marginLeftPx": "Left Margin (px)",
  "marginRightPx": "Right Margin (px)",
  "gapPercent": "Additional Margin (%)",
  "columnGapPx": "Column Gap (px)",
  "maxColumnCount": "Maximum Number of Columns",
  "maxInlineSize": "Maximum Column Width (px)",
  "maxBlockSize": "Maximum Column Height (px)",
  "overrideFont": "Override Book Font",
  "useBookLayout": "Use Book Layout",
  "fullJustification": "Full Justification",
  "hyphenation": "Hyphenation",
  "scrolled": "Scrolled Mode",
  "defaultFont": "Font Category",
  "serifFont": "Serif Font",
  "sansSerifFont": "Sans-Serif Font",
  "monospaceFont": "Monospace Font",
  "defaultCJKFont": "CJK Font",
  "manageFonts": "Manage Fonts",
  "fontSizes": "Font Size",
  "preferredFont": "Preferred Font",
  "paragraph": "Paragraph",
  "page": "Page",
  "fonts": "Fonts",
  "layout": "Layout",
  "serif": "Serif Font",
  "sans-serif": "Sans-Serif Font",
  "monospace": "Monospace Font",
  "bookFont": "Use Book Font",
  library: 'Bookshelf', toc: 'Contents', color: 'Theme', progress: 'Reading progress', font: 'Font & Layout', menu: 'View', close: 'Close',
  previous: 'Previous page', next: 'Next page', previousSection: 'Previous section', nextSection: 'Next section',
  historyBack: 'Go back', historyForward: 'Go forward', decrease: 'Decrease font size', increase: 'Increase font size',
  light: 'Light', sepia: 'Sepia', dark: 'Dark',
  settings: 'Settings', upload: 'Send progress', reconcile: 'Check remote', status: 'Offline ready',
  auto: 'System', themeMode: 'Theme mode', themeColor: 'Color scheme', scopeReader: 'Reader',
  default: 'Default', gray: 'Gray', grass: 'Grass', cherry: 'Cherry', sky: 'Sky', solarized: 'Solarized', gruvbox: 'Gruvbox', nord: 'Nord', contrast: 'Contrast', sunset: 'Sunset'
};

export function createChrome(host: ChromeHost) {
  const style = document.createElement('style'); style.textContent = `${layout}\n${motion}`; document.head.append(style);
  const root = document.createElement('div'); root.id = 'reader-chrome'; root.hidden = true; document.body.append(root);
  let labels = { ...english }, visible = true, panel = '', title = '', toc: TocItem[] = [], fontTab = 'fonts';
  let progress = 0, chapter = '', syncEnabled = false, busy = false;
  const text = (value: string) => value.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
  const button = (action: string, extra = '') => `<button class="icon-button ${extra}" type="button" data-action="${action}" aria-label="${text(labels[action])}" title="${text(labels[action])}"><svg viewBox="0 0 24 24" aria-hidden="true">${icons[action]}</svg></button>`;
  const navigation = () => ['previousSection', 'previous', 'historyBack', 'historyForward', 'next', 'nextSection'].map(a => button(a)).join('');
  const range = () => `<input type="range" min="0" max="100" step="0.1" value="${progress}" aria-label="${text(labels.progress)}" data-progress>`;
  // Each panel is a separate extension point, matching Readest's footer panels.
  const numericLimits: Record<string, [number, number, number]> = {"fontSize":[1,120,1],"minimumFontSize":[1,120,1],"fontWeight":[100,900,100],"lineHeight":[1,3,0.1],"paragraphMargin":[0,4,0.1],"wordSpacing":[-4,8,0.5],"letterSpacing":[-2,4,0.5],"textIndent":[-2,4,1],"marginTopPx":[0,144,4],"marginBottomPx":[0,144,4],"marginLeftPx":[0,144,4],"marginRightPx":[0,144,4],"gapPercent":[0,30,1],"columnGapPx":[0,200,4],"maxColumnCount":[1,4,1],"maxInlineSize":[200,9999,50],"maxBlockSize":[400,9999,50]};
  const numericRow = (key: keyof Appearance) => {
    const [min, max, step] = numericLimits[key];
    return `<div class="settings-row"><label for="setting-${key}">${text(labels[key])}</label><input id="setting-${key}" data-setting="${key}" type="number" min="${min}" max="${max}" step="${step}" aria-label="${text(labels[key])}"></div>`;
  };
  const flagRow = (key: keyof Appearance) => `<div class="settings-row"><label for="setting-${key}">${text(labels[key])}</label><input id="setting-${key}" type="checkbox" role="switch" data-setting="${key}" aria-label="${text(labels[key])}"></div>`;
  const fontRow = (key: keyof Appearance, fallback: string) => {
    const options = key === 'defaultFont' ? ['serif', 'sans-serif'] : [...new Set([fallback, ...host.getFonts().filter(f => !Object.values(builtinFontFamilies).includes(f.family)).map(f => f.family)])];
    const selected = String(host.getSettings()[key]);
    if (!options.includes(selected)) options.push(selected);
    const family = (value: string) => text(resolvedFontFamily(value || 'system-ui', host.getFonts()));
    const label = (value: string) => text(labels[value] || (value ? value : labels.bookFont));
    return `<div class="settings-row font-row"><label id="label-${key}" for="setting-${key}">${text(labels[key])}</label><div class="font-picker">
      <button id="setting-${key}" type="button" data-font-picker="${key}" aria-labelledby="label-${key} setting-${key}" aria-haspopup="listbox" aria-expanded="false" aria-controls="options-${key}"><span data-font-label style="font-family:${family(selected)}">${label(selected)}</span><span aria-hidden="true">▾</span></button>
      <div id="options-${key}" class="font-options" role="listbox" aria-labelledby="label-${key}" hidden>${options.map(value => `<button type="button" role="option" tabindex="-1" data-font-setting="${key}" data-font-value="${text(value)}" aria-selected="${value === selected}" style="font-family:${family(value)}">${label(value)}</button>`).join('')}</div>
    </div></div>`;
  };
  const boxed = (label: string, rows: string) => `<h3 class="setting-section">${text(labels[label])}</h3><div class="boxed-settings">${rows}</div>`;
  const fontPanel = () => `<div class="font-tabs" role="tablist">${['fonts', 'layout'].map(tab => `<button type="button" role="tab" data-font-tab="${tab}" aria-selected="${fontTab === tab}">${text(labels[tab])}</button>`).join('')}</div>
    <div data-font-group="fonts" ${fontTab !== 'fonts' ? 'hidden' : ''}>
    <div class="boxed-settings">${flagRow('overrideFont')}</div>
    ${boxed('fontSizes', `<div class="settings-row"><label for="setting-fontSize">${text(labels.fontSize)}</label><div class="number-stepper">${button('decrease')}<input id="setting-fontSize" data-setting="fontSize" type="number" min="1" max="120" step="1" aria-label="${text(labels.fontSize)}"><output data-font-size class="visually-hidden"></output>${button('increase')}</div></div>${numericRow('minimumFontSize')}`)}
    ${boxed('fontWeight', numericRow('fontWeight'))}
    ${boxed('preferredFont', fontRow('defaultFont', 'serif') + fontRow('serifFont', 'serif') + fontRow('sansSerifFont', 'sans-serif') + fontRow('monospaceFont', 'monospace') + fontRow('defaultCJKFont', ''))}
    <button type="button" class="manage-fonts" data-action="settings">${text(labels.manageFonts)}</button></div>
    <div data-font-group="layout" ${fontTab !== 'layout' ? 'hidden' : ''}>
    <div class="boxed-settings">${flagRow('scrolled')}</div>
    ${boxed('paragraph', flagRow('useBookLayout') + numericRow('paragraphMargin') + `<div class="settings-row"><label for="reader-line-height">${text(labels.lineHeight)}</label><output data-line-height></output></div><input id="reader-line-height" data-setting="lineHeight" type="range" min="1" max="3" step=".1" aria-label="${text(labels.lineHeight)}">` + numericRow('wordSpacing') + numericRow('letterSpacing') + numericRow('textIndent') + flagRow('fullJustification') + flagRow('hyphenation'))}
    ${boxed('page', numericRow('marginTopPx') + numericRow('marginBottomPx') + numericRow('marginLeftPx') + numericRow('marginRightPx') + numericRow('gapPercent') + numericRow('columnGapPx') + numericRow('maxColumnCount') + numericRow('maxInlineSize') + numericRow('maxBlockSize'))}</div>`;

  const panels: Record<string, () => string> = {
    progress: () => `<div class="progress-caption"><span class="chapter-label">${text(chapter || title)}</span><output class="percentage">${Math.round(progress)}%</output></div>${range()}<div class="navigation-actions">${navigation()}</div>`,
    font: fontPanel,
    color: () => `<div class="settings-row"><label>${text(labels.themeMode)}</label><div class="theme-modes" role="radiogroup" aria-label="${text(labels.themeMode)}">${['auto', 'light', 'dark'].map(m => `<button class="icon-button" type="button" role="radio" data-mode="${m}" aria-label="${text(labels[m])}" title="${text(labels[m])}"><svg viewBox="0 0 24 24" aria-hidden="true">${icons[m]}</svg></button>`).join('')}</div></div><div class="theme-color-label">${text(labels.themeColor)}</div><div class="theme-options" role="group" aria-label="${text(labels.themeColor)}">${BUILTIN_THEMES.map(t => `<button class="theme-option" type="button" data-theme="${t.name}" aria-label="${text(labels[t.name] || t.label)}"><span class="theme-sample">Aa</span><span class="theme-name">${text(labels[t.name] || t.label)}</span></button>`).join('')}</div>`,
    toc: () => toc.map((item, i) => `<button class="toc-item" type="button" data-toc="${i}" style="padding-inline-start:${12 + item.depth * 16}px">${text(item.label)}</button>`).join('')
  };
  function render() {
    root.innerHTML = `<header class="header-bar" aria-label="${text(title)}" aria-hidden="${!visible}">${button('library')}${button('toc', 'desktop-only')}<div class="header-title">${text(title)}</div><div class="header-end">${button('color', 'desktop-only')}${button('font', 'desktop-only')}${button('menu')}</div></header>
      <footer class="footer-bar" aria-hidden="${!visible}">
        ${Object.keys(panels).map(key => `<section class="footer-panel" data-panel="${key}" aria-label="${text(labels[key])}" aria-hidden="${panel !== key}"><div class="panel-heading"><span>${text(labels[key])}</span>${button('close')}</div><div class="panel-scroll"><div class="panel-content">${panels[key]()}</div></div></section>`).join('')}
        <nav class="mobile-tools" aria-label="${text(labels.menu)}">${['toc', 'color', 'progress', 'font'].map(a => button(a)).join('')}</nav>
        <nav class="desktop-tools" aria-label="${text(labels.progress)}">${button('previousSection')}${button('previous')}${button('historyBack')}${button('historyForward')}<output class="percentage">${Math.round(progress)}%</output>${range()}${button('next')}${button('nextSection')}</nav>
      </footer><div class="view-menu" hidden>${['settings', 'upload', 'reconcile'].map(a => `<button type="button" class="menu-action" data-action="${a}">${text(labels[a])}</button>`).join('')}<div class="sync-status" role="status"></div></div><div class="panel-backdrop" hidden></div>`;
    syncVisibility(); updateAppearance(); updatePosition();
  }
  function syncVisibility() {
    for (const bar of root.querySelectorAll<HTMLElement>('.header-bar,.footer-bar')) {
      bar.setAttribute('aria-hidden', String(!visible)); (bar as any).inert = !visible;
    }
    for (const section of root.querySelectorAll<HTMLElement>('[data-panel]')) {
      const active = visible && section.dataset.panel === panel;
      section.setAttribute('aria-hidden', String(!active)); (section as any).inert = !active;
      if (!active) {
        for (const list of section.querySelectorAll<HTMLElement>('.font-options')) list.hidden = true;
        for (const picker of section.querySelectorAll<HTMLElement>('[data-font-picker]')) picker.setAttribute('aria-expanded', 'false');
      }
    }
    for (const item of root.querySelectorAll<HTMLElement>('[data-action]')) {
      if (panels[item.dataset.action!]) item.setAttribute('aria-expanded', String(panel === item.dataset.action));
      if (item.dataset.action === 'menu') item.setAttribute('aria-expanded', String(visible && !root.querySelector<HTMLElement>('.view-menu')!.hidden));
    }
    if (!visible) { root.querySelector<HTMLElement>('.view-menu')!.hidden = true; panel = ''; }
    root.querySelector<HTMLElement>('.panel-backdrop')!.hidden = !hasOverlay();
    if (!visible && root.contains(document.activeElement)) (document.activeElement as HTMLElement).blur();
  }
  function setVisible(value: boolean) { visible = value; if (!visible) panel = ''; syncVisibility(); }
  function hasOverlay() { return !root.hidden && (Boolean(panel) || !root.querySelector<HTMLElement>('.view-menu')!.hidden); }
  function dismiss() {
    if (root.contains(document.activeElement)) (document.activeElement as HTMLElement).blur();
    panel = ''; root.querySelector<HTMLElement>('.view-menu')!.hidden = true;
    syncVisibility();
  }
  function updatePosition() {
    for (const range of root.querySelectorAll<HTMLInputElement>('[data-progress]')) if (document.activeElement !== range) range.value = String(progress);
    for (const value of root.querySelectorAll<HTMLElement>('.percentage')) value.textContent = `${Math.round(progress)}%`;
    root.querySelector<HTMLElement>('.chapter-label')!.textContent = chapter || title;
    for (const action of ['historyBack', 'historyForward']) for (const b of root.querySelectorAll<HTMLButtonElement>(`[data-action='${action}']`)) b.disabled = !host.getView()?.history?.[action === 'historyBack' ? 'canGoBack' : 'canGoForward'];
  }
  function updateAppearance(settings = host.getSettings()) {
    const primary = settings.defaultFont === 'sans-serif' ? resolvedFontFamily(settings.sansSerifFont, host.getFonts(), 'sans-serif') : resolvedFontFamily(settings.serifFont, host.getFonts());
    const family = settings.defaultCJKFont ? `${cssFamily(settings.defaultCJKFont)}, ${primary}` : primary;
    root.style.fontFamily = family;
    for (const picker of root.querySelectorAll<HTMLButtonElement>('[data-font-picker]')) {
      const key = picker.dataset.fontPicker as keyof Appearance, value = String(settings[key]);
      const label = picker.querySelector<HTMLElement>('[data-font-label]')!;
      label.textContent = labels[value] || value || labels.bookFont;
      label.style.fontFamily = resolvedFontFamily(value || 'system-ui', host.getFonts());
      for (const option of root.querySelectorAll<HTMLElement>(`[data-font-setting="${key}"]`)) option.setAttribute('aria-selected', String(option.dataset.fontValue === value));
    }
    const dark = themeIsDark(settings.themeMode, host.getSystemDark());
    const theme = palette(settings.themeColor, dark);
    const colors = [theme.bg, theme.inset, theme.fg, theme.muted, theme.line];
    ['surface', 'inset', 'fg', 'muted', 'line'].forEach((name, i) => root.style.setProperty(`--reader-${name}`, colors[i]));
    root.querySelector<HTMLElement>('[data-font-size]')!.textContent = String(settings.fontSize);
    root.querySelector<HTMLElement>('[data-line-height]')!.textContent = settings.lineHeight.toFixed(1);
    root.querySelector<HTMLInputElement>('#reader-line-height')!.value = String(settings.lineHeight);
    for (const input of root.querySelectorAll<HTMLInputElement>('[data-setting]')) {
      const key = input.dataset.setting as keyof Appearance;
      if (input instanceof HTMLInputElement && input.type === 'checkbox') input.checked = settings[key] as boolean;
      else if (document.activeElement !== input) input.value = String(settings[key]);
      input.disabled = settings.useBookLayout && ['paragraphMargin', 'lineHeight', 'wordSpacing', 'letterSpacing', 'textIndent', 'fullJustification', 'hyphenation'].includes(key) || settings.scrolled && ['columnGapPx', 'maxColumnCount'].includes(key);
    }
    root.querySelector<HTMLInputElement>('[data-setting="fontSize"]')!.min = String(settings.minimumFontSize);
    for (const b of root.querySelectorAll<HTMLElement>('[data-theme]')) {
      const colors = palette(b.dataset.theme!, dark);
      b.style.background = colors.bg; b.style.color = colors.fg;
      b.setAttribute('aria-pressed', String(settings.themeColor === b.dataset.theme));
    }
    for (const b of root.querySelectorAll<HTMLElement>('[data-mode]')) b.setAttribute('aria-checked', String(settings.themeMode === b.dataset.mode));
    (root.querySelector('[data-action="decrease"]') as HTMLButtonElement).disabled = settings.fontSize <= settings.minimumFontSize;
    (root.querySelector('[data-action="increase"]') as HTMLButtonElement).disabled = settings.fontSize >= 120;
  }
  function appearance(settings: Appearance) {
    // Reflect dependent controls immediately while a selected font is loading.
    updateAppearance(settings);
    host.command({ type: 'appearance', settings }); host.emit('appearanceChanged', { settings });
  }
  root.addEventListener('click', event => {
    const element = event.target as Element;
    if (hasOverlay() && !element.closest(`[data-panel="${panel}"][aria-hidden="false"], .view-menu:not([hidden])`)) { event.stopPropagation(); dismiss(); return; }
    const target = (event.target as Element).closest<HTMLButtonElement>('button');
    if (!target || target.disabled) return;
    const action = target.dataset.action;
    if (target.dataset.fontPicker) {
      const options = root.querySelector<HTMLElement>(`#options-${target.dataset.fontPicker}`)!;
      const opening = options.hidden;
      for (const list of root.querySelectorAll<HTMLElement>('.font-options')) list.hidden = true;
      for (const picker of root.querySelectorAll<HTMLElement>('[data-font-picker]')) picker.setAttribute('aria-expanded', 'false');
      options.hidden = !opening; target.setAttribute('aria-expanded', String(opening));
      if (opening) options.querySelector<HTMLElement>('[aria-selected="true"]')?.focus();
      return;
    }
    if (target.dataset.fontSetting) {
      const key = target.dataset.fontSetting as keyof Appearance;
      const settings = { ...host.getSettings(), [key]: target.dataset.fontValue, overrideFont: true };
      if (key === 'serifFont') settings.defaultFont = 'serif';
      if (key === 'sansSerifFont') settings.defaultFont = 'sans-serif';
      target.closest<HTMLElement>('.font-options')!.hidden = true;
      const picker = root.querySelector<HTMLElement>(`[data-font-picker="${key}"]`)!;
      picker.setAttribute('aria-expanded', 'false'); picker.focus();
      appearance(settings); return;
    }
    if (target.dataset.fontTab) { fontTab = target.dataset.fontTab; render(); return; }
    if (target.dataset.toc !== undefined) { host.command({ type: 'navigate', href: toc[Number(target.dataset.toc)].href }); panel = ''; syncVisibility(); }
    else if (target.dataset.theme) appearance({ ...host.getSettings(), themeColor: target.dataset.theme });
    else if (target.dataset.mode) appearance({ ...host.getSettings(), themeMode: target.dataset.mode });
    else if (action === 'menu') { const menu = root.querySelector<HTMLElement>('.view-menu')!; panel = ''; menu.hidden = !menu.hidden; target.setAttribute('aria-expanded', String(!menu.hidden)); syncVisibility(); }
    else if (action && panels[action]) { panel = panel === action ? '' : action; root.querySelector<HTMLElement>('.view-menu')!.hidden = true; syncVisibility(); }
    else if (action === 'close') dismiss();
    else if (action === 'decrease' || action === 'increase') appearance({ ...host.getSettings(), fontSize: Math.max(host.getSettings().minimumFontSize, Math.min(120, host.getSettings().fontSize + (action === 'increase' ? 2 : -2))) });
    else if (['library', 'settings', 'upload', 'reconcile'].includes(action!)) { dismiss(); host.emit('readerAction', { action }); }
    else if (action) host.command({ type: action });
  });
  root.addEventListener('keydown', event => {
    const target = event.target as HTMLElement;
    const options = target.closest('.font-options');
    if (!options || !['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const items = Array.from(options.querySelectorAll<HTMLElement>('[role="option"]'));
    const index = items.indexOf(target);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[next]?.focus();
  });
  root.addEventListener('input', event => {
    const target = event.target as HTMLInputElement;
    if (target.matches('[data-progress]')) for (const output of root.querySelectorAll<HTMLElement>('.percentage')) output.textContent = `${Math.round(Number(target.value))}%`;
    if (target.id === 'reader-line-height') root.querySelector<HTMLElement>('[data-line-height]')!.textContent = Number(target.value).toFixed(1);
  });
  root.addEventListener('change', event => {
    const target = event.target as HTMLInputElement;
    if (target.matches('[data-progress]')) host.command({ type: 'fraction', percentage: Number(target.value) / 100 });
    else if (target.dataset.setting) {
      const key = target.dataset.setting as keyof Appearance;
      const settings = { ...host.getSettings() };
      if (target.type === 'checkbox') (settings as any)[key] = target.checked;
      else if (numericLimits[key]) {
        const value = Number(target.value), [min, max] = numericLimits[key];
        if (!target.value.trim() || !Number.isFinite(value) || value < min || value > max || key === 'maxColumnCount' && !Number.isInteger(value)) { updateAppearance(); return; }
        (settings as any)[key] = value;
        if (key === 'minimumFontSize' || key === 'fontSize') settings.fontSize = Math.max(settings.fontSize, settings.minimumFontSize);
      } else return;
      appearance(settings);
    }
  });
  document.addEventListener('keydown', event => {
    if (root.hidden) return;
    if (event.key === 'Escape') { event.preventDefault(); back(); }
    else if (!hasOverlay() && !root.contains(document.activeElement) && ['ArrowLeft', 'ArrowRight'].includes(event.key)) { event.preventDefault(); host.command({ type: event.key === 'ArrowLeft' ? 'previous' : 'next' }); }
  });
  function back() {
    const menu = root.querySelector<HTMLElement>('.view-menu')!;
    const options = root.querySelector<HTMLElement>('.font-options:not([hidden])');
    if (options) { options.hidden = true; const picker = root.querySelector<HTMLElement>(`[aria-controls="${options.id}"]`)!; picker.setAttribute('aria-expanded', 'false'); picker.focus(); }
    else if (!menu.hidden) { menu.hidden = true; syncVisibility(); }
    else if (panel) dismiss();
    else host.emit('readerAction', { action: 'library' });
  }
  render();
  return {
    open(bookTitle: string, items: TocItem[]) { title = bookTitle; toc = items; panel = ''; visible = true; render(); root.hidden = false; syncVisibility(); },
    close() { root.hidden = true; panel = ''; },
    toggle() { setVisible(!visible); host.emit('toggleControls'); },
    back,
    hasOverlay,
    appearance: updateAppearance,
    fontsChanged: render,
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
