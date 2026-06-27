import XCTest
@testable import AppleToolsLib

/// Pins the canonical ISO-8601 output format shared by every tool. Before
/// DateFormatting existed, `email inbox` emitted a localized AppleScript string
/// and `email read` an RFC-2822 header while `email search` emitted ISO-8601
/// (issue #11); these tests lock the single format so it can't drift again.
final class DateFormattingTests: XCTestCase {

    override func tearDown() {
        // Other tests (and the default) expect UTC output.
        DateFormatting.outputTimeZone = TimeZone(identifier: "UTC")!
        super.tearDown()
    }

    // MARK: - iso(Date)

    func testISODefaultsToUTCZ() {
        XCTAssertEqual(
            DateFormatting.iso(Date(timeIntervalSince1970: 0)),
            "1970-01-01T00:00:00Z"
        )
    }

    func testISOHonorsOutputTimeZoneOverride() {
        DateFormatting.outputTimeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 1970-01-01T00:00:00Z is 1969-12-31 16:00 in PST (-08:00).
        XCTAssertEqual(
            DateFormatting.iso(Date(timeIntervalSince1970: 0)),
            "1969-12-31T16:00:00-08:00"
        )
    }

    // MARK: - AppleScript component conversion (email inbox/read, Notes)

    func testAppleScriptComponentsPreserveWallClock() {
        // Interpreting in the machine TZ and rendering in that same TZ must
        // return the original wall-clock — independent of what the CI TZ is.
        DateFormatting.outputTimeZone = TimeZone.current
        let out = DateFormatting.isoFromAppleScriptComponents("2026,6,27,9,30,0")
        XCTAssertTrue(
            out.hasPrefix("2026-06-27T09:30:00"),
            "expected wall-clock 2026-06-27T09:30:00..., got \(out)"
        )
    }

    func testAppleScriptComponentsZeroPadsSingleDigits() {
        DateFormatting.outputTimeZone = TimeZone.current
        let out = DateFormatting.isoFromAppleScriptComponents("2026,1,5,3,7,9")
        XCTAssertTrue(
            out.hasPrefix("2026-01-05T03:07:09"),
            "expected zero-padded components, got \(out)"
        )
    }

    func testAppleScriptComponentsReturnsRawOnGarbage() {
        XCTAssertEqual(
            DateFormatting.isoFromAppleScriptComponents("Friday, June 27, 2026"),
            "Friday, June 27, 2026"
        )
    }

    func testAppleScriptComponentsReturnsRawOnWrongCount() {
        XCTAssertEqual(DateFormatting.isoFromAppleScriptComponents("2026,6,27"), "2026,6,27")
    }

    // MARK: - RFC-2822 conversion (email read fast path)

    func testRFC2822WithWeekdayToUTC() {
        XCTAssertEqual(
            DateFormatting.isoFromRFC2822("Thu, 15 Jan 2026 09:30:00 -0800"),
            "2026-01-15T17:30:00Z"
        )
    }

    func testRFC2822WithoutWeekday() {
        XCTAssertEqual(
            DateFormatting.isoFromRFC2822("15 Jan 2026 09:30:00 -0800"),
            "2026-01-15T17:30:00Z"
        )
    }

    func testRFC2822WithoutSeconds() {
        XCTAssertEqual(
            DateFormatting.isoFromRFC2822("Thu, 15 Jan 2026 09:30 +0000"),
            "2026-01-15T09:30:00Z"
        )
    }

    func testRFC2822ReturnsRawOnGarbage() {
        XCTAssertEqual(DateFormatting.isoFromRFC2822("not a date"), "not a date")
    }

    func testRFC2822ReturnsRawOnEmpty() {
        XCTAssertEqual(DateFormatting.isoFromRFC2822(""), "")
    }
}
