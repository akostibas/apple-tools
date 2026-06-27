# ADR-0002: Serve `notes search` from a direct on-disk store read

- Status: Accepted
- Date: 2026-06-27

## Context

`notes search` was built on AppleScript. The filter was
`every note whose name contains theQuery or plaintext contains theQuery`,
counted and paginated inside the script (issue #13).

On a large store (~2k notes) broad/short queries hit
`AppleScriptRunner.defaultDeadline` (60s) and returned nothing useful — exactly
the exploratory queries an agent issues first. The issue named
`plaintext contains` as the cause: it forces Notes to decompress and scan every
note body on each call, O(store).

Benchmarking on the real store (`bench/notes_fulltext_bench.swift`) and then
testing the name-only fix exposed a second, decisive fact: **the
`name contains` half is just as fatal on a broad query.** AppleScript's `whose`
filter costs one Apple-event round-trip per match, so cost scales with the match
count regardless of which field is matched:

| query | matches | AppleScript name-only |
|-------|--------:|----------------------:|
| `meeting` | 129 | 3.3s |
| `a` | ~2000 | **timeout (60s)** |

So the timeout is a property of the **backend** (Apple events), not the
`plaintext` clause. A name-first fast path — the issue's leading proposal —
would still time out on the broad queries the issue is about, failing its own
acceptance criterion ("broad query returns within the deadline for the default
code path").

Separately, the infrastructure for reading the on-disk store already exists:
`NotesChecklistStore` opens `NoteStore.sqlite` read-only, gunzips the protobuf
body blobs, and parses them on every `notes read` (to recover checklist/link
state). The same primitives serve search.

## Decision

Retire the AppleScript search path entirely. Serve **both** modes of
`notes search` by reading `NoteStore.sqlite` directly (`NotesStoreSearch`), the
same store and gunzip path `NotesChecklistStore` already uses:

- **Default (title):** SQL `ZTITLE1 LIKE ? ESCAPE '\'` — ~10ms, no
  decompression. LIKE wildcards in the query are escaped so they match
  literally.
- **`full_text` (opt-in, new boolean param):** title OR gunzipped-body substring
  scan in Swift — ~200ms for a full-store sweep, independent of match breadth.

Results are ordered newest-first by `ZMODIFICATIONDATE1`. Note ids are
reconstructed as `x-coredata://<Z_METADATA.Z_UUID>/ICNote/p<Z_PK>` so a search
hit feeds straight back into `read`. Pagination (`offset`/`limit`) and the JSON
output schema are unchanged; `full_text` is a new **input** param only.

Measured after the change: broad `a` default 0.3s, `full_text` 0.36s — both
~150× under the deadline.

## Alternatives considered

### Name-first fast path (issue's leading proposal): default `name contains` via AppleScript, gate `plaintext contains` behind a flag
- **Pros:** smallest diff; default path stays real-time (AppleScript reads live
  Notes state, no store-flush lag).
- **Cons:** **doesn't fix the bug.** Measured: `name contains` alone still times
  out at ~2000 matches because the `whose` filter is O(matches) over Apple
  events. Fails acceptance criterion #1. Rejected once the benchmark disproved
  the "name is cheap" premise.

### Opt-in AppleScript `plaintext contains` (full-text via the slow clause, behind the flag)
- **Pros:** real-time; no new schema coupling.
- **Cons:** still O(store); a broad `full_text` query still times out. Treats the
  symptom. Rejected.

### Raise/route the deadline for Notes search
- **Pros:** trivial.
- **Cons:** the query is genuinely O(store)/O(matches); a longer deadline just
  makes the tool slow instead of failing. Doesn't scale with store size.
  Rejected.

### Build/maintain our own search index (e.g. SQLite FTS5 sidecar)
- **Pros:** sub-ms repeat queries.
- **Cons:** the first build *is* the full O(store) scan we're avoiding, so it
  buys nothing for the first query; adds persistent state and cache invalidation
  (the store isn't real-time — when did iCloud sync?) to a tool that is
  otherwise stateless. The direct scan is already ~200ms, so an index optimizes
  a non-problem. Explicitly a non-goal in the issue. Rejected; revisit only if a
  store ever proves too large for the live scan (the benchmark is the gate).

### Direct store read for both modes (chosen)
- **Pros:** fixes the timeout for *every* query shape; one backend; reuses
  proven `NotesChecklistStore` primitives; full-text is a strict superset of
  title; faster than the old AppleScript path even for narrow queries.
- **Cons:** couples search to Apple's private Core Data schema (already a
  dependency via `NotesChecklistStore`); **not real-time** — a note
  created/renamed seconds ago may not match until Notes flushes to the store.

## Consequences

- Search now reads the on-disk store instead of querying the live Notes app.
  **Search results can lag a just-written note** by Notes' flush cadence
  (seconds). Mitigation: callers needing a fresh note `read` it by id/title,
  which stays real-time via AppleScript. Documented on `NotesStoreSearch` and in
  the `full_text` param description.
- New input param `full_text` (boolean, default false) on the `notes` tool.
  Output schema unchanged. Per release policy this is a new feature → minor
  version bump + release tag.
- Coupling to the private schema (`ZICCLOUDSYNCINGOBJECT`, `ZICNOTEDATA`,
  `Z_METADATA`) now backs search as well as read. If Apple changes the schema,
  `NotesStoreSearch.search` returns `[]` (best-effort, like
  `NotesChecklistStore`) rather than throwing — search degrades to empty, it
  doesn't crash.
- Encrypted/password-protected notes (whose body won't gunzip) are skipped under
  `full_text`. Title search still finds them (titles aren't encrypted).
- The slow AppleScript search machinery is deleted; `bench/` retains the
  benchmark that documents the before/after and gates any future index decision.
