# Readest for HarmonyOS

A new HarmonyOS app with a native ArkUI library and settings, and an offline EPUB reader built from Readest's Foliate engine. The initial release synchronizes reading positions with Readest through a shared KoSync server.

The UI follows the pinned Readest design: a compact shelf toolbar, cover-sized import tile, floating tabbed settings, neutral boxed lists, and sync-source choice cards containing their own chapter and progress. Reader chrome uses a compact title bar, expandable phone panels and a slim desktop progress toolbar. Bar transitions reuse Readest's CSS declarations; page turns use its vendored Foliate animation. EPUB import and reading work without an internet connection; wide screens show two reading columns and phones show one.

Sync settings use collapsible service cards. Once connected, KOReader shows the saved account, sync options and Disconnect; username/password fields appear only when disconnected. Unsupported methods are hidden. The About page describes current reading features and displays the app version and license.

## First release

- Import reflowable EPUBs, extract covers and metadata, and resume saved positions offline.
- Use the table of contents, tap/swipe page turns, progress slider, font size, and line spacing.
- Choose Readest's 11 built-in color schemes with Light, Dark, or System mode independently for the shelf and reader. Existing theme and typography preferences migrate on upgrade. Custom schemes and other theme features remain deferred.
- Fill the screen with a themed background, including the status and gesture areas, while keeping controls and text clear of system indicators. The launcher and splash screen use Readest's official icon artwork; the displayed app name is Readest.
- Configure an existing KoSync account and HTTPS server. Like Readest's prompt mode, check remote progress on book open and app return, and let the user choose when positions differ. Uploads pause until that choice. Reading changes upload after five seconds, including backwards reading; manual Send progress and Check remote are available.
- Prefer the newer local reading-change time or server update time. Missing/tied times require a choice. An unresolvable remote XPointer pauses automatic uploads.
- English and Simplified Chinese follow the system language.

KoSync transfers **positions only**. Import the same EPUB into Readest and HarmonyReadest and select file-content/binary matching in Readest. Credentials never enter the reader WebView; native HTTP uses normal TLS verification and the saved credentials are encrypted with a HUKS AES-GCM key.

The default server is `https://sync.koreader.rocks/`, matching [Readest's default](https://github.com/readest/readest/blob/main/apps/readest-app/src/services/constants.ts). Readest leaves KoSync disabled with empty credentials until configured. Use the same KoSync username and password in both apps; these are separate from Readest cloud credentials. This app connects to an existing account and does not register one.

PDF, fixed-layout EPUB, DRM, annotations, search, OPDS, TTS, and official Readest cloud sync are deferred. Import limits are 128 MiB compressed / 512 MiB expanded. App backup/restore is disabled in this initial build so device-bound credential storage is not backed up. Files survive app restarts but not uninstall or clearing app data.

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

ArkTS owns import, private files, ArkData relational persistence, preferences, lifecycle events, KoSync networking, and HUKS credentials. ArkWeb hosts a bundled EPUB parser/layout engine and emits typed metadata and position messages. A versioned bridge uses per-book session IDs, request IDs, and restricted origins; stale sessions cannot update another book. Chapter scripts and external resource loads are blocked.

Reading positions retain canonical EPUB CFI, the compatible XPointer, local change time, revision, pending-upload flag, and the acknowledged remote record. Pending changes are persisted before upload. Upload acknowledgment cannot clear a newer reading revision. Pending progress for a closed book is reconciled when that book is reopened; background network work is best-effort.

`ProgressSyncProvider` separates the sync transport from the coordinator and renderer. A later Readest-cloud provider can reuse the same reader positions and platform services. It will require Readest authentication, book/storage identity adapters, and the then-current replica encryption/cursor protocol; KoSync does not stand in for those APIs.

## Upstream and license

Readest and its exact Foliate dependency are pinned in `vendor/revisions.json`. To deliberately re-fetch the recorded sources, run `python scripts/fetch-upstream.py` with network access. To change revisions, update the fetch script, re-vendor, rerun compatibility tests, and update notices.

AGPL-3.0-or-later; see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). This is an independent project and is not an official Readest release.
