# Readest Replica Syncing

The Syncing page follows Readest's Cloud Sync and Reading Sync groups, with service rows leading to dedicated settings pages. The Readest page exposes existing-account email/password sign-in, automatic/manual sync, independent font and annotation switches, last successful sync, live storage usage/quota/available space/file count, storage refresh and disconnect. It synchronizes supported EPUB library entries, book files, covers, reading positions, per-book font/layout preferences, bookmarks and highlights, plus TTF/OTF custom fonts.

Other font formats and files above 32 MiB remain remote and are skipped without blocking supported fonts. Readest's pinned settings-replica whitelist does not carry ordinary global font/layout defaults or built-in shelf/reader themes; these remain device-local. Supported font/layout preferences synchronize through per-book configs. Credential/passphrase sharing, dictionaries, textures, statistics and catalog replicas are outside the existing-feature scope. Use an existing account with email/password login.

## Protocol

- Public Supabase client configuration comes from Readest revision `f74a19d39e2badf81125f42a85c54adae26c7048`. Password login and refresh use `/auth/v1/token`; passwords are never persisted. Access/refresh tokens, category flags, cursor, HLC state and pending deletes are encrypted in a separate device-bound HUKS vault.
- Metadata uses authenticated `GET /api/sync/replicas?kind=font&since=…` and `POST /api/sync/replicas` with schema version 1, per-field `{v,t,s}` envelopes, and Readest's 13-hex/8-hex/device hybrid logical clock. Incoming rows must belong to the connected account and satisfy the supported schema, filename, size and digest checks.
- Content identity is Readest's `md5(partialMD5 | byteSize | filename)`. File bodies use signed storage URLs under `Readest/Replicas/font/<contentId>/<filename>`. Account bearer headers are sent only to the Readest API, not the signed object URLs or WebView.
- Uploads publish metadata first, upload the binary, then commit the manifest. Interrupted uploads stay unpublished locally and retry. Downloads validate byte length, partial digest and content identity before installation. A failed batch does not advance its persisted pull cursor.
- Pulls precede uploads to respect remote tombstones. Local deletions while the Fonts category is enabled are queued durably before removing the local file. Remote deletion never touches original imported source files. Re-import after deletion uses a fresh reincarnation token.
- Foreground/network recovery and a one-minute timer retry enabled syncing, including a failed initial position check. Turning off Fonts or Annotations stops that category while book/config sync continues. Turning off Sync stops automatic publication/pulls. Account changes and disconnect invalidate in-flight responses. Disconnect preserves local files and remote account data.

## Library, positions and storage

- Library/config/annotation data use `GET /api/sync?type=books|configs|notes&since=…` and `POST /api/sync`. Pulls use database fields; pushes use Readest's camelCase payloads. Library cursors use server `synced_at`, config/note cursors use update/deletion times. Cursors commit only after every received row is applied; server pagination returns timestamp ties together.
- Bookmarks and highlights retain stable IDs and merge by update/deletion time; deletion wins ties. Offline deletions survive restart. Upload acknowledgments cannot clear a newer local edit. Unsupported note text/XPointer fields are preserved when editing supported highlights. Remote changes refresh the open reader without moving it or producing a local edit event. Account changes discard the old account's annotation tombstones.
- Books retain the EPUB partial MD5. Metadata is published before the signed object under `Readest/Books/<hash>/<hash>.epub`; `uploadedAt` commits after book and available cover transfers complete. The download endpoint resolves legacy title-based object names. Covers use `Readest/Books/<hash>/cover.png`.
- Cloud books appear on the shelf and download when opened. Downloads stream into private temporary files with 128 MiB book/4 MiB cover bounds, handle short writes, verify partial MD5 and atomically rename. Failures retain existing content. Expanded EPUBs remain bounded at 512 MiB.
- Configs carry CFI, compatible XPointer and fractional `[current,total]` progress. Fonts/layout map to `viewSettings`, including `defaultFontSize`. Unsupported view/search/RSVP settings and book metadata/group/tag fields are preserved. Typography uploads preserve cloud progress until reconciliation, and concurrent local style edits remain pending.
- Opening a book/app reconciles positions through the existing choice dialog. Differing positions never use timestamps to silently choose a winner. Unresolved locators or pending choices pause publication; acknowledgments cannot clear newer edits. Safe closed-book positions retry; conflicts remain pending and are reported in the card. Existing saved progress is published when Readest has no position for it.
- With both methods enabled, Readest supplies the resume position, falling back to KoSync when Readest has none. The chosen local or remote position is sent to both. Failure in either publication channel keeps it pending. Credentials remain independent.
- Local removal leaves uploaded cloud books downloadable. The separately labeled cloud removal publishes a library tombstone and removes this device's copy. Readest's normal tombstone protocol retains cloud files, so this action does not reclaim storage.
- `/api/storage/stats` provides live account-wide usage, quota and file count. Storage refresh also works while automatic syncing is paused. Errors are shown separately and never imply zero usage. Tokens never enter signed-object requests or the WebView.

## Font and layout settings

Native settings and reader panels use the same defaults and supported ranges. The native font list includes actual enumerated system families and installed custom families; the reader's compact selectors include generic and custom families. Only selected custom families are loaded into reader memory. Book fonts are preserved until Override Book Font is enabled, including fonts declared on the EPUB's `html` element. Minimum size preserves and restores publisher inline declarations, and layout changes do not create reading edits.

The native Fonts/Layout controls persist through the existing appearance preference and per-book synchronized configs. Legacy typography and independently configured shelf/reader themes migrate together. Use Book Layout disables paragraph controls and restores publisher styling without discarding overrides. Scrolled mode disables column-count/gap controls. Page margins add native safe-area insets.

## Validation boundary

Automated tests exercise the real native font library and replica coordinator with a local platform/transport fixture, including two clients, storage keys, manifest ordering, integrity checks, retries, category gating, refresh, account cancellation and tombstones. Existing vault tests exercise real AES-GCM with HarmonyOS-style missing-key behavior. Browser tests load a real local font and verify rendered EPUB styles, margins, columns and scroll mode.

Cloud tests cover two-device library/config exchange, lazy bodies, signed keys, transfer ordering, retries, cursor ties, tombstones, offline conflicts, account cancellation, concurrent style edits and unknown-field preservation. Real native file code is exercised with streamed bodies, short reads/writes, partial-MD5 verification and cleanup on size/checksum/network/disk failures. Edge also verifies CFI-only cloud previews without moving the reader.

New persistent features must include their Readest payload, merge/deletion behavior and round-trip coverage. This requirement is documented beside the annotation sync model; KoSync remains the reading-position channel.

The signed update was installed over the physical tablet's existing app. Its saved Readest account loaded, reported successful sync and displayed live storage usage/quota/available bytes/file count while Fonts was disabled. See [validation evidence](VALIDATION.md) for results and remaining live cross-device checks.
