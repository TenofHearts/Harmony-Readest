export const defaultTypography = {
  fontSize: 20, minimumFontSize: 8, fontWeight: 400, overrideFont: false,
  defaultFont: 'serif', serifFont: 'serif', sansSerifFont: 'sans-serif', monospaceFont: 'monospace', defaultCJKFont: '',
  lineHeight: 1.7, useBookLayout: false, paragraphMargin: 1, wordSpacing: 0, letterSpacing: 0, textIndent: 0,
  fullJustification: false, hyphenation: true, marginTopPx: 12, marginBottomPx: 12, marginLeftPx: 24, marginRightPx: 24,
  gapPercent: 4, columnGapPx: 32, maxColumnCount: 2, maxInlineSize: 720, maxBlockSize: 9999, scrolled: false,
  themeMode: 'auto', themeColor: 'default'
};
export type Appearance = typeof defaultTypography;
export type ReaderFont = { family: string; style: string; weight: string; url: string };
const quote = (name: string) => JSON.stringify(name).replace(/</g, '\\3c ');
export const cssFamily = (name: string, fallback = 'serif') =>
  ['serif', 'sans-serif', 'monospace', 'system-ui'].includes(name) ? name : `${quote(name)}, ${fallback}`;
export const builtinFontFamilies: Record<string, string> = { serif: 'Readest Serif', 'sans-serif': 'Readest Sans', monospace: 'Readest Mono' };
export function resolvedFontFamily(name: string, faces: ReaderFont[], fallback = 'serif') {
  const alias = builtinFontFamilies[name];
  return cssFamily(alias && faces.some(face => face.family === alias) ? alias : name, fallback);
}

export function fontFaceStyles(faces: ReaderFont[], sources: Map<string, string>, previews = false) {
  return faces.filter(face => previews || sources.has(face.url)).map(face =>
    `@font-face{font-family:${quote(face.family)};src:url(${quote(sources.get(face.url) || face.url)});font-style:${face.style};font-weight:${face.weight};font-display:swap}`).join('\n');
}

export function typographyStyles(s: Appearance, faces: ReaderFont[], sources: Map<string, string>) {
  const cjkFace = faces.find(face => face.family === s.defaultCJKFont);
  const cjkSource = cjkFace ? `url(${quote(sources.get(cjkFace.url) || '')})` : `local(${quote(s.defaultCJKFont)})`;
  const cjk = s.defaultCJKFont ? `'Readest CJK', ` : '';
  const family = s.defaultFont === 'sans-serif' ? resolvedFontFamily(s.sansSerifFont, faces, 'sans-serif') : resolvedFontFamily(s.serifFont, faces);
  return `${fontFaceStyles(faces, sources)}
    ${s.defaultCJKFont ? `@font-face{font-family:'Readest CJK';src:${cjkSource};font-weight:100 900;unicode-range:U+2E80-9FFF,U+AC00-D7AF,U+F900-FAFF,U+FE30-FE4F,U+FF00-FFEF,U+20000-3134F}` : ''}
    html,body{font-size:${s.fontSize}px!important;font-weight:${s.fontWeight};-webkit-text-size-adjust:none;text-size-adjust:none}
    :where(html){font-family:${cjk}${family}${s.overrideFont ? '!important' : ''}}
    ${s.overrideFont ? `html body{font-family:${cjk}${family}!important}
      body *:not(pre,code,kbd,samp):not(pre *,code *,kbd *,samp *){font-family:inherit!important}
      p,li,div,pre,dd{font-size:max(1rem,${s.minimumFontSize}px)!important}` : ''}
    ${s.overrideFont ? 'html body :is(pre,code,kbd,samp)' : ':where(pre,code,kbd,samp)'}{font-family:${resolvedFontFamily(s.monospaceFont, faces, 'monospace')}${s.overrideFont ? '!important' : ''}}
    ${s.useBookLayout ? '' : `body{line-height:${s.lineHeight}!important;word-spacing:${s.wordSpacing}px!important;letter-spacing:${s.letterSpacing}px!important}
      p,div,li,blockquote{line-height:${s.lineHeight}!important;word-spacing:${s.wordSpacing}px!important;letter-spacing:${s.letterSpacing}px!important}
      p{margin-block:${s.paragraphMargin}em!important;text-indent:${s.textIndent}em!important;text-align:${s.fullJustification ? 'justify' : 'start'}!important;hyphens:${s.hyphenation ? 'auto' : 'none'}!important}`}`;
}

// Preserve publisher inline declarations while enforcing only the minimum.
const minimumOverrides = new Map<HTMLElement, { value: string; priority: string }>();
export function restoreMinimumFont() {
  for (const [element, style] of minimumOverrides) {
    if (style.value) element.style.setProperty('font-size', style.value, style.priority);
    else element.style.removeProperty('font-size');
  }
  minimumOverrides.clear();
}
export function enforceMinimumFont(doc: Document, minimum: number) {
  for (const element of doc.querySelectorAll<HTMLElement>('body *')) {
    if (['SCRIPT', 'STYLE', 'SVG', 'PATH', 'IMG'].includes(element.tagName.toUpperCase())) continue;
    const size = parseFloat(doc.defaultView!.getComputedStyle(element).fontSize);
    if (size < minimum) {
      minimumOverrides.set(element, { value: element.style.getPropertyValue('font-size'), priority: element.style.getPropertyPriority('font-size') });
      element.style.setProperty('font-size', `${minimum}px`, 'important');
    }
  }
}
