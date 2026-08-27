import XCTest

@testable import AppleToolsLib

/// All-day `create` inputs: what counts as a bare date, and how a date string
/// anchors to a local day rather than an instant (Shannon #1038).
final class CalendarAllDayTests: XCTestCase {

    func testIsDateOnlyDistinguishesBareDatesFromInstants() {
        XCTAssertTrue(CalendarIntegration.isDateOnly("2026-08-26"))
        XCTAssertFalse(CalendarIntegration.isDateOnly("2026-08-26T00:00:00Z"))
        XCTAssertFalse(CalendarIntegration.isDateOnly("2026-08-26T09:00:00"))
        XCTAssertFalse(CalendarIntegration.isDateOnly("not-a-date"))
    }

    func testParseDayAnchorsToLocalMidnightIgnoringZone() throws {
        // A UTC-suffixed midnight must still land on Aug 26 locally — otherwise
        // an all-day event slides a day west of Greenwich.
        let cal = Calendar(identifier: .gregorian)
        for input in ["2026-08-26", "2026-08-26T00:00:00Z", "2026-08-26T23:30:00-07:00"] {
            let d = try XCTUnwrap(CalendarIntegration.parseDay(input))
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 8, 26, 0, 0], "\(input)")
        }
    }

    func testParseDayRejectsNonDates() {
        XCTAssertNil(CalendarIntegration.parseDay("tomorrow"))
        XCTAssertNil(CalendarIntegration.parseDay(""))
    }
}
