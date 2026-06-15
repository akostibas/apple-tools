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

    /// Search events by keyword across title, notes, location, and attendee names.
    public static func searchEvents(
        query: String,
        from start: Date,
        to end: Date,
        in calendars: [EKCalendar]? = nil
    ) -> [EKEvent] {
        let queryLower = query.lowercased()
        return events(from: start, to: end, in: calendars).filter { event in
            if let title = event.title, title.lowercased().contains(queryLower) { return true }
            if let notes = event.notes, notes.lowercased().contains(queryLower) { return true }
            if let location = event.location, location.lowercased().contains(queryLower) { return true }
            if let attendees = event.attendees {
                for attendee in attendees {
                    if let name = attendee.name, name.lowercased().contains(queryLower) { return true }
                }
            }
            return false
        }
    }

    /// Create and persist a new event. Throws CalendarError on save failure.
    public static func createEvent(
        title: String,
        start: Date,
        end: Date,
        calendar: EKCalendar?,
        location: String?,
        notes: String?
    ) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar ?? store.defaultCalendarForNewEvents
        if let location = location { event.location = location }
        if let notes = notes { event.notes = notes }

        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
        return event
    }

    // MARK: - Date parsing

    /// Parse ISO 8601 dates with/without fractional seconds, or zone-less
    /// `yyyy-MM-dd[THH:mm:ss]` (treated as local time — LLMs often omit the Z).
    public static func parseDate(_ str: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }

        let fmtBasic = ISO8601DateFormatter()
        if let d = fmtBasic.date(from: str) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = format
            if let d = df.date(from: str) { return d }
        }
        return nil
    }
}
