# Third-party sources

This Readest port for HarmonyOS (repository: HarmonyReadest) is licensed under AGPL-3.0-or-later. It is an independent HarmonyOS application, not an official Readest release.

| Component | Revision / version | License | Use |
| --- | --- | --- | --- |
| [Readest](https://github.com/readest/readest) | `f74a19d39e2badf81125f42a85c54adae26c7048` | AGPL-3.0-or-later | CFI/XPointer conversion, partial MD5, CREngine fixtures, adapted reader chrome and bar transitions, native settings, sync-source cards, built-in palettes and official icon artwork |
| [Readest Foliate fork](https://github.com/readest/foliate-js) | `08db61054bd5bc21f244c6ad128f103b6427b03c` | MIT | EPUB parser, layout, navigation, CFI |
| [zip.js](https://github.com/gildas-lormeau/zip.js) | 2.8.26 | BSD-3-Clause | EPUB archive loading |
| [js-md5](https://github.com/emn178/js-md5) | 0.8.3 | MIT | KoSync-compatible partial document digest |

Vendored sources retain upstream copyright and license files. Reader builds also include the license texts as `reader/licenses.txt`. Development tools (esbuild, Playwright, Hypium, Hamock) are not part of the production reader bundle. `tinycolor2` 1.6.0 (MIT) evaluates the pinned palette definitions at build time; only static palette data ships in the app.

Theme selectors follow Readest's `ThemePanel.tsx`, `ThemeModeSelector.tsx`, and `ThemeColorSelector.tsx`: one shelf/reader scope, separate mode and color, pill mode controls and three-column palette previews. `scripts/generate-themes.mjs` evaluates the unmodified `styles/themes.ts` with its original color library to generate the shared `core/Themes.ets` table. All 11 schemes have light and dark variants; System mode follows platform appearance. Custom themes, ambient mode and other theme options are deferred. Launcher foreground artwork uses Readest's Android `ic_launcher_foreground.png`, proportionally resized into a 1024 x 1024 transparent layer for HarmonyOS with its original composition and spacing preserved. The separate white background is also 1024 x 1024 and fills the entire layer; launcher masking is left to the system. Splash/About artwork uses its `public/icon.png`. `sharp` is a build-only image-processing dependency and is not packaged with the reader.

Native sync settings adapt the provider rows in `IntegrationsPanel.tsx` and the configured/unconfigured branches of `integrations/KOSyncForm.tsx`. Service rows expand inline within the floating dialog. Configured accounts expose options and Disconnect without login fields; unsupported providers are hidden. Changing sync enablement or device name persists locally without reauthenticating or requesting remote progress.

Reader chrome adapts `HeaderBar.tsx`, `footerbar/{FooterBar,MobileFooterBar,DesktopFooterBar,NavigationBar,NavigationPanel}.tsx` from the pinned Readest revision. `reader/src/readest-motion.css` resolves their Tailwind transition declarations into standalone CSS with the same properties, durations and easing. Page turns use the unmodified vendored Foliate paginator's `animated` / `turn-style="push"` path (Readest's default). Settings and source-choice cards follow Readest's `SettingsDialog.tsx`, `Dialog.tsx`, and `KOSyncResolver.tsx`. Platform markup and the offline bridge are adapted; unavailable Readest features remain deferred.

Readest/Foliate adaptations are implemented in the app wrapper and build script rather than modifying vendored source files. The build removes `allow-scripts` from Foliate chapter iframe sandboxes and stubs unsupported format modules. `scripts/fetch-upstream.py` fetches the recorded Readest revision and its exact Foliate gitlink; `vendor/revisions.json` records both.
