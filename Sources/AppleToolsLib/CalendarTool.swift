import EventKit
import Foundation

public struct CalendarTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "calendar",
        description: "Access Apple Calendar events. Use 'calendars' to list calendars, 'list' to view events in a date range, 'create' to add an event, 'search' to find events by keyword. Each returned event includes 'is_organizer', 'my_status' (accepted/declined/tentative/pending — the current user's RSVP), and an 'attendees' array of {name, email, status} (plus 'organizer') — use these to answer questions about invites, RSVPs, and meetings the user is running. For 'list'/'search', pass dedupe_by_id=true to collapse the same shared event that appears on multiple calendars into one row carrying a 'calendars' array (the singular 'calendar' field is replaced by 'calendars' only in de-duped output). Note: 'create' does not send invites.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "calendars, list, create, or search"),
                "calendar_name": PropertySchema(type_: "string", description: "Calendar name to filter by (for list, search) or create in (for create)",
                    summary: "Calendar to filter by (list/search) or create in (create)", actions: ["list", "search", "create"]),
                "start": PropertySchema(type_: "string", description: "Start date/time, ISO 8601 e.g. 2026-04-15T09:00:00Z (required for create; for list defaults to start of today; for search defaults to 30 days ago)",
                    summary: "Start date/time, ISO 8601 (e.g. 2026-04-15T09:00:00Z)", actions: ["list", "search", "create"]),
                "end": PropertySchema(type_: "string", description: "End date/time, ISO 8601 (required for create; for list defaults to end of start day; for search defaults to 30 days from now)",
                    summary: "End date/time, ISO 8601", actions: ["list", "search", "create"]),
                "title": PropertySchema(type_: "string", description: "Event title (required for create)",
                    summary: "Event title", actions: ["create"]),
                "location": PropertySchema(type_: "string", description: "Event location (for create)",
                    summary: "Event location", actions: ["create"]),
                "notes": PropertySchema(type_: "string", description: "Event notes (for create)",
                    summary: "Event notes", actions: ["create"]),
                "query": PropertySchema(type_: "string", description: "Search keyword (required for search)",
                    summary: "Search keyword", actions: ["search"]),
                "dedupe_by_id": PropertySchema(type_: "boolean", description: "For list/search: collapse the same event appearing on multiple calendars into one row with a 'calendars' array (opt-in; default false)",
                    summary: "Collapse an event on multiple calendars into one row (default false)", actions: ["list", "search"]),
            ],
            required: ["action"]
        ),
        cliSummary: "List, search, and create Apple Calendar events.",
        actions: [
            ActionHelp(name: "calendars", summary: "List available calendars",
                example: "apple-tools calendar calendars"),
            ActionHelp(name: "list", summary: "View events in a date range",
                example: "apple-tools calendar list [--start <d>] [--end <d>] [--calendar_name <n>] [--dedupe_by_id]"),
            ActionHelp(name: "search", summary: "Find events by keyword",
                example: "apple-tools calendar search --query <text> [--start <d>] [--end <d>] [--calendar_name <n>] [--dedupe_by_id]", required: ["query"]),
            ActionHelp(name: "create", summary: "Add an event (does not send invites)",
                example: "apple-tools calendar create --title <t> --start <d> --end <d> [--location <l>] [--notes <n>] [--calendar_name <n>]", required: ["title", "start", "end"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "calendars": .read,
        "list":      .read,
        "search":    .read,
        "create":    .readWrite,
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
            return createEvent(title: title, start: startStr, end: endStr, calendarName: calendarName, location: location, notes: notes)
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
            return ("unknown action: \(action) (use calendars, list, create, or search)", true)
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

    private func createEvent(title: String, start: String, end: String, calendarName: String?, location: String?, notes: String?) -> (String, Bool) {
        guard let startDate = CalendarIntegration.parseDate(start) else {
            return ("invalid start date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
        }
        guard let endDate = CalendarIntegration.parseDate(end) else {
            return ("invalid end date format", true)
        }

        var calendar: EKCalendar? = nil
        if let calendarName = calendarName {
            guard let cals = CalendarIntegration.resolveCalendars(name: calendarName), let cal = cals.first else {
                return ("no calendar found with name: \(calendarName)", true)
            }
            calendar = cal
        }

        let event: EKEvent
        do {
            event = try CalendarIntegration.createEvent(
                title: title,
                start: startDate,
                end: endDate,
                calendar: calendar,
                location: location,
                notes: notes
            )
        } catch let error as CalendarIntegration.CalendarError {
            return (error.description, true)
        } catch {
            return ("failed to save event: \(error.localizedDescription)", true)
        }

        let response: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "calendar": event.calendar.title,
            "start": DateFormatting.calendarTime(event.startDate, allDay: event.isAllDay),
            "end": DateFormatting.calendarTime(event.endDate, allDay: event.isAllDay),
        ]
        return (jsonString(response) ?? "{}", false)
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
            myStatus: myStatus
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
