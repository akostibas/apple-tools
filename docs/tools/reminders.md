# reminders — Reminders

Manage Apple Reminders through EventKit: browse lists, search and read
reminders, create, change, and delete reminders, create lists, and mark reminders done. Writes go
straight to the Reminders store (no review step).

**Access:** read/write
**Permissions:** Reminders (TCC). The first write triggers the system dialog;
grant in System Settings → Privacy & Security → Reminders.

## Actions

- **lists** — list every reminder list with its `id`, flagging the default list
  for new reminders (`is_default`).
- **search** — find reminders by any of `query` (case-insensitive substring over
  title + notes), `list_name`, a `due_date` / `due_date_end` range, or `flagged`
  (only flagged reminders); completed reminders are excluded unless
  `show_completed` is set. Every result carries `is_flagged`; results also
  include parent / subtask links pulled from the Reminders database.
- **get** — full detail for a single reminder by `id`, including untruncated
  notes, `is_flagged`, and its parent / subtasks.
- **create** — add a top-level reminder (`title` required; optional `list_name`,
  `due_date`, `notes`, `priority`, `flagged`, `recurrence`). Falls back to the
  default list when `list_name` is omitted.
- **update** — change any of those fields on a reminder by `id`; `due_date none`
  and `recurrence none` clear them. A repeating reminder must keep a due date.
- **delete** — remove a reminder by `id`. A repeating reminder is removed
  entirely; reminders have no per-occurrence copies to delete one of.
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
apple-tools reminders create --title "Take out trash" --due_date 2026-10-13T19:00:00Z --recurrence "FREQ=WEEKLY;BYDAY=TU"
apple-tools reminders update --id <id> --due_date 2026-10-16T09:00:00Z --flagged true
apple-tools reminders delete --id <id>
```

## Shortcomings

- **You cannot create sub-tasks / nested reminders.** `create` only ever makes
  a top-level reminder — `createReminder` sets title, list, due date, and notes
  and nothing else, with no parent parameter. Subtask relationships are *read*
  (enriched from the Reminders SQLite DB in `search`/`get`), but there is no way
  to *write* one.
- **Lists can't be deleted or renamed.** Only reminders can be changed.
- **Read-only lists are refused.** `update`/`delete` on a reminder in a list you
  can't edit (e.g. a shared list without edit rights) errors rather than trying.
- **Flag writes go through Reminders.app scripting.** EventKit has no flag API,
  so `flagged` on create/update needs Automation permission for Reminders; if it
  fails the rest of the change is already saved and the error says so.
- **`complete` is one-way.** It sets `isCompleted = true` and stamps a completion
  date; there is no un-complete / reopen action.
- **No alarms or URL.** Neither can be set. Flag state has no public EventKit API, so it's read
  from the Reminders SQLite DB (like subtasks). If that DB is unreadable, the
  reminders still come back but `is_flagged`, `parent`, and `subtasks` are
  *omitted* and a `warnings` entry says why — they're never reported as absent.
  `--flagged` is an error in that case, since the filter would otherwise return
  a confident, empty, wrong answer.
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
