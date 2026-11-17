# Tool compatibility — what's been verified where

apple-tools drives macOS apps through AppleScript and native frameworks, whose
**terminology and behavior drift across macOS releases** (e.g. macOS 26 "Tahoe"
renamed Music's `loved` property to `favorited` and made transport commands
settle asynchronously). So "it works" is never absolute — it's a claim about a
**specific build of this code on a specific macOS version, verified on a date.**

A row below means: *this tool was exercised end-to-end (not just unit tests)
against the real app, at that apple-tools version/commit, on that macOS build,
on that date, and behaved correctly.* It does **not** guarantee:

- a **newer macOS** still works (Apple can rename/break scripting terms — re-verify),
- a **newer apple-tools commit** still works (our own changes can regress it — the
  row is pinned to a commit for exactly this reason),
- anything about tools/rows marked **not recorded** (just untested, not known-broken).

Verify with `make test` (add `--slow` to exercise writes) and say in the row's
Notes which groups ran; a skipped test is not a pass. Then add/update the row
with the current `apple-tools --version`, `git rev-parse --short HEAD`,
`sw_vers`, and today's date.

Every registered tool must have a row here (enforced by
`CompatibilityDocTests`); a tool with no OS dependency is marked `n/a`.

**This table is read by automation.** `bin/macos-compat-status` runs at session
start and compares the running macOS build against the builds recorded below,
speaking up when a tool has no row for the OS you're actually on. It is
deliberately a notice and not a test: a test would fail every commit after an
upgrade, on something that isn't a code defect, and would be silenced within a
day. It stays quiet unless a row is genuinely stale — rows marked `n/a` or
`not recorded` never trigger it on their own, or it would fire every session
and stop being read.

| Tool | apple-tools | Commit | macOS | Verified | Notes |
|------|-------------|--------|-------|----------|-------|
| calendar | 0.34.0 | 6cecaa1 | 27.2.1 (26B131) | 2026-11-16 | Read-only and slow groups green: `calendars`, `list`, `search`, and create, update and delete of timed, all-day, time-zoned and repeating events (one occurrence and this-and-future), in a calendar shared with nobody. |
| clipboard | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only and slow groups green: `read`, and `write` read back with the previous contents restored. |
| contacts | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only and slow groups green: `search`, `read`, `create`, `update`, `delete` against the real address book (iCloud account only). |
| documents | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green: `list`, `info`, `fetch` and Spotlight `search` over `~/Documents`. |
| email | 0.34.0 | 6cecaa1 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green with Mail open: `inbox`, `read`, `headers`, `mailboxes`, `search` by sender. Slow group green: `draft` (no window), `discard`, `reply` to a no-reply sender, `move` within one non-Gmail account, and `fetch_attachment`, the last two on the test's own draft. |
| imessage | 0.34.0 | 6cecaa1 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green: `list`, `read`, `stats`, `search` over the real `chat.db`. Slow group green: one `send` to the user's own number with a file, read back and its attachment fetched. SMS and group chats NOT exercised. |
| media | 0.34.0 | 1e22516 | 27.2.1 (26B131) | 2026-11-16 | `list` over the real Podcasts store returned recent episodes with duration and progress; not cross-checked against the Podcasts app. The 27.0 duration probe still holds. #94 ("schema unrecognized" on 27.2 26B123) did not reproduce here and is treated as a locked store: locks are now waited out and reported as busy. Books also read (98 items over a long window). |
| music | 0.34.0 | 6cecaa1 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green with Music open: `now-playing`, `search`, `stats`, `mix`, `airplay-list`. Slow group green: favorite, rating, playlist create, add, remove and delete. Attended group green: play, pause, skip, seek, stop, volume, shuffle, repeat; AirPlay re-selected only. |
| notes | 0.34.0 | 470ec12 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green: `folders`, `list`, `search`, `read`. Slow group green: create (headings `#`/`##` round-trip; `###` is stored as `##`), append, move, delete and rename-folder. Attended group not run. |
| photos | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green: keyword search over common subjects, people search, `fetch`. The 27.0 `leo.sqlite` reading still holds. Import NOT exercised (#97). |
| reminders | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only and slow groups green: every action, including subtasks, repeat rules and a test list that is removed afterwards. |
| screenshot | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green: a capture produced an image. |
| voicememos | 0.34.0 | e61f1f5 | 27.2.1 (26B131) | 2026-11-16 | Read-only group green: `folders`, `list`, `search`, `export`, `transcribe` over the real store. |
| echo | n/a | n/a | n/a | n/a | Diagnostic tool; no OS interaction. |
| open_uri | 0.34.0 | 6cecaa1 | 27.2.1 (26B131) | 2026-11-16 | Attended group green: a folder URI opened in Finder. Web, `mailto:` and deep links NOT exercised. |

## What a verified row can't prove

One line per tool; each tool's page has the detail under *Testing gaps*.

- **calendar**: invites from other people and events on read-only calendars are never touched; needs a calendar shared with nobody.
- **clipboard**: no known gap.
- **contacts**: refusals for read-only accounts and cards spanning two accounts can't be tested without such contacts.
- **documents**: an unindexed file looks the same as a broken Spotlight search.
- **email**: received mail can't be planted; move and attachment fetch are proven only on the test's own draft; skipped while Mail is closed.
- **imessage**: only a send to yourself over iMessage is proven; each slow run leaves that message behind.
- **media**: nothing can be planted, so an empty list is undecidable on a new Mac.
- **music**: play history can't be planted; playback is proven only by the attended group; AirPlay is re-selected, never moved; skipped while Music is closed.
- **notes**: test folders are left behind; locked-note refusals are untested.
- **open_uri**: attended only, and only a folder URI is opened.
- **photos**: keyword search can't be planted; import is untested because the photo can't be removed.
- **reminders**: no known gap.
- **screenshot**: skipped unless Screen Recording is already granted.
- **voicememos**: nothing can be planted, so an empty list is undecidable on a new Mac.

## macOS 27 upgrade — what moved

Recorded 2026-09-15, from a full sweep after upgrading. Two data stores changed
shape, and both failed **silently** — returning an empty result with a success
exit code, which is indistinguishable from "you genuinely have none of these":

- **Podcasts** moved episode duration out of `ZMTEPISODE` into a separate
  `ZMTMEDIAENCLOSURE` row. Fixed by probing for the column rather than
  requiring it.
- **Photos** deleted `psi.sqlite` entirely, replacing it with `leo.sqlite`.
  Keyword search now reads the new index. Where psi had a `ga` join table, leo
  inverts it: each row in `items` carries a `lexeme_ids` BLOB — a packed array
  of little-endian `UInt32` ids — pointing into a `lexicon` table. Scene labels
  are category 4000, keyed `scene/N`, with synonyms sharing a lexeme id.
  Category 4120 holds text scanned out of the image and is deliberately **not**
  searched as content; see `photos.md`.

Both fixes probe for what's present rather than checking the OS version, per
[ADR-0004](../adr/0004-macos-version-compatibility.md).

Because of this, `apple-tools permissions` now reports a third state: a `⚠`
**degraded** line (exit 3) for capabilities lost to an OS change, distinct from
a denied permission (exit 2). Permissions preflighted green on 27 while both
tools above were broken — opening a store proves nothing about reading it.

**Toolchain note:** building on macOS 27 requires a Swift toolchain matching the
27.0 SDK. Xcode 26.6 bundles Swift 6.4 (`arm64-apple-macosx27.0`) and builds
cleanly; the mise pin in `.tool-versions` (`swift 6.3.2`, which targets
`macosx28.0`) fails with `unknown argument: '-target-arch-variant'`.
