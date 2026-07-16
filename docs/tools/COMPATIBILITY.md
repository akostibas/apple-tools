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
| music | 0.19.0 | bed3809 | 26.5.2 (25F84) Tahoe | 2026-07-16 | Reads + Group B playback control. Tahoe: `loved`→`favorited` (fallback in place); transport/shuffle/repeat need a settle delay before read-back. |
| media | 0.21.0 | 3524b5d | 26.5.2 (25F84) Tahoe | 2026-07-16 | Read-only recent-media reader over Podcasts + Books SQLite stores. Podcasts reflects phone listening via iCloud sync. TV/movies not covered (no local data). |
| echo | n/a | n/a | n/a | n/a | Diagnostic tool; no OS interaction. |
| calendar | — | — | not recorded | — | |
| reminders | — | — | not recorded | — | |
| notes | — | — | not recorded | — | |
| email | — | — | not recorded | — | |
| imessage | — | — | not recorded | — | |
| contacts | — | — | not recorded | — | |
| photos | — | — | not recorded | — | |
| voicememos | — | — | not recorded | — | |
| documents | — | — | not recorded | — | |
| clipboard | — | — | not recorded | — | |
| screenshot | — | — | not recorded | — | |
| open_uri | — | — | not recorded | — | |
