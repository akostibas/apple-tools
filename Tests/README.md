# Tests

One command runs everything: `make test`. It runs groups of tests and reports
each one separately, because they fail for different reasons.

```bash
make test                  # unit + read-only (the default, a minute or two)
make test-unit             # unit only; this is what pre-commit runs
make test-slow             # unit + read-only + slow
make test-attended         # everything, including tests that need you at the screen
make test-slow TOOL=notes  # any target, limited to one tool (or TOOL=notes,calendar)
make test-refresh          # re-discover the read-only group's remembered items
```

| Group | What it touches | A failure means |
|---|---|---|
| **unit** | Fixtures only. Passes on any machine. | Our code is wrong. |
| **read-only** | Reads this Mac's real data. Changes nothing. | Items this Mac had before can't be found: Apple moved a store, or you removed them. Look in the app to tell which. |
| **slow** | Creates data labeled `apple-tools live test`, reads it back, changes it, removes it. Nothing appears on screen. | A real action misbehaves against the real app. |
| **attended** | Tests that put a window or dialog in front of you, or change what you hear. | Same as slow. None are written yet. |

## How the read-only group knows what to look for

On its first run it lists what is on this Mac (a few note titles, contacts,
recent episodes, and so on) and remembers them in
`~/Library/Application Support/apple-tools/live-targets.json`. That file is
yours: it is outside the repo and never committed. Later runs check that the
remembered items can still be found. Losing some is normal; losing all of them
for a tool is the alarm.

- **"Nothing to check"** is a skip, not a pass. It means the tool found nothing
  and has no memory to compare with, so it can't tell "this Mac has none" from
  "the lookup is broken". The message says how to settle it: run that tool's
  slow test, or look in the app.
- **`--refresh`** replaces the remembered items. Use it only after you have
  confirmed the data really changed. A refresh that finds nothing keeps the old
  memory and still fails.
- Mail and Music reads are skipped while that app is closed, because reading
  would open it in front of you.

## What a run leaves behind

The slow and attended groups remove what they create, even when a test fails.
This is everything that still remains afterwards, so you can decide whether you
want to run them. `make test-slow` prints this list before it starts. The unit
and read-only groups leave nothing.

<!-- One line per tool, as "- **tool:** ...". A unit test requires a line for every tool with a write test. -->
- **clipboard:** nothing. Whatever was on the clipboard is put back, including images and files.
- **contacts:** nothing.
- **email:** one draft labeled `apple-tools live test` in the Trash of your default mail account.
- **music:** nothing.
- **notes:** four empty folders, `AppleToolsLive A`, `AppleToolsLive B`, `AppleToolsLive C` and `AppleToolsFmtLive`. A scripted folder delete comes back through iCloud, so they are reused on every run.
- **open_uri:** attended only. A Finder window showing a temporary folder may stay open.
- **reminders:** nothing.

## Adding an action

Every action a tool declares needs a live test, or a written reason why not.
`LiveCoverageTests` (a unit test, so pre-commit runs it) fails otherwise.

- Start the test with `try LiveTest.reads("tool", "action")`,
  `LiveTest.writes(...)` or `LiveTest.attended(...)`. The names must be string
  literals; the rule reads them from the source.
- A tool with a `writes` or `attended` test needs a line under *What a run
  leaves behind* above, even if that line says "nothing".
- An action that changes data may not be claimed by a `reads` test.
- If it truly can't be tested, add it to `LiveExemptions.exempt` with the reason.
  `LiveExemptions.owed` is the list of tests not written yet, and should only
  shrink.

The rule proves a test claims the action, not that the test is thorough.
