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

    func testRFC2822WithTrailingZoneComment() {
        // A trailing `(PST)` comment is common in real headers; it must be
        // stripped so the numeric offset still parses (#38).
        XCTAssertEqual(
            DateFormatting.isoFromRFC2822("Thu, 15 Jan 2026 09:30:00 -0800 (PST)"),
            "2026-01-15T17:30:00Z"
        )
    }

    func testRFC2822WithTrailingZoneCommentNoWeekday() {
        XCTAssertEqual(
            DateFormatting.isoFromRFC2822("15 Jan 2026 09:30:00 +0000 (UTC)"),
            "2026-01-15T09:30:00Z"
        )
    }

    func testRFC2822ReturnsRawOnGarbage() {
        XCTAssertEqual(DateFormatting.isoFromRFC2822("not a date"), "not a date")
    }

    func testRFC2822ReturnsRawOnEmpty() {
        XCTAssertEqual(DateFormatting.isoFromRFC2822(""), "")
    }

    // MARK: - floatingLocal(from:) — zone-less reminder due times (#824)

    func testFloatingLocalTimedIsZoneless() {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 1; c.hour = 9; c.minute = 0; c.second = 0
        XCTAssertEqual(DateFormatting.floatingLocal(from: c), "2026-07-01T09:00:00")
    }

    func testFloatingLocalTimedDefaultsSecondsToZero() {
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 5; c.hour = 17; c.minute = 30
        XCTAssertEqual(DateFormatting.floatingLocal(from: c), "2026-12-05T17:30:00")
    }

    func testFloatingLocalDateOnlyOmitsTime() {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 1
        XCTAssertEqual(DateFormatting.floatingLocal(from: c), "2026-07-01")
    }

    func testFloatingLocalIsIndependentOfOutputTimeZone() {
        // A floating time must not shift when the output zone changes — it has no
        // zone at all. This is the core #824 invariant.
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 1; c.hour = 9; c.minute = 0
        DateFormatting.outputTimeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DateFormatting.floatingLocal(from: c), "2026-07-01T09:00:00")
    }

    func testFloatingLocalReturnsNilWithoutDate() {
        var c = DateComponents()
        c.hour = 9; c.minute = 0
        XCTAssertNil(DateFormatting.floatingLocal(from: c))
    }

    // MARK: - localDateOnly / calendarTime — all-day off-by-one fold-in (#824)

    func testCalendarTimeAllDayIsBareLocalDate() {
        // An all-day event anchored at machine-local midnight renders as that
        // local date, regardless of the machine's offset from UTC — no instant,
        // so no cross-midnight shift.
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 1; c.hour = 0; c.minute = 0; c.second = 0
        let midnight = cal.date(from: c)!  // local midnight, machine zone
        XCTAssertEqual(DateFormatting.calendarTime(midnight, allDay: true), "2026-07-01")
    }

    func testCalendarTimeTimedFallsThroughToISO() {
        XCTAssertEqual(
            DateFormatting.calendarTime(Date(timeIntervalSince1970: 0), allDay: false),
            "1970-01-01T00:00:00Z"
        )
    }

    // MARK: - resolveTimeZone — --timezone / APPLE_TOOLS_TIMEZONE parsing

    func testResolveTimeZoneLocalKeyword() {
        XCTAssertEqual(DateFormatting.resolveTimeZone("local"), .current)
        XCTAssertEqual(DateFormatting.resolveTimeZone("LOCAL"), .current)
        XCTAssertEqual(DateFormatting.resolveTimeZone("  Local  "), .current)
    }

    func testResolveTimeZoneUTCKeywords() {
        let utc = TimeZone(identifier: "UTC")
        XCTAssertEqual(DateFormatting.resolveTimeZone("utc"), utc)
        XCTAssertEqual(DateFormatting.resolveTimeZone("UTC"), utc)
        XCTAssertEqual(DateFormatting.resolveTimeZone("gmt"), utc)
        XCTAssertEqual(DateFormatting.resolveTimeZone("Z"), utc)
    }

    func testResolveTimeZoneIANAIdentifier() {
        XCTAssertEqual(
            DateFormatting.resolveTimeZone("America/New_York"),
            TimeZone(identifier: "America/New_York")
        )
    }

    func testResolveTimeZoneOffsetAbbreviation() {
        XCTAssertEqual(
            DateFormatting.resolveTimeZone("gmt-0700"),
            TimeZone(abbreviation: "GMT-0700")
        )
    }

    func testResolveTimeZoneReturnsNilOnGarbage() {
        XCTAssertNil(DateFormatting.resolveTimeZone("Not/AZone"))
        XCTAssertNil(DateFormatting.resolveTimeZone("banana"))
    }
}
