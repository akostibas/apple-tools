import EventKit
import XCTest

@testable import AppleToolsLib

final class CalendarEventFormatterTests: XCTestCase {

    // MARK: - Fixtures

    private func attendee(
        _ name: String,
        _ email: String,
        _ status: String,
        organizer: Bool = false
    ) -> CalendarAttendee {
        CalendarAttendee(name: name, email: email, status: status, isOrganizer: organizer)
    }

    private func record(
        id: String,
        externalID: String?,
        calendar: String,
        title: String = "Standup",
        start: String = "2026-06-10T17:00:00Z",
        end: String = "2026-06-10T17:30:00Z",
        attendees: [CalendarAttendee] = [],
        organizer: CalendarAttendee? = nil,
        isOrganizer: Bool = false,
        myStatus: String? = nil
    ) -> CalendarEventRecord {
        CalendarEventRecord(
            id: id,
            externalID: externalID,
            title: title,
            calendar: calendar,
            start: start,
            end: end,
            allDay: false,
            attendees: attendees,
            organizer: organizer,
            isOrganizer: isOrganizer,
            myStatus: myStatus
        )
    }

    // MARK: - Attendee / status mapping (#4)

    func testAttendeeDictIncludesNameEmailStatus() {
        let dict = CalendarEventFormatter.attendeeDict(attendee("Jane Doe", "jane@example.com", "accepted"))
        XCTAssertEqual(dict["name"] as? String, "Jane Doe")
        XCTAssertEqual(dict["email"] as? String, "jane@example.com")
        XCTAssertEqual(dict["status"] as? String, "accepted")
        XCTAssertNil(dict["is_organizer"])
    }

    func testAttendeeDictMarksOrganizer() {
        let dict = CalendarEventFormatter.attendeeDict(attendee("Boss", "boss@example.com", "accepted", organizer: true))
        XCTAssertEqual(dict["is_organizer"] as? Bool, true)
    }

    func testAttendeeDictOmitsEmptyFields() {
        let dict = CalendarEventFormatter.attendeeDict(CalendarAttendee(name: nil, email: "", status: "pending"))
        XCTAssertNil(dict["name"])
        XCTAssertNil(dict["email"])
        XCTAssertEqual(dict["status"] as? String, "pending")
    }

    func testEventDictCarriesAttendeesOrganizerAndMyStatus() {
        let r = record(
            id: "evt-1",
            externalID: "ext-1",
            calendar: "Alexi",
            attendees: [
                attendee("Alexi", "alexi@example.com", "accepted"),
                attendee("Sam", "sam@example.com", "tentative"),
            ],
            organizer: attendee("Sam", "sam@example.com", "accepted", organizer: true),
            isOrganizer: false,
            myStatus: "accepted"
        )
        let dict = CalendarEventFormatter.eventDict(r)

        XCTAssertEqual(dict["id"] as? String, "evt-1")
        XCTAssertEqual(dict["calendar"] as? String, "Alexi")
        XCTAssertEqual(dict["my_status"] as? String, "accepted")
        XCTAssertEqual(dict["is_organizer"] as? Bool, false)

        let attendees = dict["attendees"] as? [[String: Any]]
        XCTAssertEqual(attendees?.count, 2)
        XCTAssertEqual(attendees?[1]["status"] as? String, "tentative")

        let organizer = dict["organizer"] as? [String: Any]
        XCTAssertEqual(organizer?["is_organizer"] as? Bool, true)
    }

    func testEventDictOmitsMyStatusWhenNil() {
        let dict = CalendarEventFormatter.eventDict(record(id: "x", externalID: nil, calendar: "Home", myStatus: nil))
        XCTAssertNil(dict["my_status"])
        XCTAssertNil(dict["attendees"])
        // Singular calendar present in un-deduped output (back-compat).
        XCTAssertEqual(dict["calendar"] as? String, "Home")
    }

    // MARK: - De-dupe by id (#10)

