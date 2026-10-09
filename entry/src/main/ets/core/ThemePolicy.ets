import { ReaderSettings, ThemeSettings } from './Models';
import { isThemeColor, isThemeMode } from './Themes';
import { fontName } from './TypographyPolicy';

export interface StoredAppearance {
  fontSize?: number;
  lineHeight?: number;
  minimumFontSize?: number;
  fontWeight?: number;
  paragraphMargin?: number;
  wordSpacing?: number;
  letterSpacing?: number;
  textIndent?: number;
  marginTopPx?: number;
  marginBottomPx?: number;
  marginLeftPx?: number;
  marginRightPx?: number;
  gapPercent?: number;
  columnGapPx?: number;
  maxColumnCount?: number;
  maxInlineSize?: number;
  maxBlockSize?: number;
  defaultFont?: string;
  serifFont?: string;
  sansSerifFont?: string;
  monospaceFont?: string;
  defaultCJKFont?: string;
  overrideFont?: boolean;
  useBookLayout?: boolean;
  fullJustification?: boolean;
  hyphenation?: boolean;
  scrolled?: boolean;
  theme?: string;
  themeMode?: string;
  themeColor?: string;
}

export function validAppearanceEvent(value: StoredAppearance): boolean {
  if (value.fontSize !== undefined && (!Number.isFinite(value.fontSize) || value.fontSize < 1 || value.fontSize > 120)) return false;
  if (value.minimumFontSize !== undefined && (!Number.isFinite(value.minimumFontSize) || value.minimumFontSize < 1 || value.minimumFontSize > 120)) return false;
  if (value.fontWeight !== undefined && (!Number.isFinite(value.fontWeight) || value.fontWeight < 100 || value.fontWeight > 900 || !Number.isInteger(value.fontWeight))) return false;
  if (value.lineHeight !== undefined && (!Number.isFinite(value.lineHeight) || value.lineHeight < 1 || value.lineHeight > 3)) return false;
  if (value.paragraphMargin !== undefined && (!Number.isFinite(value.paragraphMargin) || value.paragraphMargin < 0 || value.paragraphMargin > 4)) return false;
  if (value.wordSpacing !== undefined && (!Number.isFinite(value.wordSpacing) || value.wordSpacing < -4 || value.wordSpacing > 8)) return false;
  if (value.letterSpacing !== undefined && (!Number.isFinite(value.letterSpacing) || value.letterSpacing < -2 || value.letterSpacing > 4)) return false;
  if (value.textIndent !== undefined && (!Number.isFinite(value.textIndent) || value.textIndent < -2 || value.textIndent > 4)) return false;
  if (value.marginTopPx !== undefined && (!Number.isFinite(value.marginTopPx) || value.marginTopPx < 0 || value.marginTopPx > 144)) return false;
  if (value.marginBottomPx !== undefined && (!Number.isFinite(value.marginBottomPx) || value.marginBottomPx < 0 || value.marginBottomPx > 144)) return false;
  if (value.marginLeftPx !== undefined && (!Number.isFinite(value.marginLeftPx) || value.marginLeftPx < 0 || value.marginLeftPx > 144)) return false;
  if (value.marginRightPx !== undefined && (!Number.isFinite(value.marginRightPx) || value.marginRightPx < 0 || value.marginRightPx > 144)) return false;
  if (value.gapPercent !== undefined && (!Number.isFinite(value.gapPercent) || value.gapPercent < 0 || value.gapPercent > 30)) return false;
  if (value.columnGapPx !== undefined && (!Number.isFinite(value.columnGapPx) || value.columnGapPx < 0 || value.columnGapPx > 200)) return false;
  if (value.maxColumnCount !== undefined && (!Number.isFinite(value.maxColumnCount) || value.maxColumnCount < 1 || value.maxColumnCount > 4 || !Number.isInteger(value.maxColumnCount))) return false;
  if (value.maxInlineSize !== undefined && (!Number.isFinite(value.maxInlineSize) || value.maxInlineSize < 200 || value.maxInlineSize > 9999)) return false;
  if (value.maxBlockSize !== undefined && (!Number.isFinite(value.maxBlockSize) || value.maxBlockSize < 400 || value.maxBlockSize > 9999)) return false;
  if (value.defaultFont !== undefined && !fontName(value.defaultFont)) return false;
  if (value.serifFont !== undefined && !fontName(value.serifFont)) return false;
  if (value.sansSerifFont !== undefined && !fontName(value.sansSerifFont)) return false;
  if (value.monospaceFont !== undefined && !fontName(value.monospaceFont)) return false;
  if (value.defaultCJKFont !== undefined && !fontName(value.defaultCJKFont)) return false;
  if (value.overrideFont !== undefined && typeof value.overrideFont !== 'boolean') return false;
  if (value.useBookLayout !== undefined && typeof value.useBookLayout !== 'boolean') return false;
  if (value.fullJustification !== undefined && typeof value.fullJustification !== 'boolean') return false;
  if (value.hyphenation !== undefined && typeof value.hyphenation !== 'boolean') return false;
  if (value.scrolled !== undefined && typeof value.scrolled !== 'boolean') return false;
  if (value.defaultFont !== undefined && !['serif', 'sans-serif'].includes(value.defaultFont)) return false;
  return true;
}


