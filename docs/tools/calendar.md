# calendar — Calendar

Read and write Apple Calendar events across every EventKit account. Lists
calendars, views events in a date range, searches by keyword, and creates,
changes, and deletes events (including repeating ones). Reads include
RSVP/attendee detail so you can answer questions about invites and meetings.

**Access:** read/write
**Permissions:** Calendar (EventKit full access; the first use triggers the
system dialog).

## Actions

- **calendars** — list all event calendars: `name`, `id`, `type`
  (local/caldav/exchange/subscription/birthday), color, and which is the
  default for new events.
- **list** — events in a date range. `start`/`end` are ISO 8601 (defaults to
  today only); optional `calendar_name` to scope; `dedupe_by_id=true` collapses
  the same shared event across calendars into one row.
- **search** — events matching a `query` keyword (matches title, notes,
  location, and attendee names) within `start`/`end` (defaults to −30…+30 days);
  same `calendar_name` and `dedupe_by_id` options as `list`.
- **create** — add an event: `title`, `start`, `end` required; optional
  `calendar_name` (defaults to the default calendar), `location`, `notes`,
  `all_day`. Does **not** send invites. Bare dates (`2026-08-26`) on both ends
  make a true all-day event without the flag; `end` is then the **last day,
  inclusive** — `2026-08-26` to `2026-08-27` covers both days. `recurrence`
  takes an RFC 5545 RRULE (`FREQ=MONTHLY;BYDAY=2TU,4TU`) or plain
  `daily`/`weekly`/`monthly`/`yearly`; `event_timezone` (IANA) pins a timed event's
  wall-clock time across DST and is the zone offset-less times are read in.
- **update** — change an event by `id`: any of the fields `create` takes. An
  empty `location`/`notes` clears it; `recurrence none` stops repeating.
- **delete** — remove an event by `id`.

**Repeating events.** Every occurrence shares one `id`, so `update`/`delete`
also need `occurrence` (its listed start, or just its date) and take `span`:
`this` (default) — only that occurrence; `future` — it and every later one;
`all` — the whole series. With `span all`, a new `start` is read as "this
occurrence moves to X" and the whole series shifts by the same amount. Changing
the repeat rule or calendar needs `future` or `all`.

**Refusals.** `update`/`delete` refuse events you didn't organize (invites):
changing one locally can be silently reverted at the next sync, and deleting
it can send the organizer a decline. They also refuse read-only calendars
(subscriptions, Birthdays). Use Calendar.app for those.

Each returned event carries `is_organizer`, `my_status` (the current user's
RSVP), an `attendees` array plus `organizer`, and `recurrence` (the series'
RRULE) when it repeats.

Run `apple-tools calendar --help` for the exact parameters of each action.

## Examples

```bash
apple-tools calendar calendars
apple-tools calendar list --start 2026-07-07T00:00:00Z --end 2026-07-14T00:00:00Z
apple-tools calendar search --query "standup" --dedupe_by_id true
apple-tools calendar create --title "Dentist" --start 2026-07-10T15:00:00Z --end 2026-07-10T16:00:00Z --location "123 Main St"
apple-tools calendar create --title "Staging refresh" --start 2026-10-13T03:00:00 --end 2026-10-13T04:00:00 \
  --event_timezone America/New_York --recurrence "FREQ=MONTHLY;BYDAY=2TU,4TU"
apple-tools calendar update --id <id> --occurrence 2026-10-27 --start 2026-10-27T05:00:00   # just that one
apple-tools calendar delete --id <id> --span all
```

## Shortcomings

- **`create` never sends invites and can't add attendees.** There is no
  attendee parameter, so you cannot invite anyone or run a meeting through this
  tool. Answering invites (accept/decline) isn't possible either: EventKit
  exposes RSVP status read-only.
- **Invites can't be changed or deleted** — by design, see Refusals above.
- **Only one repeat rule per event**, and only what EventKit can represent:
  no `BYHOUR`/`BYMINUTE`/`BYWEEKNO`/`BYYEARDAY`, no `EXDATE` (skip a date by
  deleting that occurrence instead).
- **Changing a series' time brings back deleted occurrences** (an EventKit
  limitation). They aren't re-deleted, since the user may want them at the new
  time; the result's `notice` lists the dates (looking up to two years ahead).
- **Moving one occurrence to another calendar is refused**; move the series.
- **No alarms, URL, or availability on create/update.** `createEvent` sets no alarms,
  `url`, or availability, so a created event carries none of these — even though
  read events surface `url` and RSVP fields.
- **Calendar names must match exactly (case-insensitively).** `resolveCalendars`
  filters on `title.lowercased() == name.lowercased()`, not a substring match, so
  a partial or misspelled `calendar_name` yields "no calendar found" rather than
  a fuzzy hit. When several calendars share a name, `create` silently picks the
  first match.
- **`list` defaults to a single day.** With no `end`, `listEvents` sets `end` to
  23:59:59 of the `start` day (and `start` defaults to today), so a bare
  `list` shows only today — a longer horizon needs an explicit `end`.
- **`search` is a substring scan within a bounded window.** Matching is a
  case-insensitive `contains` over title/notes/location/attendee-name only (not
  organizer email, URL, or fuzzy terms), and only over events between `start`
  and `end` (default −30…+30 days) — anything outside that window is silently
  missed.
- **Zone-less dates are treated as local time** unless `event_timezone` is passed.
  `parseDate` accepts `yyyy-MM-dd[THH:mm:ss]` without a `Z` and interprets it in
  the machine's zone, so omitting both can shift an event's real time.
- **`dedupe_by_id` changes the output schema.** Only in de-duped output is the
  singular `calendar` field replaced by a `calendars` array (per the tool
  description), so consumers must handle both shapes depending on the flag.
```
