# Validation

## Verified on this workspace

- Production ArkTS/HAP build passes with the installed HarmonyOS 6.1.1/API 24 SDK. The local development profile now produces both signed and unsigned HAPs.
- Native Hypium test HAP compiles. **Its tests have not run on HarmonyOS.**
- Node tests cover timestamp decisions, server echoes, missing records, invalid responses, authentication fallback, custom base URLs, revision acknowledgment, session cancellation, and a two-client exchange through a local KoSync-compatible HTTP fixture server.
- Edge browser tests cover EPUB metadata/TOC, the pinned Alice partial digest, all **707** upstream CREngine oracle words in both directions, page turning, saved-CFI reopening, invalid/stale locators, appearance, landscape relayout, and EPUB script/tracking isolation.
- Browser screenshots are generated under `output/playwright`; they validate the web reader, not the native ArkUI screens or ArkWeb itself.

## EPUB loading and UI update (2026-10-09)

- A connected HarmonyOS tablet reproduced `Bad file descriptor` during import. ArkWeb consumed the numeric EPUB response descriptor, then cancellation closed it again. Responses now carry binary buffers; native code opens and closes each descriptor once. Missing-file cleanup cannot strand the loading state or mask the original import error.
- Import extracts metadata and covers without starting the renderer. The ZIP decompressor is bundled JavaScript and does not fetch WASM, use workers, or require the platform's native compression streams. The reader CSP is unchanged.
- The updated signed HAP was installed over the existing app. A real EPUB was imported and opened on the tablet; the user confirmed loading succeeds. Device artifacts are under `output/device`.
- Node regression tests exercise offline import, duplicate cleanup, failed import followed by retry, cancelled picking, and multi-chunk binary response/descriptor lifetime.
- Browser validation disables WebAssembly and native decompression. It also imports and renders with `navigator.onLine === false`, fulfilling only the three local reader/book resources.
- Tablet pagination uses two columns, narrow phone layouts use one, and explicit per-side margins replace the ignored generic margin attribute. An empty error banner no longer offsets/clips the viewport. Touch swipes are handled by Foliate once.
- A numbered-word EPUB checks full-height text and five consecutive two-column spread boundaries without missing words. A real Chromium touch swipe advances exactly one spread; left/right thirds turn pages, the middle third toggles controls (including the gutter), and rapid duplicate taps are guarded. Portrait phone relayout returns to one column. Screenshots include `reader-two-columns.png` and `reader-offline.png`.
- The WebView keeps its full viewport size. Native title/toolbar/progress bars overlay the content; toggling them does not resize or repaginate it. CSS length attributes include units, and the settings scroll content aligns at the top.
- On the physical tablet, repeated middle-third taps hid and restored all native bars. The WebView bounds remained `[0,88][2800,1777]`, and the accessible book text and its bounds remained identical before/after both toggles. Device screenshots include `reader-hidden.jpeg`, `reader-visible-again.jpeg`, `bookshelf-after.jpeg`, and `settings-after.jpeg`.
- Native bookshelf/settings are adapted from the pinned Readest library header, cover grid, settings tabs and boxed-list components. They include search, grid/list views, sorting, neutral surfaces, monochrome toolbar icons, and English/Chinese labels.

Browser and local-server tests are not a live Readest integration test. Native import and ArkWeb reading were checked on the connected tablet. Native sync transport and the full HUKS/persistence Hypium suite still need runtime validation.

## Emulator acceptance procedure

1. Create an API 24 phone emulator in DevEco Studio, configure development signing, and run the app. `hdc list targets` must identify the emulator.
2. Import the pinned Alice EPUB and a Chinese EPUB through the system picker. Verify covers/metadata, duplicate handling, cancelled selection, malformed ZIPs, and rejection of fixed-layout/encrypted EPUBs. If copying fixture books into the emulator, use its Documents directory and select them normally.
3. Check empty library, bookshelf, settings, reader controls, TOC, dialogs, dark theme, and Chinese locale. Check phone portrait and tablet/landscape layouts; confirm all controls remain reachable.
4. Read to a different chapter, close the reader, force-stop/relaunch, and reopen. Verify the passage and progress survive. Rotate and change typography without creating a new reading-change timestamp. Rapidly switch books and confirm old callbacks do not update the new one.
5. Run the Hypium `ohosTest` suite: relational persistence/pending progress, isolated HUKS Unicode credentials and no plaintext, timestamp decisions, stale sessions, and concurrent acknowledgment.
6. Configure the same KoSync URL/account and identical EPUB in Readest and HarmonyReadest. Push from HarmonyReadest and pull in Readest; then advance in Readest and reopen HarmonyReadest. Check the passage reached, not only the percentage. Repeat with local progress newer than remote, and read backwards to verify that newer-time comparison does not mean furthest-progress comparison.
7. Read while offline, restart, reconnect, and verify pending progress reconciles. Introduce a newer remote position before reconnecting and verify it wins. Close immediately after a page turn; verify the local save and the next-open retry if the background flush was interrupted.
8. Test invalid credentials, HTML instead of a sync endpoint, timeouts, missing/tied timestamps, and an unresolvable remote XPointer. A failed pull/conversion must not silently overwrite remote progress. Manual Push explicitly overrides the remote record; manual Pull explicitly selects it.
9. Change accounts/servers and disable sync. Confirm queued work from the previous session does not update the new account's local state. Credential tests use separate preference/key names and do not replace the user's credentials.

## Current environment limitations

The initial validation had no connected target or signing profile. As of 2026-10-09, a signed build and connected physical tablet are available and EPUB loading has been verified there. The full native Hypium suite, phone emulator checks, and an actual Readest/KoSync account round trip remain pending. Existing SDK agreement selections were not changed.

KoSync timestamps describe server updates and may differ from the actual moment another client read a passage. Accurate clocks are assumed. The protocol has no conditional-write primitive, so simultaneous clients can race between a pull and a push; the client reconciles before uploads and checks acknowledgments, but cannot make that exchange atomic.
