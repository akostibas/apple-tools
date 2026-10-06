import EventKit
import XCTest

@testable import AppleToolsLib

/// RRULE parsing for calendar create/update (#75): what EKRecurrenceRule can
/// represent round-trips; anything else is rejected rather than half-applied.
final class CalendarRecurrenceTests: XCTestCase {

    func testRoundTripsSupportedRules() throws {
        for rule in [
            "FREQ=DAILY",
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR",
            "FREQ=MONTHLY;BYDAY=2TU,4TU",
            "FREQ=MONTHLY;BYDAY=-1FR",
            "FREQ=MONTHLY;BYMONTHDAY=15;COUNT=6",
            "FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR;BYMONTH=3;BYSETPOS=-1",
            "FREQ=DAILY;UNTIL=20261231T235959Z",
        ] {
            XCTAssertEqual(CalendarRecurrence.format(try CalendarRecurrence.parse(rule)), rule)
        }
    }

    func testShorthandsPrefixAndCase() throws {
        XCTAssertEqual(CalendarRecurrence.format(try CalendarRecurrence.parse("weekly")), "FREQ=WEEKLY")
        XCTAssertEqual(CalendarRecurrence.format(try CalendarRecurrence.parse("RRULE:freq=monthly;wkst=su")), "FREQ=MONTHLY")
    }

    func testBareUntilDateRunsThroughEndOfDayInEventZone() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let rule = try CalendarRecurrence.parse("FREQ=DAILY;UNTIL=20261231", timeZone: ny)
        // 23:59:59 Eastern on Dec 31 is 04:59:59Z on Jan 1.
        XCTAssertEqual(CalendarRecurrence.format(rule), "FREQ=DAILY;UNTIL=20270101T045959Z")
    }

    func testRejectsWhatEventKitCannotRepresent() {
        for bad in [
            "", "FREQ=HOURLY", "INTERVAL=2", "FREQ=DAILY;INTERVAL=0",
            "FREQ=DAILY;COUNT=3;UNTIL=20261231", "FREQ=WEEKLY;BYDAY=2TU",
            "FREQ=WEEKLY;BYDAY=XX", "FREQ=MONTHLY;BYMONTHDAY=32",
            "FREQ=DAILY;BYHOUR=9", "FREQ=DAILY;FREQ=WEEKLY", "FREQ=DAILY;UNTIL=soon",
        ] {
            XCTAssertThrowsError(try CalendarRecurrence.parse(bad), bad)
        }
    }
}
