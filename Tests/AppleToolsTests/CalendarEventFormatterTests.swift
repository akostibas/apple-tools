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
            start: "2026-06-10T17:00:00Z",
            end: "2026-06-10T17:30:00Z",
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

    func testDedupeDoesNotDuplicateSameCalendar() {
        let records = [
            record(id: "a", externalID: "g-1", calendar: "Alexi"),
            record(id: "b", externalID: "g-1", calendar: "Alexi"),
        ]
        let rows = CalendarEventFormatter.dedupeByID(records)
        XCTAssertEqual(rows[0]["calendars"] as? [String], ["Alexi"])
    }
}
