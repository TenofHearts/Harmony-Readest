import { ReaderSettings } from './Models';

export function fontName(value: string): boolean {
  return typeof value === 'string' && value.length <= 128 && !/[\x00-\x1f]/.test(value);
}

export function numericSetting(settings: ReaderSettings, key: string): number {
  switch (key) {
    case 'fontSize': return settings.fontSize;
    case 'minimumFontSize': return settings.minimumFontSize;
    case 'fontWeight': return settings.fontWeight;
    case 'lineHeight': return settings.lineHeight;
    case 'paragraphMargin': return settings.paragraphMargin;
    case 'wordSpacing': return settings.wordSpacing;
    case 'letterSpacing': return settings.letterSpacing;
    case 'textIndent': return settings.textIndent;
    case 'marginTopPx': return settings.marginTopPx;
    case 'marginBottomPx': return settings.marginBottomPx;
    case 'marginLeftPx': return settings.marginLeftPx;
    case 'marginRightPx': return settings.marginRightPx;
    case 'gapPercent': return settings.gapPercent;
    case 'columnGapPx': return settings.columnGapPx;
    case 'maxColumnCount': return settings.maxColumnCount;
    case 'maxInlineSize': return settings.maxInlineSize;
    case 'maxBlockSize': return settings.maxBlockSize;
    default: return 0;
  }
}

export function setNumericSetting(settings: ReaderSettings, key: string, value: number): void {
  switch (key) {
    case 'fontSize': if (Number.isFinite(value) && value >= 1 && value <= 120) settings.fontSize = value; break;
    case 'minimumFontSize': if (Number.isFinite(value) && value >= 1 && value <= 120) settings.minimumFontSize = value; break;
    case 'fontWeight': if (Number.isInteger(value) && value >= 100 && value <= 900) settings.fontWeight = value; break;
    case 'lineHeight': if (Number.isFinite(value) && value >= 1 && value <= 3) settings.lineHeight = value; break;
    case 'paragraphMargin': if (Number.isFinite(value) && value >= 0 && value <= 4) settings.paragraphMargin = value; break;
    case 'wordSpacing': if (Number.isFinite(value) && value >= -4 && value <= 8) settings.wordSpacing = value; break;
    case 'letterSpacing': if (Number.isFinite(value) && value >= -2 && value <= 4) settings.letterSpacing = value; break;
    case 'textIndent': if (Number.isFinite(value) && value >= -2 && value <= 4) settings.textIndent = value; break;
    case 'marginTopPx': if (Number.isFinite(value) && value >= 0 && value <= 144) settings.marginTopPx = value; break;
    case 'marginBottomPx': if (Number.isFinite(value) && value >= 0 && value <= 144) settings.marginBottomPx = value; break;
    case 'marginLeftPx': if (Number.isFinite(value) && value >= 0 && value <= 144) settings.marginLeftPx = value; break;
    case 'marginRightPx': if (Number.isFinite(value) && value >= 0 && value <= 144) settings.marginRightPx = value; break;
    case 'gapPercent': if (Number.isFinite(value) && value >= 0 && value <= 30) settings.gapPercent = value; break;
    case 'columnGapPx': if (Number.isFinite(value) && value >= 0 && value <= 200) settings.columnGapPx = value; break;
    case 'maxColumnCount': if (Number.isInteger(value) && value >= 1 && value <= 4) settings.maxColumnCount = value; break;
    case 'maxInlineSize': if (Number.isFinite(value) && value >= 200 && value <= 9999) settings.maxInlineSize = value; break;
    case 'maxBlockSize': if (Number.isFinite(value) && value >= 400 && value <= 9999) settings.maxBlockSize = value; break;
  }
}

export function validTypography(settings: ReaderSettings): boolean {
  return Number.isFinite(settings.fontSize) && settings.fontSize >= 1 && settings.fontSize <= 120 &&
    Number.isFinite(settings.minimumFontSize) && settings.minimumFontSize >= 1 && settings.minimumFontSize <= 120 &&
    Number.isFinite(settings.fontWeight) && settings.fontWeight >= 100 && settings.fontWeight <= 900 &&
    Number.isFinite(settings.lineHeight) && settings.lineHeight >= 1 && settings.lineHeight <= 3 &&
    Number.isFinite(settings.paragraphMargin) && settings.paragraphMargin >= 0 && settings.paragraphMargin <= 4 &&
    Number.isFinite(settings.wordSpacing) && settings.wordSpacing >= -4 && settings.wordSpacing <= 8 &&
    Number.isFinite(settings.letterSpacing) && settings.letterSpacing >= -2 && settings.letterSpacing <= 4 &&
    Number.isFinite(settings.textIndent) && settings.textIndent >= -2 && settings.textIndent <= 4 &&
    Number.isFinite(settings.marginTopPx) && settings.marginTopPx >= 0 && settings.marginTopPx <= 144 &&
    Number.isFinite(settings.marginBottomPx) && settings.marginBottomPx >= 0 && settings.marginBottomPx <= 144 &&
    Number.isFinite(settings.marginLeftPx) && settings.marginLeftPx >= 0 && settings.marginLeftPx <= 144 &&
    Number.isFinite(settings.marginRightPx) && settings.marginRightPx >= 0 && settings.marginRightPx <= 144 &&
    Number.isFinite(settings.gapPercent) && settings.gapPercent >= 0 && settings.gapPercent <= 30 &&
    Number.isFinite(settings.columnGapPx) && settings.columnGapPx >= 0 && settings.columnGapPx <= 200 &&
    Number.isFinite(settings.maxColumnCount) && settings.maxColumnCount >= 1 && settings.maxColumnCount <= 4 &&
    Number.isFinite(settings.maxInlineSize) && settings.maxInlineSize >= 200 && settings.maxInlineSize <= 9999 &&
    Number.isFinite(settings.maxBlockSize) && settings.maxBlockSize >= 400 && settings.maxBlockSize <= 9999 &&
    settings.minimumFontSize <= settings.fontSize && Number.isInteger(settings.maxColumnCount) &&
    Number.isInteger(settings.fontWeight) && ['serif', 'sans-serif'].includes(settings.defaultFont) &&
    fontName(settings.serifFont) && fontName(settings.sansSerifFont) && fontName(settings.monospaceFont) && fontName(settings.defaultCJKFont) &&
    typeof settings.overrideFont === 'boolean' && typeof settings.useBookLayout === 'boolean' && typeof settings.fullJustification === 'boolean' && typeof settings.hyphenation === 'boolean' && typeof settings.scrolled === 'boolean';
}
