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

When you verify a tool on a new OS or after nontrivial changes, add/update its
row with the current `apple-tools --version`, `git rev-parse --short HEAD`,
`sw_vers`, and today's date.

Every registered tool must have a row here (enforced by
`CompatibilityDocTests`); a tool with no OS dependency is marked `n/a`.

| Tool | apple-tools | Commit | macOS | Verified | Notes |
|------|-------------|--------|-------|----------|-------|
| calendar | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `calendars` and `list` over a real multi-calendar setup (CalDAV + shared). No drift from 26. |
| clipboard | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `read` against an empty and a populated pasteboard. No drift from 26. |
| contacts | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `search` over the real address book. No drift from 26. |
| documents | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | Spotlight-backed `search`. No drift from 26. |
| email | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `inbox` and `search` against live Mail. Store-version globbing (v0.26.0) holds on 27. Draft/reply/send NOT exercised. |
| imessage | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `recent` and `search` over the real `chat.db`. Contact resolution and spam classification intact. `send` NOT exercised. |
| media | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | **Broke on 27 and was fixed.** Podcasts moved episode duration from `ZMTEPISODE.ZDURATION` to `ZMTMEDIAENCLOSURE`; the column was wrongly required, so the whole source returned empty. Duration is now probed wherever it lives. Books unaffected. |
| music | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `now-playing`, `search`, `stats`, `mix` verified. The 26 `loved`→`favorited` fallback still holds. Playback control (play/pause/next) NOT re-exercised on 27. |
| notes | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `folders` (63 folders, nested paths) and `search`. No drift from 26. Create/append NOT exercised. |
| photos | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | **Partially broken on 27.** Listing, `--person`, `--album` and `--match filename` all work. Keyword/content search does NOT: macOS 27 deleted `psi.sqlite` (replaced by an as-yet-unread `leo.sqlite` FTS index), so it now returns an explicit error instead of silently filename-matching. See issue #65. |
| reminders | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `lists` and `search`, including parent/subtask nesting. No drift from 26. |
| screenshot | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | Capture to the output dir. No drift from 26. |
| voicememos | 0.26.1 | 5504294 | 27.0 (26A428) | 2026-09-15 | `list` and `search` over the real store; schema still recognized. Export and transcribe NOT exercised. |
| echo | n/a | n/a | n/a | n/a | Diagnostic tool; no OS interaction. |
| open_uri | — | — | not recorded | — | Not exercised on 27 (side-effecting: opens a real URI). |

## macOS 27 upgrade — what moved

Recorded 2026-09-15, from a full sweep after upgrading. Two data stores changed
shape, and both failed **silently** — returning an empty result with a success
exit code, which is indistinguishable from "you genuinely have none of these":

- **Podcasts** moved episode duration out of `ZMTEPISODE` into a separate
  `ZMTMEDIAENCLOSURE` row. Fixed by probing for the column rather than
  requiring it.
- **Photos** deleted `psi.sqlite` entirely. It is replaced by `leo.sqlite` (an
  FTS5 `lexicon` plus an `items` table keyed by a packed `lexeme_ids` BLOB) and
  a binary Spotlight V3 index. Keyword search is unrestored — see issue #65.

Because of this, `apple-tools permissions` now reports a third state: a `⚠`
**degraded** line (exit 3) for capabilities lost to an OS change, distinct from
a denied permission (exit 2). Permissions preflighted green on 27 while both
tools above were broken — opening a store proves nothing about reading it.

**Toolchain note:** building on macOS 27 requires a Swift toolchain matching the
27.0 SDK. Xcode 26.6 bundles Swift 6.4 (`arm64-apple-macosx27.0`) and builds
cleanly; the mise pin in `.tool-versions` (`swift 6.3.2`, which targets
`macosx28.0`) fails with `unknown argument: '-target-arch-variant'`.
