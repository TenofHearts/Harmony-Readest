import { ReaderSettings, ThemeSettings } from './Models';
import { isThemeColor, isThemeMode } from './Themes';

export interface StoredAppearance {
  fontSize?: number;
  lineHeight?: number;
  theme?: string;
  themeMode?: string;
  themeColor?: string;
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
  if (value.fontSize !== undefined && Number.isFinite(value.fontSize) && value.fontSize >= 12 && value.fontSize <= 40) settings.fontSize = value.fontSize;
  if (value.lineHeight !== undefined && Number.isFinite(value.lineHeight) && value.lineHeight >= 1.2 && value.lineHeight <= 2.4) settings.lineHeight = value.lineHeight;
  return settings;
}
