import Foundation

/// Plain, EventKit-free value types and pure formatting/de-dupe logic for
/// calendar events. Kept separate from `CalendarTool`/`CalendarIntegration`
/// (which depend on EventKit and can't be constructed in unit tests) so the
/// attendee/status mapping and the de-dupe collapsing can be exercised with
/// fixture data.

/// One participant of an event (attendee or organizer).
public struct CalendarAttendee: Equatable {
    public let name: String?
    public let email: String?
    /// Already-mapped status label (accepted/declined/tentative/pending/...).
    public let status: String
    /// True when this participant is the event's chair (organizer).
    public let isOrganizer: Bool

    public init(name: String?, email: String?, status: String, isOrganizer: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.isOrganizer = isOrganizer
    }
}

/// A single event row, decoupled from EventKit.
public struct CalendarEventRecord {
    /// `eventIdentifier` — per-calendar instance id, surfaced as `id`.
    public let id: String
    /// `calendarItemExternalIdentifier` — the cross-calendar identity (e.g. the
    /// underlying Google event id). Stable across copies of the SAME shared
    /// event living on different local calendars; used as the de-dupe key.
    public let externalID: String?
    public let title: String
    public let calendar: String
    /// `calendarIdentifier` of the calendar this copy lives on.
    public let calendarID: String
    /// Title of the calendar's account (EKSource), e.g. "iCloud".
    public let account: String?
    /// confirmed/tentative/cancelled; nil when the event has no status.
    public let status: String?
    /// IANA zone of a timed event; nil for all-day and floating events.
    public let eventTimezone: String?
    public let start: String
    public let end: String
    public let allDay: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    public let attendees: [CalendarAttendee]
    public let organizer: CalendarAttendee?
    public let isOrganizer: Bool
    public let myStatus: String?
    /// RRULE of the series this occurrence belongs to, if it repeats.
    public let recurrence: String?

    public init(
        id: String,
        externalID: String?,
        title: String,
        calendar: String,
        start: String,
        end: String,
        allDay: Bool,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        attendees: [CalendarAttendee] = [],
        organizer: CalendarAttendee? = nil,
        isOrganizer: Bool = false,
        myStatus: String? = nil,
        recurrence: String? = nil,
        calendarID: String = "",
        account: String? = nil,
        status: String? = nil,
        eventTimezone: String? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.organizer = organizer
        self.isOrganizer = isOrganizer
        self.myStatus = myStatus
        self.recurrence = recurrence
        self.calendarID = calendarID
        self.account = account
        self.status = status
        self.eventTimezone = eventTimezone
    }
}

public enum CalendarEventFormatter {

    /// JSON dict for one participant.
    public static func attendeeDict(_ a: CalendarAttendee) -> [String: Any] {
        var entry: [String: Any] = ["status": a.status]
        if let name = a.name, !name.isEmpty { entry["name"] = name }
        if let email = a.email, !email.isEmpty { entry["email"] = email }
        if a.isOrganizer { entry["is_organizer"] = true }
        return entry
    }

    /// JSON dict for one event. Emits the singular `calendar` field
    /// (back-compat, un-deduped output).
    public static func eventDict(_ r: CalendarEventRecord) -> [String: Any] {
        var entry: [String: Any] = [
            "id": r.id,
            "title": r.title,
            "calendar": r.calendar,
            "start": r.start,
            "end": r.end,
            "all_day": r.allDay,
            "is_organizer": r.isOrganizer,
        ]
        if let location = r.location, !location.isEmpty { entry["location"] = location }
        if let notes = r.notes, !notes.isEmpty { entry["notes"] = notes }
        if let url = r.url, !url.isEmpty { entry["url"] = url }
        if !r.attendees.isEmpty { entry["attendees"] = r.attendees.map { attendeeDict($0) } }
        if let organizer = r.organizer { entry["organizer"] = attendeeDict(organizer) }
        if let status = r.myStatus { entry["my_status"] = status }
        if let rule = r.recurrence { entry["recurrence"] = rule }
        if let ext = r.externalID, !ext.isEmpty { entry["external_id"] = ext }
        if !r.calendarID.isEmpty { entry["calendar_id"] = r.calendarID }
        if let account = r.account, !account.isEmpty { entry["account"] = account }
        if let status = r.status { entry["status"] = status }
        if let tz = r.eventTimezone { entry["event_timezone"] = tz }
        return entry
    }

    /// Collapse records that refer to the same underlying event *occurrence*
    /// into a single row. Identity is `externalID` when present (the
    /// cross-calendar Google id), else `id` — **plus the occurrence `start`**.
    /// EventKit gives every occurrence of a recurring event the same
    /// `eventIdentifier`/`externalID`; they differ only by date, so the start
    /// must be part of the key or a daily standup queried Mon–Fri collapses to
    /// one row. Including `start` still merges the same occurrence found on
    /// multiple calendars (identical id/ext *and* start). First-seen order is
    /// preserved; the surviving row carries a `calendars` array (replacing the
    /// singular `calendar`) listing every calendar the occurrence was found on,
    /// in first-seen order, de-duplicated.
    public static func dedupeByID(_ records: [CalendarEventRecord]) -> [[String: Any]] {
        var order: [String] = []
        var firstRecord: [String: CalendarEventRecord] = [:]
        var calendars: [String: [String]] = [:]

        for (idx, r) in records.enumerated() {
            let key: String
            if let ext = r.externalID, !ext.isEmpty {
                key = "ext:" + ext + "\u{1F}" + r.start
            } else if !r.id.isEmpty {
                key = "id:" + r.id + "\u{1F}" + r.start
            } else {
                // No stable identity — never merge; treat each as unique.
                key = "row:\(idx)"
            }

            if firstRecord[key] == nil {
                firstRecord[key] = r
                calendars[key] = [r.calendar]
                order.append(key)
            } else if !(calendars[key]?.contains(r.calendar) ?? false) {
                calendars[key]?.append(r.calendar)
            }
        }

        return order.map { key in
            var entry = eventDict(firstRecord[key]!)
            // calendar_id and account describe one copy only, so they go with the singular name.
            for field in ["calendar", "calendar_id", "account"] { entry.removeValue(forKey: field) }
            entry["calendars"] = calendars[key] ?? []
            return entry
        }
    }

    /// Pick the calendar `spec` means: an exact id, else a case-insensitive name.
    /// A name shared by several calendars is refused rather than guessed at.
    public static func resolveCalendar(_ spec: String, among calendars: [CalendarRef]) throws -> CalendarRef {
        if let byID = calendars.first(where: { $0.id == spec }) { return byID }
        let named = calendars.filter { $0.name.lowercased() == spec.lowercased() }
        guard let first = named.first else { throw CalendarLookupError.notFound(spec) }
        guard named.count == 1 else { throw CalendarLookupError.ambiguous(spec, named) }
        return first
    }
}

/// A calendar's identity, decoupled from EventKit.
public struct CalendarRef: Equatable {
    public let id: String
    public let name: String
    public let account: String

    public init(id: String, name: String, account: String) {
        self.id = id
        self.name = name
        self.account = account
    }
}

public enum CalendarLookupError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case ambiguous(String, [CalendarRef])

    public var description: String {
        switch self {
        case .notFound(let spec):
            return "no calendar found with name or id: \(spec)"
        case .ambiguous(let spec, let candidates):
            let list = candidates.map { "\"\($0.name)\" in \($0.account.isEmpty ? "no account" : $0.account) (id \($0.id))" }
            return "\(candidates.count) calendars are named \"\(spec)\": \(list.joined(separator: "; ")). Pass the id of the one you mean."
        }
    }
}
