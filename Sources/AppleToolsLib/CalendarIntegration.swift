import EventKit
import Foundation

/// Shared Apple Calendar (EventKit) integration. All EventKit access lives here.
///
/// Consumers: CalendarTool (LLM tool wrapper) and any future calendar integration
/// point (hooks, service-account tools, tests).
///
/// Design: stateless enum with static methods. A single shared EKEventStore is
/// retained internally because EventKit expects a long-lived store for change
/// notifications and predicate evaluation.
public enum CalendarIntegration {

    // EventKit recommends a long-lived store; share one across all callers.
    private static let store = EKEventStore()

    // MARK: - Types

    public enum CalendarError: Error, CustomStringConvertible {
        case accessDenied
        case invalidDate(String)
        case calendarNotFound(String)
        case saveFailed(String)
        case eventNotFound(String)
        case notOrganizer(String)
        case readOnlyCalendar(String)

        public var description: String {
            switch self {
            case .accessDenied:
                return "Calendar access denied. Grant permission in System Settings → Privacy & Security → Calendars."
            case .invalidDate(let field):
                return "invalid \(field) date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)"
            case .calendarNotFound(let name):
                return "no calendar found with name: \(name)"
            case .saveFailed(let reason):
                return "failed to save event: \(reason)"
            case .eventNotFound(let detail):
                return "no event found: \(detail)"
            case .notOrganizer(let title):
                return "can't change \"\(title)\": you're not the organizer. Changing or deleting an invite here can be silently undone by the next sync or send the organizer a decline. Change it in Calendar.app instead."
            case .readOnlyCalendar(let name):
                return "calendar \"\(name)\" is read-only (e.g. a subscription or Birthdays) and can't be changed"
            }
        }
    }

    // MARK: - Access

