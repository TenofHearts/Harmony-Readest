import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { loadCore } from './core-loader.mjs';

const { BUILTIN_THEMES, themePalette, themeIsDark, migrateAppearance, migrateTheme, ReaderSettings } = await loadCore();
const result = await build({ stdin: { contents: "export { themes } from './vendor/readest/apps/readest-app/src/styles/themes.ts';", resolveDir: process.cwd() }, bundle: true, write: false, format: 'esm', platform: 'node' });
const { themes } = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

test('every shipped light/dark scheme matches the pinned Readest palette', () => {
  assert.equal(BUILTIN_THEMES.length, 11);
  assert.deepEqual(BUILTIN_THEMES.map(t => t.name), themes.map(t => t.name));
  for (const original of themes) for (const mode of ['light', 'dark']) {
    const actual = themePalette(original.name, mode === 'dark'), expected = original.colors[mode];
    assert.deepEqual([actual.bg, actual.fg, actual.inset, actual.line, actual.primary],
      [expected['base-100'], expected['base-content'], expected['base-200'], expected['base-300'], expected.primary]);
  }
});

test('legacy light, dark and sepia preferences migrate without losing typography', () => {
  for (const [theme, color, mode] of [['light', 'default', 'light'], ['dark', 'default', 'dark'], ['sepia', 'sepia', 'light']]) {
    const settings = migrateAppearance({ theme, fontSize: 24, lineHeight: 1.9 });
    assert.deepEqual({ ...settings }, { ...new ReaderSettings(), themeMode: mode, themeColor: color, fontSize: 24, lineHeight: 1.9 });
    assert.deepEqual({ ...migrateTheme({ theme }) }, { themeMode: mode, themeColor: color });
  }
  assert.deepEqual({ ...migrateTheme({ themeMode: 'auto', themeColor: 'nord', theme: 'sepia' }) }, { themeMode: 'auto', themeColor: 'nord' });
});

test('System follows OS appearance while explicit modes remain fixed', () => {
  assert.equal(themeIsDark('auto', true), true); assert.equal(themeIsDark('auto', false), false);
  assert.equal(themeIsDark('light', true), false); assert.equal(themeIsDark('dark', false), true);
  assert.deepEqual({ ...migrateAppearance({ themeMode: 'invalid', themeColor: 'custom', fontSize: 121, lineHeight: NaN }) },
    { ...new ReaderSettings() });
});

const repositoryBundle = await build({ entryPoints: ['entry/src/main/ets/services/Repository.ets'], bundle: true, write: false, format: 'esm', platform: 'node',
  resolveExtensions: ['.ets', '.ts', '.js'], plugins: [{ name: 'theme-preferences-fixture', setup(b) {
    b.onResolve({ filter: /^@kit\./ }, args => ({ path: args.path, namespace: 'kit' }));
    b.onLoad({ filter: /.*/, namespace: 'kit' }, () => ({ contents: 'export const preferences = {}; export const relationalStore = {}; export const fileIo = {}; export const util = {};' }));
    b.onLoad({ filter: /\.ets$/ }, async args => ({ contents: await readFile(args.path, 'utf8'), loader: 'ts' }));
  }}] });
const { Repository } = await import(`data:text/javascript;base64,${Buffer.from(repositoryBundle.outputFiles[0].text).toString('base64')}`);

test('real repository preserves the legacy shelf on upgrade and reloads both theme scopes separately', async () => {
  const values = new Map([['appearance', JSON.stringify({ theme: 'sepia', fontSize: 24, lineHeight: 1.9 })]]);
  const prefs = { async get(key, fallback) { return values.get(key) ?? fallback; }, async put(key, value) { values.set(key, value); }, async flush() {} };
  const original = new Repository(); original.prefs = prefs;
  const reader = await original.settings(), shelf = await original.librarySettings();
  await original.saveLibrarySettings(shelf);
  await original.saveSettings({ ...reader, themeMode: 'auto', themeColor: 'nord' });
  const restarted = new Repository(); restarted.prefs = prefs;
  assert.deepEqual({ ...await restarted.librarySettings() }, { themeMode: 'light', themeColor: 'sepia' });
  assert.deepEqual({ ...await restarted.settings() }, { ...new ReaderSettings(), themeMode: 'auto', themeColor: 'nord', fontSize: 24, lineHeight: 1.9 });
  await restarted.saveLibrarySettings({ themeMode: 'dark', themeColor: 'grass' });
  assert.equal((await restarted.settings()).themeColor, 'nord');
});
