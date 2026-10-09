# Readest for HarmonyOS

A HarmonyOS app with a native ArkUI library and settings, and an offline EPUB reader built from Readest's Foliate engine. Readest cloud sync exchanges EPUB books, reading positions, per-book typography and custom fonts. KoSync is also available for reading positions.

The UI follows the pinned Readest design: a compact shelf toolbar, cover-sized import tile, floating tabbed settings, neutral boxed lists, and sync-source choice cards containing their own chapter and progress. Reader chrome uses a compact title bar, expandable phone panels and a slim desktop progress toolbar. Bar transitions reuse Readest's CSS declarations; page turns use its vendored Foliate animation. EPUB import and reading work without an internet connection; wide screens show two reading columns and phones show one.

Sync settings use collapsible Readest and KOReader service cards. Connected cards show the saved account, sync options and Disconnect; login fields appear only when disconnected. The Readest card includes live cloud storage usage, quota, available space and file count. Unsupported services and categories are hidden.

## First release

- Import reflowable EPUBs, extract covers and metadata, and resume saved positions offline.
- Use the table of contents, tap/swipe page turns, progress slider, and paginated or scrolled reading.
- Font settings follow Readest's grouped controls: book-font override, default/minimum size, weight, serif/sans-serif/monospace families, CJK fallback, and custom font management. Import local TTF/OTF files up to 32 MiB each; installed fonts work offline.
- Adjust paragraph margins, line/word/letter spacing, indentation, justification and hyphenation. Use Book Layout restores publisher paragraph styling. Page settings include four margins, additional margin, column gap, maximum columns and column dimensions; system safe areas remain reserved for text.
- Sign in with an existing Readest email/password account to synchronize the EPUB library, files, covers, positions and per-book font/layout settings. Cloud books download when opened and are verified against their content hash. TTF/OTF custom fonts use the replica protocol, with an independent category switch. Manual sync, incremental pulls, retry and storage refresh are available.
- Choose Readest's 11 built-in color schemes with Light, Dark, or System mode independently for the shelf and reader. Existing theme and typography preferences migrate on upgrade. Custom schemes and other theme features remain deferred.
- Fill the screen with a themed background, including the status and gesture areas, while keeping controls and text clear of system indicators. The launcher and splash screen use Readest's official icon artwork; the displayed app name is Readest.
- Configure an existing KoSync account and HTTPS server. Like Readest's prompt mode, check remote progress on book open and app return, and let the user choose when positions differ. Uploads pause until that choice. Reading changes upload after five seconds, including backwards reading; manual Send progress and Check remote are available.
- With both services enabled, Readest supplies the resume position, falling back to KoSync when Readest has none. The chosen position is sent to both services. Differing positions require a choice; an unresolvable remote locator pauses automatic uploads.
- English and Simplified Chinese follow the system language.

KoSync transfers **positions only**. Import the same EPUB into Readest and HarmonyReadest and select file-content/binary matching in Readest. Credentials never enter the reader WebView; native HTTP uses normal TLS verification and the saved credentials are encrypted with a HUKS AES-GCM key.

The default server is `https://sync.koreader.rocks/`, matching [Readest's default](https://github.com/readest/readest/blob/main/apps/readest-app/src/services/constants.ts). Readest leaves KoSync disabled with empty credentials until configured. Use the same KoSync username and password in both apps; these are separate from Readest cloud credentials. This app connects to an existing account and does not register one.

PDF, fixed-layout EPUB, DRM, annotations, search, OPDS and TTS are deferred. The Readest card exposes the data this reader implements. Global appearance defaults and shelf theme remain device-local; per-book font/layout settings synchronize. Import limits are 128 MiB compressed / 512 MiB expanded. App backup/restore is disabled so device-bound credential storage is not backed up. Files survive app restarts but not uninstall or clearing app data.

## Build

Requires DevEco Studio with HarmonyOS **6.1.1 / API 24**, its bundled tools, and Node/npm. The existing project targets phone and tablet. Keep the prototype bundle ID `com.example.harmonyreadest` until an application identity and matching signing profile are chosen.

```powershell
npm ci
./scripts/build-hap.ps1
# Override an installation path if necessary:
./scripts/build-hap.ps1 -DevEco 'C:\path\to\DevEco Studio'
```

The script sets the SDK/JDK for the build process and runs Hvigor. A Hvigor hook builds all reader assets into `entry/src/main/resources/rawfile/reader` before packaging, including when using DevEco Studio's Run button after `npm ci`. The same build generates one shared native/web palette table from the pinned Readest `themes.ts` and copies the official icon assets. No CDN or hosted reader is required. Vendored sources and the npm lockfile make normal builds independent of upstream changes.

Builds produce `entry/build/default/outputs/default/entry-default-unsigned.hap`. With a local signing profile configured in DevEco Studio, they also produce `entry-default-signed.hap`, which can run on a connected device or API 24 emulator. Signing credentials belong to the local development environment.

## Tests

```powershell
npm test
npm run test:browser
./scripts/build-hap.ps1 -Tests
```

Browser tests use installed Microsoft Edge by default; set `PW_CHANNEL=chrome` to use installed Chrome. Reports and screenshots go to `output/playwright`. The browser bundle enables test helpers that are excluded from the production HAP bundle.

See [validation status and emulator checks](docs/VALIDATION.md) for results and checks that remain unverified. Building a Hypium test HAP is separate from executing its tests on HarmonyOS.

## Architecture

ArkTS owns import, private files, ArkData relational persistence, preferences, lifecycle events, KoSync/replica networking, and HUKS credentials. Readest access/refresh tokens use a separate HUKS vault; account passwords are used only during sign-in. Font binaries reach ArkWeb through restricted local resource responses and selected-font blob URLs, without exposing account tokens. ArkWeb hosts a bundled EPUB parser/layout engine and emits typed metadata and position messages. A versioned bridge uses per-book session IDs, request IDs, and restricted origins; stale sessions cannot update another book. Chapter scripts and external resource loads are blocked.

Reading positions retain canonical EPUB CFI, the compatible XPointer, local change time, revision, pending-upload flag, and the acknowledged remote record. Pending changes are persisted before upload. Upload acknowledgment cannot clear a newer reading revision. Safe pending cloud positions for closed books retry automatically; conflicting positions remain pending until the book is opened and a position chosen. Background network work is best-effort.

`ProgressSyncProvider` separates progress transport from the coordinator and renderer. Readest books/configs use the cloud API, and custom fonts use the replica API. Both share an encrypted Readest session, while KoSync retains its separate credentials. See [sync protocol and supported scope](docs/REPLICA_SYNC.md).

## Upstream and license

Readest and its exact Foliate dependency are pinned in `vendor/revisions.json`. To deliberately re-fetch the recorded sources, run `python scripts/fetch-upstream.py` with network access. To change revisions, update the fetch script, re-vendor, rerun compatibility tests, and update notices.

AGPL-3.0-or-later; see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). This is an independent project and is not an official Readest release.
