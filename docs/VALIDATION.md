# Validation

## Verified on this workspace

- Production ArkTS/HAP build passes with the installed HarmonyOS 6.1.1/API 24 SDK. Output is unsigned because no signing profile is configured.
- Native Hypium test HAP compiles. **Its tests have not run on HarmonyOS.**
- Node tests cover timestamp decisions, server echoes, missing records, invalid responses, authentication fallback, custom base URLs, revision acknowledgment, session cancellation, and a two-client exchange through a local KoSync-compatible HTTP fixture server.
- Edge browser tests cover EPUB metadata/TOC, the pinned Alice partial digest, all **707** upstream CREngine oracle words in both directions, page turning, saved-CFI reopening, invalid/stale locators, appearance, landscape relayout, and EPUB script/tracking isolation.
- Browser screenshots are generated under `output/playwright`; they validate the web reader, not the native ArkUI screens or ArkWeb itself.

Browser and local-server tests are not a live Readest integration test. The native transport, document picker, HUKS runtime, filesystem response descriptors, and ArkWeb runtime still need emulator validation.

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

`hdc list targets` returned empty. No deployed emulator image was found in the configured Huawei emulator directory. The project has no signing profile, and no shared KoSync account was supplied. Therefore native emulator tests and an actual Readest round trip are pending. Existing SDK agreement selections were not changed.

KoSync timestamps describe server updates and may differ from the actual moment another client read a passage. Accurate clocks are assumed. The protocol has no conditional-write primitive, so simultaneous clients can race between a pull and a push; the client reconciles before uploads and checks acknowledgments, but cannot make that exchange atomic.
