# reminders — Reminders

Manage Apple Reminders through EventKit: browse lists, search and read
reminders, create new reminders and lists, and mark reminders done. Writes go
straight to the Reminders store (no review step).

**Access:** read/write
**Permissions:** Reminders (TCC). The first write triggers the system dialog;
grant in System Settings → Privacy & Security → Reminders.

## Actions

- **lists** — list every reminder list with its `id`, flagging the default list
  for new reminders (`is_default`).
- **search** — find reminders by any of `query` (case-insensitive substring over
  title + notes), `list_name`, or a `due_date` / `due_date_end` range; completed
  reminders are excluded unless `show_completed` is set. Results include parent /
  subtask links pulled from the Reminders database.
- **get** — full detail for a single reminder by `id`, including untruncated
  notes and its parent / subtasks.
- **create** — add a top-level reminder (`title` required; optional `list_name`,
  `due_date`, `notes`). Falls back to the default list when `list_name` is
  omitted.
- **create-list** — make a new reminder list (`name` required; optional `account`
  to pick the holding source, e.g. iCloud). Rejects a duplicate name.
- **complete** — mark a reminder done by `id`.

Run `apple-tools reminders --help` for the exact parameters of each action.

## Examples

```bash
apple-tools reminders lists
apple-tools reminders search --list_name "Groceries"
apple-tools reminders search --query "call" --due_date 2026-07-10T00:00:00Z
apple-tools reminders create --title "Renew passport" --list_name "Errands" --due_date 2026-08-01T09:00:00Z
```

## Shortcomings

- **You cannot create sub-tasks / nested reminders.** `create` only ever makes
  a top-level reminder — `createReminder` sets title, list, due date, and notes
  and nothing else, with no parent parameter. Subtask relationships are *read*
  (enriched from the Reminders SQLite DB in `search`/`get`), but there is no way
  to *write* one.
- **No edit / reschedule.** Once created, a reminder can't be changed — there is
  no update action, so title, due date, notes, list, and priority are fixed at
  creation. The only post-create mutation is `complete`.
- **No delete.** Neither reminders nor lists can be removed; the tool exposes no
  delete action.
- **`complete` is one-way.** It sets `isCompleted = true` and stamps a completion
  date; there is no un-complete / reopen action.
- **No recurring reminders, alarms, priority, or URL on create.** `createReminder`
  sets no recurrence rule, alarm, priority, or URL. Priority is *reported* when
  present (high/medium/low), but you can't *set* it here.
- **Search keyword matching is a plain substring on title + notes only.** No
  fuzzy/token matching and no matching on other fields; a `query` word that isn't
  a literal substring of the title or notes won't match. Notes in `search`
  results are also truncated to ~100 chars (use `get` for the full text).
- **A lone `due_date` means "due that whole day," not "due at that instant."**
  When `due_date` is given without `due_date_end`, the range is bounded to
  23:59:59 of that day, so the filter returns everything due that day. A lone
  `due_date_end` stays open at the bottom (everything due at or before it).
- **Due dates are floating wall-clock — no time zone.** Emitted as
  `YYYY-MM-DDTHH:MM:SS` (or `YYYY-MM-DD` for date-only), with zone stripped
  deliberately; the caller must label/interpret them, and they won't shift
  across zones.
- **Name lookups are case-insensitive and can be ambiguous.** `list_name` matches
  every list whose title equals it (case-insensitively): `search` spans all such
  lists, but `create` silently uses the *first* match. Likewise `create-list
  --account` matches source titles case-insensitively.
```