    /// Synchronously request full calendar access. Returns true if granted.
    public static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { result, _ in
                granted = result
                semaphore.signal()
            }
        } else {
            store.requestAccess(to: .event) { result, _ in
                granted = result
                semaphore.signal()
            }
        }

        semaphore.wait()
        return granted
    }

    public static func preflight() -> (ok: Bool, message: String) {
        let granted = requestAccess()
        return (granted, granted ? "calendar access granted" : "calendar access denied")
    }

    // MARK: - Calendars

    public static func allCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    public static func defaultCalendarForNewEvents() -> EKCalendar? {
        store.defaultCalendarForNewEvents
    }

    /// Resolve calendars by case-insensitive name match. Returns nil if no match.
    public static func resolveCalendars(name: String) -> [EKCalendar]? {
        let matching = store.calendars(for: .event).filter { $0.title.lowercased() == name.lowercased() }
        return matching.isEmpty ? nil : matching
    }

    // MARK: - Events

    /// Fetch events in a date range, optionally restricted to a set of calendars.
    public static func events(from start: Date, to end: Date, in calendars: [EKCalendar]? = nil) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
    }

    /// Search events by keyword across title, notes, location, and attendee
    /// names. AND-of-terms: every word in a multi-word query must appear in at
    /// least one field, in any order (issue #47).
    public static func searchEvents(
        query: String,
        from start: Date,
        to end: Date,
        in calendars: [EKCalendar]? = nil
    ) -> [EKEvent] {
        // AND-of-terms: a multi-word query matches when every word appears in
        // at least one field, in any order — not only as one adjacent substring
        // across the whole query (issue #47). Strip only generic stopwords; if
        // that empties the query (a bare "the"), fall back to the raw words so
        // single-word behavior is unchanged. Mirrors NotesStoreSearch.
        var terms = QueryTerms.tokenize(query)
        if terms.isEmpty { terms = QueryTerms.tokenize(query, stopwords: []) }
        guard !terms.isEmpty else { return [] }

        return events(from: start, to: end, in: calendars).filter { event in
            var fields: [String] = []
            if let title = event.title { fields.append(title) }
            if let notes = event.notes { fields.append(notes) }
            if let location = event.location { fields.append(location) }
            if let attendees = event.attendees {
                fields.append(contentsOf: attendees.compactMap { $0.name })
            }
            return QueryTerms.allTermsMatch(terms, inAnyOf: fields)
        }
    }

    /// Create and persist a new event. Throws CalendarError on save failure.
    public static func createEvent(
        title: String,
        start: Date,
        end: Date,
        calendar: EKCalendar?,
        location: String?,
        notes: String?,
        allDay: Bool = false,
        recurrence: EKRecurrenceRule? = nil,
        timeZone: TimeZone? = nil
    ) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = allDay
        if let timeZone = timeZone { event.timeZone = timeZone }
        event.startDate = start
        event.endDate = end
        event.calendar = calendar ?? store.defaultCalendarForNewEvents
        if let cal = event.calendar, !cal.allowsContentModifications {
            throw CalendarError.readOnlyCalendar(cal.title)
        }
        if let location = location { event.location = location }
        if let notes = notes { event.notes = notes }
        if let recurrence = recurrence { event.recurrenceRules = [recurrence] }

        try save(event, span: .thisEvent)
        return event
    }

    /// Look up an event by `eventIdentifier`. Every occurrence of a repeating
    /// event shares the id, so `occurrence` picks one: a bare day matches any
    /// start on that local day, an instant matches the start within a minute.
    /// Without `occurrence`, EventKit returns the series' first occurrence.
    public static func findEvent(id: String, occurrence: String?) throws -> EKEvent {
        guard let occurrence = occurrence else {
            guard let event = store.event(withIdentifier: id) else {
                throw CalendarError.eventNotFound("id \(id)")
            }
            return event
        }

        let dayOnly = isDateOnly(occurrence)
        guard let target = dayOnly ? parseDay(occurrence) : parseDate(occurrence) else {
            throw CalendarError.invalidDate("occurrence")
        }
        let day: TimeInterval = 86400
        let candidates = events(from: target.addingTimeInterval(-day), to: target.addingTimeInterval(2 * day))
            .filter { $0.eventIdentifier == id }
        let match = candidates.first { ev in
            dayOnly ? Calendar.current.isDate(ev.startDate, inSameDayAs: target)
                    : abs(ev.startDate.timeIntervalSince(target)) < 60
        }
        guard let event = match else {
            throw CalendarError.eventNotFound("id \(id) has no occurrence starting \(occurrence)")
        }
        return event
    }

    /// Refuse writes the user can't safely make: invites they don't organize
    /// (edits get reverted or send a decline) and read-only calendars.
    public static func checkWritable(_ event: EKEvent) throws {
        if !event.calendar.allowsContentModifications {
            throw CalendarError.readOnlyCalendar(event.calendar.title)
        }
        if let organizer = event.organizer, !organizer.isCurrentUser {
            throw CalendarError.notOrganizer(event.title ?? "")
        }
    }

    public static func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            store.reset()
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }

    public static func remove(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            store.reset()
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Date parsing

    /// Parse ISO 8601 dates with/without fractional seconds, or zone-less
    /// `yyyy-MM-dd[THH:mm:ss]` (treated as local time — LLMs often omit the Z).
    public static func parseDate(_ str: String, timeZone: TimeZone = .current) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }

        let fmtBasic = ISO8601DateFormatter()
        if let d = fmtBasic.date(from: str) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = format
            if let d = df.date(from: str) { return d }
        }
        return nil
    }

    /// Parse the leading `yyyy-MM-dd` of a date string as local midnight of that
    /// calendar day. All-day events anchor to days, not instants: a UTC-suffixed
    /// midnight (`2026-09-02T00:00:00Z`) would otherwise land on Sep 1 west of
    /// Greenwich.
    public static func parseDay(_ str: String, timeZone: TimeZone = .current) -> Date? {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: String(str.prefix(10)))
    }

    /// True for a bare `yyyy-MM-dd` with no time component — the natural shape
    /// for an all-day event, which `create` treats as one.
    public static func isDateOnly(_ str: String) -> Bool {
        str.count == 10 && parseDay(str) != nil
    }
}
