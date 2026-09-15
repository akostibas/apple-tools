# ADR-0004: Support macOS versions by probing stores, not by branching on the OS version

- Status: Accepted
- Date: 2026-09-15

## Context

Roughly half of apple-tools reads Apple's private on-disk stores directly —
`chat.db`, `NoteStore.sqlite`, `Photos.sqlite`, the Podcasts Core Data store,
Mail's envelope index. Those schemas are undocumented and Apple changes them
without notice.

The macOS 27 upgrade changed two of them:

- Podcasts moved episode duration out of `ZMTEPISODE` into a separate
  `ZMTMEDIAENCLOSURE` row.
- Photos deleted `psi.sqlite`, the ML-label index backing keyword search,
  replacing it with `leo.sqlite` (FTS5) and a binary Spotlight index.

Both failed **silently**: an empty result with exit 0, indistinguishable from
"you genuinely have no podcast history" or "no photos match that word."
`apple-tools permissions` reported everything green throughout, because it
checks that a store can be *opened*, which says nothing about whether it can be
*read*. The breakage surfaced only because a person ran a manual sweep after
upgrading.

The obvious per-bug fix — read the new location instead — would have moved the
breakage onto anyone still on macOS 26. `AppleToolsLib` is consumed as a SwiftPM
dependency (`probe-macos`), and those consumers upgrade macOS on their own
schedule, so we cannot assume everyone moves together. That made "how do we
support more than one macOS at a time" a prerequisite to fixing either bug
(issue #68).

## Decision

**1. Support the current and previous macOS release.** Today that is 26 and 27.
When 28 ships, 26 support may be dropped, and the drop is a minor version bump
because it is a breaking change for someone.

**2. Detect schema shape by probing what is present, never by branching on the
OS version.** A tool asks the store what columns and tables it has
(`PRAGMA table_info`, file existence) and adapts. No code reads
`ProcessInfo.operatingSystemVersion` to decide how to query.

The reason is concrete: Apple ships store changes in *point* releases, and
iCloud-synced stores can be migrated by a sync from another device that is
already on the newer OS. The OS version is therefore not a reliable proxy for
the schema on disk. Probing is also what lets one binary serve both 26 and 27
with no build-time flags.

**3. Required columns mean required.** A column a query can function without
belongs in an optional probe, not in the required set. The Podcasts break was
not really a schema change — it was `ZDURATION` sitting in the required set
while only feeding a cosmetic `percent` field, so an optional column going
missing killed the whole source. Before adding a column to a validator, ask
whether a result without it is still worth returning.

**4. An unrecognized store is an error, never an empty success.** When a reader
cannot make sense of what it finds, it says so — a non-empty error naming the
store and the reason. An empty list is reserved exclusively for a query that
genuinely matched nothing. This is the invariant that matters most: a caller
(usually an LLM) cannot otherwise distinguish "you have none" from "we could not
look," and will confidently report the former.

**5. Lost capability is distinct from denied permission.** Tools declare
`degradations()` — things they cannot do on this machine for reasons that are
not permissions. `apple-tools permissions` renders these as `⚠` and exits 3,
separate from denied (exit 2), and says explicitly that it is an OS change so a
reader does not go hunting in System Settings.

## Alternatives considered

### Branch on the OS version (`if #available` / `operatingSystemVersion`)
- **Pros:** explicit and greppable; easy to see which code serves which OS; no
  per-query probe cost.
- **Cons:** the OS version does not reliably predict the schema — point releases
  change stores, and an iCloud sync from a device on a newer OS can migrate a
  store under an older OS. Every new macOS needs a code change even when nothing
  moved, and an unrecognized future version has no sensible branch to take.
  Rejected.

### Support only the current macOS
- **Pros:** simplest possible rule; no compatibility code at all; the smallest
  surface to test.
- **Cons:** breaks library consumers the day we upgrade our own dev machine,
  which is exactly backwards — they upgrade on their schedule, not ours. Would
  have made the macOS 27 sweep a breaking release for anyone still on 26 with no
  warning. Rejected.

### Detect once at startup and cache a "schema generation" constant
- **Pros:** probe cost paid once; a single place to reason about which shape we
  are on.
- **Cons:** invents a version concept Apple does not publish, so the mapping
  from generation to actual schema is our guess and rots the same way version
  branching does. Stores can also differ in shape independently — Photos moving
  does not imply Podcasts moved — so one generation number cannot describe them.
  Rejected as an abstraction over a thing we do not actually know.

### Probe per query, adapt, fail loudly when unrecognized (chosen)
- **Pros:** one binary serves every OS including ones that do not exist yet;
  degrades per-capability rather than per-tool (a missing duration column costs
  the `percent` field, not the podcast source); correct under point-release and
  iCloud-migration drift; the probe is a `PRAGMA` on an already-open handle, so
  the cost is negligible.
- **Cons:** the adaptive branches are only exercised on whichever OS the
  developer is running — the macOS 26 paths are now untested in practice, and
  fixture tests stand in for a machine we no longer have. Probing also cannot
  *restore* a capability: when Apple replaces an index wholesale, as Photos did,
  probing detects the loss but someone still has to write the new reader.

## Consequences

- Photos content search and Podcasts recency both follow this policy as of the
  macOS 27 sweep, and both are covered by fixture tests for the 26 and 27 shapes
  so the older path does not rot unnoticed.
- Photos keyword search is restored against `leo.sqlite`. It was reported
  unavailable at first, correctly: both its tables were still empty while Photos
  reindexed, and decoding the packed `lexeme_ids` BLOB from an empty table would
  have been guesswork. Once the reindex populated it the format was legible in
  minutes. Worth remembering that "unavailable" was the right answer for a few
  hours and the wrong one after — which is an argument for re-probing rather
  than recording a capability as permanently lost.
- **Existing readers do not yet meet point 4.** An audit of all nine
  direct-store readers found the silent-empty failure mode still present:
  `NotesStoreSearch` returns `[]` when `sqlite3_prepare_v2` fails on its
  *primary* search query, so a schema change means `notes search` reports
  "nothing matched" indefinitely; `RemindersDB` does the same on its subtask
  enrichment, where its own doc comment already admits it conflates no-subtasks,
  cannot-open, and schema-mismatch. `IMessageIntegration`'s preflight has the
  open-proves-nothing problem this ADR opens with. `EmailSearch` throws on both
  open and prepare failure and is the model to copy. Bringing the rest in line
  is the remaining work on issue #67.

  Worth recording how this was missed the first time: the initial audit grepped
  for `PRAGMA table_info` and concluded only three integrations were affected.
  That search finds the readers that already *validate* — precisely the ones
  least at risk — while readers with no validation at all never appear. Audit
  for the failure mode (`sqlite3_open`), not for the guard.
- **We still have no automated way to learn that an OS update broke something.**
  Everything above improves what happens *once a break is detected*; nothing
  detects it. Today that took a hand-run sweep of 15 tools, and the two failures
  found were both invisible to `permissions`. This is the largest open gap in
  the policy, and the reason the compatibility rows in
  `docs/tools/COMPATIBILITY.md` are pinned to an OS build and a date rather than
  asserted as true.
- Dropping the previous macOS release is a minor version bump under the pre-1.0
  scheme, and consumers find out through `swift package update` rather than a
  runtime failure.
