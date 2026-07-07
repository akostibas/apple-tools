# calendar — Calendar

Read and create Apple Calendar events across every EventKit account. Lists
calendars, views events in a date range, searches by keyword, and adds new
events — including RSVP/attendee detail so you can answer questions about
invites and meetings.

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
  `calendar_name` (defaults to the default calendar), `location`, `notes`. Does
  **not** send invites.

Each returned event carries `is_organizer`, `my_status` (the current user's
RSVP), and an `attendees` array plus `organizer`.

Run `apple-tools calendar --help` for the exact parameters of each action.

## Examples

```bash
apple-tools calendar calendars
apple-tools calendar list --start 2026-07-07T00:00:00Z --end 2026-07-14T00:00:00Z
apple-tools calendar search --query "standup" --dedupe_by_id true
apple-tools calendar create --title "Dentist" --start 2026-07-10T15:00:00Z --end 2026-07-10T16:00:00Z --location "123 Main St"
```

## Shortcomings

- **No edit or delete.** The only actions are `calendars`, `list`, `search`, and
  `create` (see the `handle` switch). There is no way to modify a time,
  reschedule, cancel, or delete an event — an accidental `create` can only be
  fixed in Calendar.app.
- **`create` never sends invites and can't add attendees.** The description
  states "'create' does not send invites," and `createEvent` sets only
  title/start/end/calendar/location/notes — there is no attendee parameter, so
  you cannot invite anyone or run a meeting through this tool.
- **No recurring events.** `createEvent` builds a single `EKEvent` and saves with
  `span: .thisEvent`; there is no recurrence-rule parameter, so every created
  event is one-off. (Reading a recurring series returns its individual
  occurrences.)
- **No all-day, alarms, URL, or availability on create.** `createEvent` sets no
  `isAllDay`, alarms, `url`, or availability, so every created event is a plain
  timed event with none of these — even though read events surface `all_day`,
  `url`, and RSVP fields.
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
- **Zone-less dates are treated as local time.** `parseDate` accepts
  `yyyy-MM-dd[THH:mm:ss]` without a `Z` and interprets it in the machine's local
  timezone, so omitting the offset can shift an event's real time.
- **`dedupe_by_id` changes the output schema.** Only in de-duped output is the
  singular `calendar` field replaced by a `calendars` array (per the tool
  description), so consumers must handle both shapes depending on the flag.
```
