import { ReaderSettings } from './Models';
import { migrateAppearance, StoredAppearance } from './ThemePolicy';

// Colors and font families are app preferences; book styles retain their layout.
export function readerAppearance(defaults: ReaderSettings, style: ReaderSettings | null): ReaderSettings {
  const settings = migrateAppearance((style || defaults) as StoredAppearance);
  settings.themeMode = defaults.themeMode; settings.themeColor = defaults.themeColor;
  settings.defaultFont = defaults.defaultFont; settings.serifFont = defaults.serifFont;
  settings.sansSerifFont = defaults.sansSerifFont; settings.monospaceFont = defaults.monospaceFont;
  settings.defaultCJKFont = defaults.defaultCJKFont; settings.overrideFont = defaults.overrideFont;
  return settings;
}

export function preferredFont(settings: ReaderSettings): string {
  return settings.defaultFont === 'sans-serif' ? settings.sansSerifFont : settings.serifFont;
}