    func testDedupeCollapsesSameExternalIDAcrossCalendars() {
        // Same shared event on two calendars: identical externalID, different
        // eventIdentifier + calendar (the real-world shared-household case).
        let records = [
            record(id: "evt-a", externalID: "google-123", calendar: "Alexi"),
            record(id: "evt-b", externalID: "google-123", calendar: "Samantha Piell"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)

        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNil(row["calendar"], "singular calendar dropped in deduped output")
        XCTAssertEqual(row["calendars"] as? [String], ["Alexi", "Samantha Piell"])
    }

    func testDedupePreservesFirstSeenOrderAndDistinctEvents() {
        let records = [
            record(id: "evt-a", externalID: "g-1", calendar: "Alexi", title: "Dinner"),
            record(id: "evt-c", externalID: "g-2", calendar: "Alexi", title: "Solo"),
            record(id: "evt-b", externalID: "g-1", calendar: "Samantha Piell", title: "Dinner"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["title"] as? String, "Dinner")
        XCTAssertEqual(rows[0]["calendars"] as? [String], ["Alexi", "Samantha Piell"])
        XCTAssertEqual(rows[1]["title"] as? String, "Solo")
        XCTAssertEqual(rows[1]["calendars"] as? [String], ["Alexi"])
    }

    func testDedupeFallsBackToEventIdentifierWhenNoExternalID() {
        let records = [
            record(id: "same-id", externalID: nil, calendar: "Alexi"),
            record(id: "same-id", externalID: "", calendar: "Work"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["calendars"] as? [String], ["Alexi", "Work"])
    }

    func testDedupeNeverMergesEventsWithNoStableIdentity() {
        let records = [
            record(id: "", externalID: nil, calendar: "Alexi"),
            record(id: "", externalID: nil, calendar: "Alexi"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)
        XCTAssertEqual(rows.count, 2, "rows with no id must not collapse together")
    }

    func testDedupeKeepsRecurringOccurrencesSeparate() {
        // A daily standup: every occurrence shares one externalID + eventIdentifier,
        // differing only by start. They must NOT collapse into a single row (#24).
        let records = [
            record(id: "rec", externalID: "google-standup", calendar: "Alexi", start: "2026-06-08T17:00:00Z"),
            record(id: "rec", externalID: "google-standup", calendar: "Alexi", start: "2026-06-09T17:00:00Z"),
            record(id: "rec", externalID: "google-standup", calendar: "Alexi", start: "2026-06-10T17:00:00Z"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)
        XCTAssertEqual(rows.count, 3, "each occurrence of a recurring event is its own row")
        XCTAssertEqual(rows.map { $0["start"] as? String },
                       ["2026-06-08T17:00:00Z", "2026-06-09T17:00:00Z", "2026-06-10T17:00:00Z"])
    }

    func testDedupeMergesSameOccurrenceAcrossCalendars() {
        // The same occurrence (same externalID AND same start) found on two
        // calendars still collapses to one row.
        let records = [
            record(id: "a", externalID: "google-standup", calendar: "Alexi", start: "2026-06-10T17:00:00Z"),
            record(id: "b", externalID: "google-standup", calendar: "Samantha Piell", start: "2026-06-10T17:00:00Z"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["calendars"] as? [String], ["Alexi", "Samantha Piell"])
    }

    func testDedupeDoesNotDuplicateSameCalendar() {
        let records = [
            record(id: "a", externalID: "g-1", calendar: "Alexi"),
            record(id: "b", externalID: "g-1", calendar: "Alexi"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)
        XCTAssertEqual(rows[0]["calendars"] as? [String], ["Alexi"])
    }

    // MARK: - Identity fields and calendar lookup (#103)

    func testEventDictCarriesIdentityStatusAndZone() {
        // External ids come in several shapes; each must pass through untouched.
        for ext in ["6F1B2C3D-0000-4A5B-8C9D-112233445566", "abc123def456@google.com",
                    "040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F5060708090A0B0C0D0E0F"] {
            let dict = CalendarEventFormatter.eventDict(CalendarEventRecord(
                id: "evt", externalID: ext, title: "Planning", calendar: "Family",
                start: "2026-06-10T17:00:00Z", end: "2026-06-10T18:00:00Z", allDay: false,
                calendarID: "CAL-1", account: "iCloud", status: "tentative", eventTimezone: "America/New_York"))
            XCTAssertEqual(dict["external_id"] as? String, ext)
            XCTAssertEqual(dict["calendar"] as? String, "Family")
            XCTAssertEqual(dict["calendar_id"] as? String, "CAL-1")
            XCTAssertEqual(dict["account"] as? String, "iCloud")
            XCTAssertEqual(dict["status"] as? String, "tentative")
            XCTAssertEqual(dict["event_timezone"] as? String, "America/New_York")
        }
    }

    func testEventDictOmitsStatusAndZoneWhenUnset() {
        let dict = CalendarEventFormatter.eventDict(record(id: "x", externalID: nil, calendar: "Home"))
        for field in ["external_id", "status", "event_timezone", "account", "calendar_id"] {
            XCTAssertNil(dict[field], field)
        }
    }

    func testDedupedRowDropsTheSingleCalendarFields() {
        let rows = CalendarEventFormatter.dedupeByID([CalendarEventRecord(
            id: "a", externalID: "g-1", title: "Planning", calendar: "Family",
            start: "2026-06-10T17:00:00Z", end: "2026-06-10T18:00:00Z", allDay: false, calendarID: "CAL-1", account: "iCloud")])
        XCTAssertNil(rows[0]["calendar_id"])
        XCTAssertNil(rows[0]["account"])
        XCTAssertEqual(rows[0]["external_id"] as? String, "g-1")
        XCTAssertEqual(rows[0]["calendars"] as? [String], ["Family"])
    }

    private let refs = [
        CalendarRef(id: "CAL-1", name: "Family", account: "iCloud"),
        CalendarRef(id: "CAL-2", name: "Family", account: "pat@example.com"),
        CalendarRef(id: "CAL-3", name: "Work", account: "pat@example.com"),
    ]

    func testCalendarResolvesByIDOrUniqueName() throws {
        XCTAssertEqual(try CalendarEventFormatter.resolveCalendar("CAL-2", among: refs).account, "pat@example.com")
        XCTAssertEqual(try CalendarEventFormatter.resolveCalendar("work", among: refs).id, "CAL-3")
        XCTAssertThrowsError(try CalendarEventFormatter.resolveCalendar("Holidays", among: refs)) {
            XCTAssertEqual(String(describing: $0), "no calendar found with name or id: Holidays")
        }
    }

    func testSharedCalendarNameIsRefusedWithCandidates() {
        XCTAssertThrowsError(try CalendarEventFormatter.resolveCalendar("family", among: refs)) {
            XCTAssertEqual($0 as? CalendarLookupError, .ambiguous("family", Array(refs.prefix(2))))
            XCTAssertEqual(String(describing: $0),
                "2 calendars are named \"family\": \"Family\" in iCloud (id CAL-1); \"Family\" in pat@example.com (id CAL-2). Pass the id of the one you mean.")
        }
    }

    func testEventStatusLabels() {
        XCTAssertEqual(CalendarTool.statusLabel(.confirmed), "confirmed")
        XCTAssertEqual(CalendarTool.statusLabel(.tentative), "tentative")
        XCTAssertEqual(CalendarTool.statusLabel(.canceled), "cancelled")
        XCTAssertNil(CalendarTool.statusLabel(.none))
    }
}
