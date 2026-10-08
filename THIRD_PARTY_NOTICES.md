# Third-party sources

HarmonyReadest is licensed under AGPL-3.0-or-later. It is an independent HarmonyOS application, not an official Readest release.

| Component | Revision / version | License | Use |
| --- | --- | --- | --- |
| [Readest](https://github.com/readest/readest) | `f74a19d39e2badf81125f42a85c54adae26c7048` | AGPL-3.0-or-later | CFI/XPointer conversion, partial MD5, CREngine fixtures |
| [Readest Foliate fork](https://github.com/readest/foliate-js) | `08db61054bd5bc21f244c6ad128f103b6427b03c` | MIT | EPUB parser, layout, navigation, CFI |
| [zip.js](https://github.com/gildas-lormeau/zip.js) | 2.8.26 | BSD-3-Clause | EPUB archive loading |
| [js-md5](https://github.com/emn178/js-md5) | 0.8.3 | MIT | KoSync-compatible partial document digest |

Vendored sources retain upstream copyright and license files. Reader builds also include the license texts as `reader/licenses.txt`. Development tools (esbuild, Playwright, Hypium, Hamock) are not part of the production reader bundle.

Readest/Foliate adaptations are implemented in the app wrapper and build script rather than modifying vendored source files. The build removes `allow-scripts` from Foliate chapter iframe sandboxes and stubs unsupported format modules. `scripts/fetch-upstream.py` fetches the recorded Readest revision and its exact Foliate gitlink; `vendor/revisions.json` records both.