// Data migration only: old Light/Sepia/Dark represented both mode and color.
export function migrateTheme(value: StoredAppearance): ThemeSettings {
  const settings = new ThemeSettings();
  if (value.themeMode && isThemeMode(value.themeMode)) settings.themeMode = value.themeMode;
  else if (value.theme === 'light' || value.theme === 'sepia') settings.themeMode = 'light';
  else if (value.theme === 'dark') settings.themeMode = 'dark';
  if (value.themeColor && isThemeColor(value.themeColor)) settings.themeColor = value.themeColor;
  else if (value.theme === 'sepia') settings.themeColor = 'sepia';
  return settings;
}

export function migrateAppearance(value: StoredAppearance): ReaderSettings {
  const theme = migrateTheme(value); const settings = new ReaderSettings();
  settings.themeColor = theme.themeColor; settings.themeMode = theme.themeMode;
  if (value.fontSize !== undefined && Number.isFinite(value.fontSize) && value.fontSize >= 1 && value.fontSize <= 120) settings.fontSize = value.fontSize;
  if (value.minimumFontSize !== undefined && Number.isFinite(value.minimumFontSize) && value.minimumFontSize >= 1 && value.minimumFontSize <= 120) settings.minimumFontSize = value.minimumFontSize;
  if (value.fontWeight !== undefined && Number.isFinite(value.fontWeight) && value.fontWeight >= 100 && value.fontWeight <= 900 && Number.isInteger(value.fontWeight)) settings.fontWeight = value.fontWeight;
  if (value.lineHeight !== undefined && Number.isFinite(value.lineHeight) && value.lineHeight >= 1 && value.lineHeight <= 3) settings.lineHeight = value.lineHeight;
  if (value.paragraphMargin !== undefined && Number.isFinite(value.paragraphMargin) && value.paragraphMargin >= 0 && value.paragraphMargin <= 4) settings.paragraphMargin = value.paragraphMargin;
  if (value.wordSpacing !== undefined && Number.isFinite(value.wordSpacing) && value.wordSpacing >= -4 && value.wordSpacing <= 8) settings.wordSpacing = value.wordSpacing;
  if (value.letterSpacing !== undefined && Number.isFinite(value.letterSpacing) && value.letterSpacing >= -2 && value.letterSpacing <= 4) settings.letterSpacing = value.letterSpacing;
  if (value.textIndent !== undefined && Number.isFinite(value.textIndent) && value.textIndent >= -2 && value.textIndent <= 4) settings.textIndent = value.textIndent;
  if (value.marginTopPx !== undefined && Number.isFinite(value.marginTopPx) && value.marginTopPx >= 0 && value.marginTopPx <= 144) settings.marginTopPx = value.marginTopPx;
  if (value.marginBottomPx !== undefined && Number.isFinite(value.marginBottomPx) && value.marginBottomPx >= 0 && value.marginBottomPx <= 144) settings.marginBottomPx = value.marginBottomPx;
  if (value.marginLeftPx !== undefined && Number.isFinite(value.marginLeftPx) && value.marginLeftPx >= 0 && value.marginLeftPx <= 144) settings.marginLeftPx = value.marginLeftPx;
  if (value.marginRightPx !== undefined && Number.isFinite(value.marginRightPx) && value.marginRightPx >= 0 && value.marginRightPx <= 144) settings.marginRightPx = value.marginRightPx;
  if (value.gapPercent !== undefined && Number.isFinite(value.gapPercent) && value.gapPercent >= 0 && value.gapPercent <= 30) settings.gapPercent = value.gapPercent;
  if (value.columnGapPx !== undefined && Number.isFinite(value.columnGapPx) && value.columnGapPx >= 0 && value.columnGapPx <= 200) settings.columnGapPx = value.columnGapPx;
  if (value.maxColumnCount !== undefined && Number.isFinite(value.maxColumnCount) && value.maxColumnCount >= 1 && value.maxColumnCount <= 4 && Number.isInteger(value.maxColumnCount)) settings.maxColumnCount = value.maxColumnCount;
  if (value.maxInlineSize !== undefined && Number.isFinite(value.maxInlineSize) && value.maxInlineSize >= 200 && value.maxInlineSize <= 9999) settings.maxInlineSize = value.maxInlineSize;
  if (value.maxBlockSize !== undefined && Number.isFinite(value.maxBlockSize) && value.maxBlockSize >= 400 && value.maxBlockSize <= 9999) settings.maxBlockSize = value.maxBlockSize;
  if (value.serifFont !== undefined && fontName(value.serifFont)) settings.serifFont = value.serifFont;
  if (value.sansSerifFont !== undefined && fontName(value.sansSerifFont)) settings.sansSerifFont = value.sansSerifFont;
  if (value.monospaceFont !== undefined && fontName(value.monospaceFont)) settings.monospaceFont = value.monospaceFont;
  if (value.defaultCJKFont !== undefined && fontName(value.defaultCJKFont)) settings.defaultCJKFont = value.defaultCJKFont;
  if (value.defaultFont && ['serif', 'sans-serif'].includes(value.defaultFont)) settings.defaultFont = value.defaultFont;
  if (typeof value.overrideFont === 'boolean') settings.overrideFont = value.overrideFont;
  if (typeof value.useBookLayout === 'boolean') settings.useBookLayout = value.useBookLayout;
  if (typeof value.fullJustification === 'boolean') settings.fullJustification = value.fullJustification;
  if (typeof value.hyphenation === 'boolean') settings.hyphenation = value.hyphenation;
  if (typeof value.scrolled === 'boolean') settings.scrolled = value.scrolled;
  settings.minimumFontSize = Math.min(settings.minimumFontSize, settings.fontSize);
  return settings;
}
