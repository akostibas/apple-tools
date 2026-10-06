import EventKit
import Foundation

public struct CalendarTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "calendar",
        description: "Access Apple Calendar events. Use 'calendars' to list calendars, 'list' to view events in a date range, 'create' to add an event, 'search' to find events by keyword. Each returned event includes 'is_organizer', 'my_status' (accepted/declined/tentative/pending — the current user's RSVP), and an 'attendees' array of {name, email, status} (plus 'organizer') — use these to answer questions about invites, RSVPs, and meetings the user is running. For 'list'/'search', pass dedupe_by_id=true to collapse the same shared event that appears on multiple calendars into one row carrying a 'calendars' array (the singular 'calendar' field is replaced by 'calendars' only in de-duped output). Note: 'create' does not send invites. 'update' and 'delete' take the event 'id' from list/search; every occurrence of a repeating event shares that id, so also pass 'occurrence' (the occurrence's start, or just its date) and 'span' (this = only that occurrence, the default; future = it and all later ones; all = the whole series). They refuse events the user didn't organize (invites) and read-only calendars.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "calendars, list, search, create, update, or delete"),
                "calendar_name": PropertySchema(type_: "string", description: "Calendar name to filter by (for list, search), create in (for create), or move the event to (for update)",
                    summary: "Calendar to filter by (list/search), create in (create), or move to (update)", actions: ["list", "search", "create", "update"]),
                "start": PropertySchema(type_: "string", description: "Start date/time, ISO 8601 e.g. 2026-04-15T09:00:00Z (required for create; for list defaults to start of today; for search defaults to 30 days ago; for update the new start of the chosen occurrence — with span=all the whole series shifts by the same amount). For an all-day event pass a bare date, 2026-04-15. A time without an offset is read in 'event_timezone' (or the Mac's zone).",
                    summary: "Start date/time, ISO 8601 (e.g. 2026-04-15T09:00:00Z)", actions: ["list", "search", "create", "update"]),
                "end": PropertySchema(type_: "string", description: "End date/time, ISO 8601 (required for create; for list defaults to end of start day; for search defaults to 30 days from now). For an all-day event pass a bare date — it is the LAST day, inclusive: 2026-04-15 to 2026-04-16 covers both days, and a one-day event ends on its own date.",
                    summary: "End date/time, ISO 8601", actions: ["list", "search", "create", "update"]),
                "title": PropertySchema(type_: "string", description: "Event title (required for create)",
                    summary: "Event title", actions: ["create", "update"]),
                "location": PropertySchema(type_: "string", description: "Event location (for create, update; empty string clears on update)",
                    summary: "Event location", actions: ["create", "update"]),
                "notes": PropertySchema(type_: "string", description: "Event notes (for create, update; empty string clears on update)",
                    summary: "Event notes", actions: ["create", "update"]),
                "all_day": PropertySchema(type_: "boolean", description: "For create: make a true all-day event (banner at the top of the day) instead of a timed one. Inferred when start and end are both bare dates, so pass it explicitly only to force the flag.",
                    summary: "Make it a true all-day event (or false to make it timed)", actions: ["create", "update"]),
                "recurrence": PropertySchema(type_: "string", description: "Repeat rule for create/update, RFC 5545 RRULE: e.g. FREQ=WEEKLY;BYDAY=MO,WE,FR or FREQ=MONTHLY;BYDAY=2TU,4TU (2nd and 4th Tuesday) or FREQ=DAILY;INTERVAL=2;COUNT=10. Plain daily/weekly/monthly/yearly also work. Supports FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS. On update pass 'none' to stop repeating; changing it needs span future or all.",
                    summary: "Repeat rule (RRULE, e.g. FREQ=WEEKLY;BYDAY=MO,WE or 'daily'); 'none' removes", actions: ["create", "update"]),
                "event_timezone": PropertySchema(type_: "string", description: "IANA timezone for a timed event, e.g. America/New_York. The event keeps that wall-clock time across daylight-saving changes, and start/end without an offset are read in it. Defaults to the Mac's zone.",
                    summary: "Event timezone, IANA (e.g. America/New_York)", actions: ["create", "update"]),
                "id": PropertySchema(type_: "string", description: "Event id from list/search (required for update, delete)",
                    summary: "Event id from list/search", actions: ["update", "delete"]),
                "occurrence": PropertySchema(type_: "string", description: "For a repeating event: which occurrence to update/delete — its start as listed (2026-10-13T07:00:00Z) or just its date (2026-10-13). Required unless span=all.",
                    summary: "Which occurrence of a repeating event (its start or date)", actions: ["update", "delete"]),
                "span": PropertySchema(type_: "string", description: "For a repeating event: this (only the chosen occurrence, default), future (it and every later one), or all (the whole series)",
                    summary: "this (default), future, or all", actions: ["update", "delete"]),
                "query": PropertySchema(type_: "string", description: "Search keywords, matched across title/notes/location/attendees (required for search). Multi-word queries are AND-of-terms: every word must appear in some field, in any order.",
                    summary: "Search keywords (AND-of-terms)", actions: ["search"]),
                "dedupe_by_id": PropertySchema(type_: "boolean", description: "For list/search: collapse the same event appearing on multiple calendars into one row with a 'calendars' array (opt-in; default false)",
                    summary: "Collapse an event on multiple calendars into one row (default false)", actions: ["list", "search"]),
            ],
            required: ["action"]
        ),
        cliSummary: "List, search, create, update, and delete Apple Calendar events.",
        actions: [
            ActionHelp(name: "calendars", summary: "List available calendars",
                example: "apple-tools calendar calendars"),
            ActionHelp(name: "list", summary: "View events in a date range",
                example: "apple-tools calendar list [--start <d>] [--end <d>] [--calendar_name <n>] [--dedupe_by_id]"),
            ActionHelp(name: "search", summary: "Find events by keyword",
                example: "apple-tools calendar search --query <text> [--start <d>] [--end <d>] [--calendar_name <n>] [--dedupe_by_id]", required: ["query"]),
            ActionHelp(name: "create", summary: "Add an event (does not send invites)",
                example: "apple-tools calendar create --title <t> --start <d> --end <d> [--all_day] [--location <l>] [--notes <n>] [--calendar_name <n>] [--recurrence <rrule>] [--event_timezone <tz>]", required: ["title", "start", "end"]),
            ActionHelp(name: "update", summary: "Change an event you organize",
                example: "apple-tools calendar update --id <id> [--occurrence <d>] [--span this|future|all] [--title <t>] [--start <d>] [--end <d>] ...", required: ["id"]),
            ActionHelp(name: "delete", summary: "Delete an event you organize",
                example: "apple-tools calendar delete --id <id> [--occurrence <d>] [--span this|future|all]", required: ["id"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "calendars": .read,
        "list":      .read,
        "search":    .read,
        "create":    .readWrite,
        "update":    .readWrite,
        "delete":    .readWrite,
    ])

    public init() {}

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard CalendarIntegration.requestAccess() else {
            return (CalendarIntegration.CalendarError.accessDenied.description, true)
        }

        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "calendars":
            return listCalendars()
        case "list":
            let calendarName = params?["calendar_name"]?.value as? String
            let start = params?["start"]?.value as? String
            let end = params?["end"]?.value as? String
            let dedupe = (params?["dedupe_by_id"]?.value as? Bool) ?? false
            return listEvents(calendarName: calendarName, start: start, end: end, dedupe: dedupe)
        case "create":
            guard let title = params?["title"]?.value as? String, !title.isEmpty else {
                return ("missing required parameter: title", true)
            }
            guard let startStr = params?["start"]?.value as? String else {
                return ("missing required parameter: start", true)
            }
            guard let endStr = params?["end"]?.value as? String else {
                return ("missing required parameter: end", true)
            }
            let calendarName = params?["calendar_name"]?.value as? String
            let location = params?["location"]?.value as? String
            let notes = params?["notes"]?.value as? String
            let allDay = params?["all_day"]?.value as? Bool
            return createEvent(title: title, start: startStr, end: endStr, allDay: allDay, calendarName: calendarName, location: location, notes: notes,
                               recurrence: params?["recurrence"]?.value as? String, timeZone: params?["event_timezone"]?.value as? String)
        case "update", "delete":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let spanStr = (params?["span"]?.value as? String) ?? "this"
            guard let span = Span(rawValue: spanStr) else {
                return ("invalid span: \(spanStr) (use this, future, or all)", true)
            }
            let occurrence = params?["occurrence"]?.value as? String
            return action == "delete"
                ? deleteEvent(id: id, occurrence: occurrence, span: span)
                : updateEvent(id: id, occurrence: occurrence, span: span, params: params ?? [:])
        case "search":
            guard let query = params?["query"]?.value as? String, !query.isEmpty else {
                return ("missing required parameter: query", true)
            }
            let calendarName = params?["calendar_name"]?.value as? String
            let start = params?["start"]?.value as? String
            let end = params?["end"]?.value as? String
            let dedupe = (params?["dedupe_by_id"]?.value as? Bool) ?? false
            return searchEvents(query: query, calendarName: calendarName, start: start, end: end, dedupe: dedupe)
        default:
            return ("unknown action: \(action) (use calendars, list, search, create, update, or delete)", true)
        }
    }

    public func preflight() -> (ok: Bool, message: String) {
        return CalendarIntegration.preflight()
    }

    // MARK: - Calendars

    private func listCalendars() -> (String, Bool) {
        let calendars = CalendarIntegration.allCalendars()
        let defaultCal = CalendarIntegration.defaultCalendarForNewEvents()
        let results = calendars.map { cal -> [String: Any] in
            var entry: [String: Any] = [
                "name": cal.title,
                "id": cal.calendarIdentifier,
                "type": calendarTypeLabel(cal.type),
            ]
            if let color = cal.cgColor {
                entry["color"] = colorHex(color)
            }
            if cal == defaultCal {
                entry["is_default"] = true
            }
            return entry
        }
        return (jsonString(results) ?? "[]", false)
    }

    // MARK: - List events

    private func listEvents(calendarName: String?, start: String?, end: String?, dedupe: Bool = false) -> (String, Bool) {
        let startDate: Date
        if let startStr = start {
            guard let d = CalendarIntegration.parseDate(startStr) else {
                return ("invalid start date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
            }
            startDate = d
        } else {
            startDate = Calendar.current.startOfDay(for: Date())
        }

        let endDate: Date
        if let endStr = end {
            guard let d = CalendarIntegration.parseDate(endStr) else {
                return ("invalid end date format", true)
            }
            endDate = d
        } else {
            endDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: startDate)
                ?? startDate.addingTimeInterval(86400)
        }

        var calendars: [EKCalendar]? = nil
        if let name = calendarName {
            guard let resolved = CalendarIntegration.resolveCalendars(name: name) else {
                return ("no calendar found with name: \(name)", true)
            }
            calendars = resolved
        }

        let events = CalendarIntegration.events(from: startDate, to: endDate, in: calendars)
        let results = formatEvents(events, dedupe: dedupe)
        let response: [String: Any] = [
            "count": results.count,
            "events": results,
        ]
        return (jsonString(response) ?? "{}", false)
    }

    // MARK: - Create

    private func createEvent(title: String, start: String, end: String, allDay: Bool?, calendarName: String?, location: String?, notes: String?,
                             recurrence: String?, timeZone tzName: String?) -> (String, Bool) {
        // Bare dates on both ends mean an all-day event; an explicit flag wins.
        // All-day spans whole local days (end inclusive), so anchor to the day
        // rather than the instant — EventKit takes the day containing endDate
        // as the last day.
        let isAllDay = allDay ?? (CalendarIntegration.isDateOnly(start) && CalendarIntegration.isDateOnly(end))
        do {
            let tz = try timeZone(named: tzName)
            let startDate = try parseTime(start, field: "start", allDay: isAllDay, timeZone: tz)
            let endDate = try parseTime(end, field: "end", allDay: isAllDay, timeZone: tz)

            var calendar: EKCalendar? = nil
            if let calendarName = calendarName {
                guard let cals = CalendarIntegration.resolveCalendars(name: calendarName), let cal = cals.first else {
                    return ("no calendar found with name: \(calendarName)", true)
                }
                calendar = cal
            }

            let rule = try recurrence.map { try CalendarRecurrence.parse($0, timeZone: tz ?? .current) }
            let event = try CalendarIntegration.createEvent(
                title: title,
                start: startDate,
                end: endDate,
                calendar: calendar,
                location: location,
                notes: notes,
                allDay: isAllDay,
                recurrence: rule,
                timeZone: isAllDay ? nil : tz
            )
            return (jsonString(writeResult(event)) ?? "{}", false)
        } catch {
            return (String(describing: error), true)
        }
    }

    // MARK: - Update / delete

    enum Span: String {
        case this, future, all
        var ek: EKSpan { self == .this ? .thisEvent : .futureEvents }
    }

    /// Resolve the event to change. For span=all on a repeating event the
    /// target is the series' first occurrence (EventKit has no "whole series"
    /// span); `anchor` is the occurrence the caller named, used to shift times.
    private func resolveTarget(id: String, occurrence: String?, span: Span) throws -> (target: EKEvent, anchor: EKEvent) {
        let anchor = try CalendarIntegration.findEvent(id: id, occurrence: occurrence)
        try CalendarIntegration.checkWritable(anchor)
        guard anchor.hasRecurrenceRules else { return (anchor, anchor) }
        if span == .all {
            return (try CalendarIntegration.findEvent(id: id, occurrence: nil), anchor)
        }
        guard occurrence != nil else {
            throw ToolError("\"\(anchor.title ?? "")\" repeats: pass occurrence (the start or date of the one you mean), or span=all for the whole series")
        }
        return (anchor, anchor)
    }

    private func updateEvent(id: String, occurrence: String?, span: Span, params: [String: AnyCodable]) -> (String, Bool) {
        func str(_ key: String) -> String? { params[key]?.value as? String }
        do {
            let (event, anchor) = try resolveTarget(id: id, occurrence: occurrence, span: span)
            let recurring = event.hasRecurrenceRules
            var changed = false

            if let title = str("title") {
                guard !title.isEmpty else { throw ToolError("title can't be empty") }
                event.title = title; changed = true
            }
            if let location = str("location") { event.location = location.isEmpty ? nil : location; changed = true }
            if let notes = str("notes") { event.notes = notes.isEmpty ? nil : notes; changed = true }

            let tz = try timeZone(named: str("event_timezone"))
            let start = str("start"), end = str("end")
            let given = [start, end].compactMap { $0 }
            // Explicit flag wins; otherwise a time-of-day means timed, bare dates mean all-day.
            let isAllDay = (params["all_day"]?.value as? Bool)
                ?? (given.isEmpty ? event.isAllDay : given.allSatisfy(CalendarIntegration.isDateOnly))
            if isAllDay != event.isAllDay { event.isAllDay = isAllDay; changed = true }
            if let tz = tz, !isAllDay { event.timeZone = tz; changed = true }

            // Times are given for the anchor occurrence; shift the target by the
            // same delta so span=all moves the whole series, not just its first date.
            let zone = tz ?? event.timeZone ?? .current
            let oldStart = event.startDate!
            if let start = start {
                let delta = try parseTime(start, field: "start", allDay: isAllDay, timeZone: zone).timeIntervalSince(anchor.startDate)
                let duration = event.endDate.timeIntervalSince(event.startDate)
                event.startDate = event.startDate.addingTimeInterval(delta)
                event.endDate = event.startDate.addingTimeInterval(duration)
                changed = true
            }
            if let end = end {
                let delta = try parseTime(end, field: "end", allDay: isAllDay, timeZone: zone).timeIntervalSince(anchor.endDate)
                event.endDate = event.endDate.addingTimeInterval(delta)
                changed = true
            }
            if event.endDate < event.startDate { throw ToolError("end is before start") }

            if let name = str("calendar_name") {
                if recurring && span == .this { throw ToolError("moving one occurrence to another calendar isn't supported; use span=all") }
                guard let cal = CalendarIntegration.resolveCalendars(name: name)?.first else {
                    throw ToolError("no calendar found with name: \(name)")
                }
                guard cal.allowsContentModifications else { throw CalendarIntegration.CalendarError.readOnlyCalendar(cal.title) }
                event.calendar = cal; changed = true
            }

            if let rrule = str("recurrence") {
                if recurring && span == .this { throw ToolError("changing the repeat rule needs span=future or span=all") }
                event.recurrenceRules = rrule.lowercased() == "none"
                    ? nil : [try CalendarRecurrence.parse(rrule, timeZone: zone)]
                changed = true
            }

            guard changed else {
                throw ToolError("nothing to update: pass at least one of title, start, end, all_day, location, notes, calendar_name, recurrence, event_timezone")
            }
            // EventKit doesn't move deleted dates with a series' time, so they come
            // back. Don't re-delete (the user may want them now); say so instead.
            let shift = event.startDate.timeIntervalSince(oldStart)
            let checkRevived = recurring && span != .this && shift != 0
            let before = checkRevived ? occurrenceDays(id: event.eventIdentifier, from: oldStart, shift: shift, tz: zone) : []
            try CalendarIntegration.save(event, span: recurring ? span.ek : .thisEvent)
            var result = writeResult(event)
            if recurring { result["span"] = span.rawValue }
            if checkRevived {
                let revived = occurrenceDays(id: event.eventIdentifier, from: event.startDate, shift: 0, tz: zone)
                    .subtracting(before).sorted()
                if !revived.isEmpty {
                    result["notice"] = "occurrences you had deleted came back with the time change: \(revived.joined(separator: ", ")). Delete them again if they're still unwanted."
                }
            }
            return (jsonString(result) ?? "{}", false)
        } catch {
            return (String(describing: error), true)
        }
    }

    private func deleteEvent(id: String, occurrence: String?, span: Span) -> (String, Bool) {
        do {
            let (event, _) = try resolveTarget(id: id, occurrence: occurrence, span: span)
            let recurring = event.hasRecurrenceRules
            var result = writeResult(event)
            try CalendarIntegration.remove(event, span: recurring ? span.ek : .thisEvent)
            result["deleted"] = true
            if recurring { result["span"] = span.rawValue }
            return (jsonString(result) ?? "{}", false)
        } catch {
            return (String(describing: error), true)
        }
    }

    // MARK: - Write helpers

    /// Days (in `tz`) holding a regular occurrence of series `id`, each moved by `shift`.
    // ponytail: two-year window; revived dates further out go unreported.
    private func occurrenceDays(id: String?, from start: Date, shift: TimeInterval, tz: TimeZone) -> Set<String> {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = "yyyy-MM-dd"
        return Set(CalendarIntegration.events(from: start, to: start.addingTimeInterval(2 * 365 * 86400))
            .filter { $0.eventIdentifier == id }
            .map { df.string(from: $0.startDate.addingTimeInterval(shift)) })
    }

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func timeZone(named name: String?) throws -> TimeZone? {
        guard let name = name, !name.isEmpty else { return nil }
        guard let tz = TimeZone(identifier: name) else {
            throw ToolError("unknown timezone: \(name) (use an IANA name like America/New_York)")
        }
        return tz
    }

    private func parseTime(_ s: String, field: String, allDay: Bool, timeZone: TimeZone?) throws -> Date {
        let tz = timeZone ?? .current
        let d = allDay ? CalendarIntegration.parseDay(s, timeZone: tz) : CalendarIntegration.parseDate(s, timeZone: tz)
        guard let date = d else { throw CalendarIntegration.CalendarError.invalidDate(field) }
        return date
    }

    private func writeResult(_ event: EKEvent) -> [String: Any] {
        var result: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "calendar": event.calendar.title,
            "start": DateFormatting.calendarTime(event.startDate, allDay: event.isAllDay),
            "end": DateFormatting.calendarTime(event.endDate, allDay: event.isAllDay),
            "all_day": event.isAllDay,
        ]
        if let rule = event.recurrenceRules?.first { result["recurrence"] = CalendarRecurrence.format(rule) }
        if !event.isAllDay, let tz = event.timeZone { result["event_timezone"] = tz.identifier }
        return result
    }

    // MARK: - Search

    private func searchEvents(query: String, calendarName: String?, start: String?, end: String?, dedupe: Bool = false) -> (String, Bool) {
        let startDate: Date
        if let startStr = start {
            guard let d = CalendarIntegration.parseDate(startStr) else {
                return ("invalid start date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
            }
            startDate = d
        } else {
            startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        }

        let endDate: Date
        if let endStr = end {
            guard let d = CalendarIntegration.parseDate(endStr) else {
                return ("invalid end date format", true)
            }
            endDate = d
        } else {
            endDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        }

        var calendars: [EKCalendar]? = nil
        if let name = calendarName {
            guard let resolved = CalendarIntegration.resolveCalendars(name: name) else {
                return ("no calendar found with name: \(name)", true)
            }
            calendars = resolved
        }

        let matching = CalendarIntegration.searchEvents(query: query, from: startDate, to: endDate, in: calendars)
        let results = formatEvents(matching, dedupe: dedupe)
        let response: [String: Any] = [
            "count": results.count,
            "events": results,
        ]
        return (jsonString(response) ?? "{}", false)
    }

    // MARK: - LLM payload formatting

    /// Map EKEvents to JSON dicts, optionally collapsing same-event duplicates.
    private func formatEvents(_ events: [EKEvent], dedupe: Bool) -> [[String: Any]] {
        let records = events.map { record(from: $0) }
        if dedupe {
            return CalendarEventFormatter.dedupeByID(records)
        }
        return records.map { CalendarEventFormatter.eventDict($0) }
    }

    /// Extract an EventKit-free `CalendarEventRecord` from an EKEvent.
    private func record(from event: EKEvent) -> CalendarEventRecord {
        let isOrganizer = event.organizer?.isCurrentUser ?? false
        let myStatus: String?
        if isOrganizer {
            myStatus = "accepted"
        } else if let me = event.attendees?.first(where: { $0.isCurrentUser }) {
            myStatus = participantStatusLabel(me.participantStatus)
        } else {
            myStatus = nil
        }

        return CalendarEventRecord(
            id: event.eventIdentifier ?? "",
            externalID: event.calendarItemExternalIdentifier,
            title: event.title ?? "",
            calendar: event.calendar.title,
            start: DateFormatting.calendarTime(event.startDate, allDay: event.isAllDay),
            end: DateFormatting.calendarTime(event.endDate, allDay: event.isAllDay),
            allDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString,
            attendees: (event.attendees ?? []).map { attendee(from: $0) },
            organizer: event.organizer.map { attendee(from: $0) },
            isOrganizer: isOrganizer,
            myStatus: myStatus,
            recurrence: event.recurrenceRules?.first.map(CalendarRecurrence.format)
        )
    }

    private func attendee(from participant: EKParticipant) -> CalendarAttendee {
        return CalendarAttendee(
            name: participant.name,
            email: emailFromParticipant(participant),
            status: participantStatusLabel(participant.participantStatus),
            isOrganizer: participant.participantRole == .chair
        )
    }

    private func emailFromParticipant(_ participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme == "mailto" else { return nil }
        let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return email.isEmpty ? nil : email
    }

    private func participantStatusLabel(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .pending: return "pending"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        default: return "unknown"
        }
    }

    private func calendarTypeLabel(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    private func colorHex(_ color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
