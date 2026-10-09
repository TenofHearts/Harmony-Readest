# Reading-position sync

HarmonyReadest follows Readest's KOSync **prompt** strategy. The user chooses a resume position when devices disagree. Neither the larger percentage nor the newer timestamp silently selects a winner.

## Reader behavior

| Trigger | Behavior |
| --- | --- |
| Open a book or return to the app | Check remote progress. If positions differ, pause uploads and show the choice dialog. |
| Choose Continue here | Upload the current local position and resume automatic uploads. |
| Choose Use other position | Restore the exact report displayed in the dialog; resume uploads only after restoration succeeds. |
| Read or revisit an earlier passage | Save locally immediately; upload after five seconds. No remote pull or automatic page jump. |
| Network reconnect, background or book close | Flush local progress after the opening check has been resolved. Unresolved choices and restoration failures block automatic uploads. |
| Reader menu → Sync | Refresh the Readest library and fonts, then check progress through the configured services and offer a choice if needed. |

A new report can prompt even if it is older or behind. A previously acknowledged or explicitly accepted report does not prompt again unchanged. A missing server record can be seeded with the saved local position.

## Comparison and preview

Known matching XPointers and accepted reports converge without a choice. Resolve another device's unfamiliar XPointer to local CFI/progress without navigating. Show its chapter and locally computed percentage alongside this device's position. Cross-client percentages alone do not establish a match.

Like Readest, ignore drift up to 0.01% for a locally resolved other-device position; this-device reports allow 1% drift. An unresolvable other-device XPointer always requires a choice, even if the reported percentage matches. A failed restoration cannot enable automatic uploads or fall back to an estimated percentage.

The dialog retains its displayed report. Choosing remote does not fetch and silently apply a different report. Automatic uploads queued behind a check are blocked when that check discovers a conflict.

## Persistence and acknowledgment

Positions, pending uploads and accepted report identity persist per account/server/document. Credentials stay in the native encrypted vault. Use the same EPUB and partial-binary digest on both clients.

Upload a snapshot and acknowledge only its revision on successful PUT. Retain CrossPoint's returned timestamp when available; marker-only responses retain the uploaded locator/percentage/device identity. Upload-only operations do not GET remote progress. Newer local edits remain pending, and stale session responses cannot update another account/book.

KOSync has no conditional-write primitive. Concurrent writers can overwrite one another; a prompt cannot make multi-device writes atomic. CrossPoint's standard endpoint returns its most recently updated device report.

## Upstream reference

This flow follows the prompt strategy, pull-on-open, window activation, five-second push debounce and explicit resolution in the pinned [Readest useKOSync hook](https://github.com/readest/readest/blob/f74a19d39e2badf81125f42a85c54adae26c7048/apps/readest-app/src/app/reader/hooks/useKOSync.ts), with comparison informed by [kosyncProgress](https://github.com/readest/readest/blob/f74a19d39e2badf81125f42a85c54adae26c7048/apps/readest-app/src/app/reader/hooks/kosyncProgress.ts).
