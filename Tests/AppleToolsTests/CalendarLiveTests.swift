import EventKit
import XCTest
@testable import AppleToolsLib

/// Live round-trip tests against the real Calendar store. Opt-in, because they create and delete events
/// (dated late 2028, no attendees) in a calendar that is the user's own and shared with nobody. Run with:
///
///     make test-slow TOOL=calendar
final class CalendarLiveTests: XCTestCase {

    private let tool = CalendarTool()
    /// Every event this run creates starts with this, and tearDown removes only those.
    private let prefix = "\(LiveTest.label) \(UUID().uuidString.prefix(8))"
    private var calendar = ""

    private static let windowStart = "2028-09-01T00:00:00Z", windowEnd = "2029-03-01T00:00:00Z"

    override func setUpWithError() throws {
        try LiveTest.writes("calendar", "create", "update", "delete", "calendars", "list", "search")
        try XCTSkipUnless(CalendarIntegration.requestAccess(), "no Calendar access")
        let own = CalendarIntegration.allCalendars().filter(Self.isPrivateAndWritable)
        let pick = own.first { $0 == CalendarIntegration.defaultCalendarForNewEvents() }
            ?? own.sorted { $0.title < $1.title }.first
        calendar = try XCTUnwrap(pick?.title, "no writable calendar that is shared with nobody; add one to run these tests")
    }

    override func tearDown() {
        // A changed occurrence and a split series get their own ids, so sweep by this run's title, not by id.
        for _ in 0..<20 {
            guard let event = mine().first else { break }
            try? CalendarIntegration.remove(event, span: .futureEvents)
        }
        XCTAssertEqual(mine().map { $0.title ?? "" }, [], "test events left behind in calendar \"\(calendar)\"")
        super.tearDown()
    }

    // MARK: - Helpers

    /// An event added to a shared calendar notifies the people it is shared with, so those are never used.
    private static func isPrivateAndWritable(_ cal: EKCalendar) -> Bool {
        // sharingStatus is not public API: 0 means shared with nobody. A calendar that can't say is not used.
        guard cal.allowsContentModifications, cal.type == .local || cal.type == .calDAV,
              cal.responds(to: Selector(("sharingStatus"))),
              (cal.value(forKey: "sharingStatus") as? Int) == 0 else { return false }
        // The tool takes a calendar by name and uses the first match, so the name must lead to this one.
        return CalendarIntegration.resolveCalendars(name: cal.title)?.first == cal
    }

    private func mine() -> [EKEvent] {
        guard let from = CalendarIntegration.parseDate(Self.windowStart),
              let to = CalendarIntegration.parseDate(Self.windowEnd) else { return [] }
        return CalendarIntegration.events(from: from, to: to)
            .filter { $0.title?.hasPrefix(prefix) == true }
            .sorted { $0.startDate < $1.startDate }
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        guard !isError else { throw NSError(domain: "calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func refusal(_ params: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        XCTAssertTrue(isError, "expected a refusal, got: \(out)", file: file, line: line)
        return out
    }

    private func create(_ extra: [String: Any]) throws -> [String: Any] {
        var p: [String: Any] = ["action": "create", "title": prefix, "calendar": calendar]
        p.merge(extra) { $1 }
        let r = try call(p)
        XCTAssertEqual(r["calendar"] as? String, calendar)
        return r
    }

    /// This run's events as `list` reports them, in start order.
    private func listed() throws -> [[String: Any]] {
        let r = try call(["action": "list", "start": Self.windowStart, "end": Self.windowEnd, "calendar": calendar])
        return try XCTUnwrap(r["events"] as? [[String: Any]])
            .filter { ($0["title"] as? String)?.hasPrefix(prefix) == true }
            .sorted { ($0["start"] as! String) < ($1["start"] as! String) }
    }

    private func starts() throws -> [String] { try listed().map { $0["start"] as! String } }

    /// The UTC form the tool reports for a wall-clock time on this Mac.
    private func local(_ wallClock: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return ISO8601DateFormatter().string(from: df.date(from: wallClock)!)
    }

    // MARK: - Timed

    func testTimedEventCreateReadUpdateDelete() throws {
        let r = try create(["start": "2028-10-03T17:00:00Z", "end": "2028-10-03T18:00:00Z",
                            "location": "Room 1", "notes": "first notes"])
        let id = try XCTUnwrap(r["id"] as? String)
        XCTAssertEqual(r["start"] as? String, "2028-10-03T17:00:00Z")
        XCTAssertEqual(r["end"] as? String, "2028-10-03T18:00:00Z")
        XCTAssertEqual(r["all_day"] as? Bool, false)
        XCTAssertNil(r["recurrence"])

        var got = try XCTUnwrap(listed().first)
        XCTAssertEqual(try listed().count, 1)
        XCTAssertEqual(got["id"] as? String, id)
        XCTAssertEqual(got["location"] as? String, "Room 1")
        XCTAssertEqual(got["notes"] as? String, "first notes")
        XCTAssertNil(got["attendees"], "a created event must invite nobody")

        let token = String(prefix.suffix(8))
        let found = try call(["action": "search", "query": "\(token) first notes",
                              "start": Self.windowStart, "end": Self.windowEnd])
        XCTAssertEqual((found["events"] as? [[String: Any]])?.map { $0["id"] as? String }, [id])

        let calendars = tool.handle(params: ["action": AnyCodable("calendars")])
        let names = (try JSONSerialization.jsonObject(with: Data(calendars.result.utf8)) as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names?.contains(calendar), true)

        let u = try call(["action": "update", "id": id, "title": "\(prefix) renamed", "location": "", "notes": "second notes",
                          "start": "2028-10-04T19:00:00Z", "end": "2028-10-04T20:30:00Z"])
        XCTAssertEqual(u["title"] as? String, "\(prefix) renamed")
        got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["title"] as? String, "\(prefix) renamed")
        XCTAssertEqual(got["start"] as? String, "2028-10-04T19:00:00Z")
        XCTAssertEqual(got["end"] as? String, "2028-10-04T20:30:00Z")
        XCTAssertNil(got["location"])
        XCTAssertEqual(got["notes"] as? String, "second notes")

        // A new start alone keeps the length.
        _ = try call(["action": "update", "id": id, "start": "2028-10-04T21:00:00Z"])
        got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["end"] as? String, "2028-10-04T22:30:00Z")
        XCTAssertEqual(got["title"] as? String, "\(prefix) renamed")

        let d = try call(["action": "delete", "id": id])
        XCTAssertEqual(d["deleted"] as? Bool, true)
        XCTAssertEqual(try listed().count, 0)
        XCTAssertTrue(refusal(["action": "update", "id": id, "title": "\(prefix) ghost"]).contains("no event found"))
        XCTAssertTrue(refusal(["action": "delete", "id": id]).contains("no event found"))
    }

    // MARK: - All-day

    func testAllDayEvents() throws {
        // Bare dates on both ends mean all-day, and the end is the last day, inclusive.
        let r = try create(["start": "2028-10-05", "end": "2028-10-06"])
        let id = try XCTUnwrap(r["id"] as? String)
        XCTAssertEqual(r["all_day"] as? Bool, true)
        XCTAssertEqual(r["start"] as? String, "2028-10-05")
        XCTAssertEqual(r["end"] as? String, "2028-10-06")
        var got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["all_day"] as? Bool, true)
        XCTAssertEqual(got["start"] as? String, "2028-10-05")
        XCTAssertEqual(got["end"] as? String, "2028-10-06")

        _ = try call(["action": "update", "id": id, "end": "2028-10-08"])
        got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["all_day"] as? Bool, true)
        XCTAssertEqual(got["start"] as? String, "2028-10-05")
        XCTAssertEqual(got["end"] as? String, "2028-10-08")

        // Times of day turn it into a timed event, and bare dates turn it back.
        _ = try call(["action": "update", "id": id, "start": "2028-10-05T17:00:00Z", "end": "2028-10-05T18:00:00Z"])
        got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["all_day"] as? Bool, false)
        XCTAssertEqual(got["start"] as? String, "2028-10-05T17:00:00Z")
        XCTAssertEqual(got["end"] as? String, "2028-10-05T18:00:00Z")
        _ = try call(["action": "update", "id": id, "start": "2028-10-09", "end": "2028-10-09"])
        got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["all_day"] as? Bool, true)
        XCTAssertEqual(got["start"] as? String, "2028-10-09")
        XCTAssertEqual(got["end"] as? String, "2028-10-09")
        _ = try call(["action": "delete", "id": id])

        // With the flag, a UTC midnight still means that calendar day, not the evening before.
        let flagged = try create(["start": "2028-10-12T00:00:00Z", "end": "2028-10-12T00:00:00Z", "all_day": true])
        XCTAssertEqual(flagged["all_day"] as? Bool, true)
        got = try XCTUnwrap(listed().first)
        XCTAssertEqual(got["start"] as? String, "2028-10-12")
        XCTAssertEqual(got["end"] as? String, "2028-10-12")
    }

    // MARK: - Time zone

    /// The case from #75: 3 a.m. Eastern on the 2nd and 4th Tuesday stays 3 a.m. Eastern when the clocks change.
    func testEventTimeZoneHoldsWallClockAcrossDaylightSaving() throws {
        let r = try create(["start": "2028-10-10T03:00:00", "end": "2028-10-10T04:00:00",
                            "event_timezone": "America/New_York", "recurrence": "FREQ=MONTHLY;BYDAY=2TU,4TU"])
        XCTAssertEqual(r["start"] as? String, "2028-10-10T07:00:00Z")
        XCTAssertEqual(r["end"] as? String, "2028-10-10T08:00:00Z")
        XCTAssertEqual(r["event_timezone"] as? String, "America/New_York")
        XCTAssertEqual(r["recurrence"] as? String, "FREQ=MONTHLY;BYDAY=2TU,4TU")

        let through = try listed().filter { ($0["start"] as! String) < "2028-12-01" }
        // US clocks go back on 2028-11-05, so 3 a.m. Eastern moves from 07:00Z to 08:00Z.
        XCTAssertEqual(through.map { $0["start"] as? String },
                       ["2028-10-10T07:00:00Z", "2028-10-24T07:00:00Z", "2028-11-14T08:00:00Z", "2028-11-28T08:00:00Z"])
        XCTAssertEqual(Set(through.map { $0["recurrence"] as? String }), ["FREQ=MONTHLY;BYDAY=2TU,4TU"])
    }

    func testUpdateReadsTimesInTheEventsZone() throws {
        let r = try create(["start": "2028-10-11T09:00:00", "end": "2028-10-11T10:00:00", "event_timezone": "Asia/Tokyo"])
        let id = try XCTUnwrap(r["id"] as? String)
        XCTAssertEqual(r["start"] as? String, "2028-10-11T00:00:00Z")

        // No zone given: the time is read in the zone the event already has.
        let moved = try call(["action": "update", "id": id, "start": "2028-10-11T11:00:00"])
        XCTAssertEqual(moved["start"] as? String, "2028-10-11T02:00:00Z")
        XCTAssertEqual(moved["event_timezone"] as? String, "Asia/Tokyo")

        let rezoned = try call(["action": "update", "id": id, "event_timezone": "Europe/Paris", "start": "2028-10-11T11:00:00"])
        XCTAssertEqual(rezoned["start"] as? String, "2028-10-11T09:00:00Z")
        XCTAssertEqual(rezoned["event_timezone"] as? String, "Europe/Paris")
        XCTAssertEqual(try starts(), ["2028-10-11T09:00:00Z"])
    }

    // MARK: - Repeating

    func testOneOccurrenceCanBeChangedAndDeletedWithoutDisturbingTheRest() throws {
        let r = try create(["start": "2028-11-13T10:00:00", "end": "2028-11-13T11:00:00", "recurrence": "FREQ=DAILY;COUNT=6"])
        let id = try XCTUnwrap(r["id"] as? String)
        XCTAssertEqual(r["recurrence"] as? String, "FREQ=DAILY;COUNT=6")
        let days = (13...18).map { "2028-11-\($0)" }
        XCTAssertEqual(try starts(), days.map { local("\($0)T10:00:00") })

        // Every occurrence shares the id, so the tool must be told which one.
        XCTAssertTrue(refusal(["action": "update", "id": id, "title": "\(prefix) all?"]).contains("pass occurrence"))
        XCTAssertTrue(refusal(["action": "delete", "id": id]).contains("pass occurrence"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "occurrence": "2028-11-14", "recurrence": "weekly"])
            .contains("span=future or span=all"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "occurrence": "2028-12-25", "title": "\(prefix) x"])
            .contains("no occurrence"))

        // Change one: span defaults to this occurrence only.
        let u = try call(["action": "update", "id": id, "occurrence": local("2028-11-14T10:00:00"),
                          "start": "2028-11-14T13:00:00", "title": "\(prefix) moved"])
        XCTAssertEqual(u["span"] as? String, "this")
        var expected = days.map { local("\($0)T10:00:00") }
        expected[1] = local("2028-11-14T13:00:00")
        XCTAssertEqual(try starts(), expected)
        XCTAssertEqual(try listed().map { $0["title"] as? String },
                       [prefix, "\(prefix) moved", prefix, prefix, prefix, prefix])

        // The moved occurrence is still reachable through the series id, by its date.
        _ = try call(["action": "update", "id": id, "occurrence": "2028-11-14", "notes": "moved notes"])
        XCTAssertEqual(try listed().map { $0["notes"] as? String }, [nil, "moved notes", nil, nil, nil, nil])

        // Delete one.
        let d = try call(["action": "delete", "id": id, "occurrence": "2028-11-16"])
        XCTAssertEqual(d["deleted"] as? Bool, true)
        XCTAssertEqual(d["span"] as? String, "this")
        expected.remove(at: 3)
        XCTAssertEqual(try starts(), expected)

        // Later edits, to one occurrence and to the whole series, must not bring it back.
        _ = try call(["action": "update", "id": id, "occurrence": "2028-11-17", "location": "Room 2"])
        XCTAssertEqual(try starts(), expected)
        let all = try call(["action": "update", "id": id, "span": "all", "notes": "series notes"])
        XCTAssertEqual(all["span"] as? String, "all")
        XCTAssertEqual(try starts(), expected, "the deleted occurrence came back after an edit")
        XCTAssertEqual(try listed().filter { $0["notes"] as? String == "series notes" }.count, 4)

        // Moving the whole series is the one edit that can revive it; if so the result must say which day.
        let shifted = try call(["action": "update", "id": id, "span": "all", "occurrence": "2028-11-13",
                                "start": "2028-11-13T11:00:00"])
        let after = try starts()
        XCTAssertEqual(after.first, local("2028-11-13T11:00:00"))
        XCTAssertTrue(after.contains(local("2028-11-18T11:00:00")))
        if after.contains(where: { $0 == local("2028-11-16T11:00:00") }) {
            XCTAssertEqual((shifted["notice"] as? String)?.contains("2028-11-16"), true,
                           "a deleted occurrence came back and the result did not say so")
        }

        XCTAssertEqual(try call(["action": "delete", "id": id, "span": "all"])["deleted"] as? Bool, true)
        XCTAssertEqual(try listed().count, 0)
    }

    func testThisAndFutureOccurrences() throws {
        let r = try create(["start": "2028-12-04T10:00:00", "end": "2028-12-04T11:00:00", "recurrence": "FREQ=WEEKLY;COUNT=5"])
        let id = try XCTUnwrap(r["id"] as? String)
        let weeks = ["2028-12-04", "2028-12-11", "2028-12-18", "2028-12-25", "2029-01-01"].map { local("\($0)T10:00:00") }
        XCTAssertEqual(try starts(), weeks)

        let u = try call(["action": "update", "id": id, "occurrence": "2028-12-18", "span": "future", "title": "\(prefix) later"])
        XCTAssertEqual(u["span"] as? String, "future")
        XCTAssertEqual(try starts(), weeks, "changing later occurrences must not add or drop any")
        XCTAssertEqual(try listed().map { $0["title"] as? String },
                       [prefix, prefix, "\(prefix) later", "\(prefix) later", "\(prefix) later"])

        // The later occurrences may now be a series of their own, so take the id from the listing.
        let laterID = try XCTUnwrap(listed()[3]["id"] as? String)
        _ = try call(["action": "delete", "id": laterID, "occurrence": "2028-12-25", "span": "future"])
        XCTAssertEqual(try starts(), Array(weeks.prefix(3)))

        // Stop the first series repeating: only its first day is left.
        let stopped = try call(["action": "update", "id": id, "span": "all", "recurrence": "none"])
        XCTAssertNil(stopped["recurrence"])
        XCTAssertEqual(try starts(), [weeks[0], weeks[2]])
        XCTAssertNil(try listed()[0]["recurrence"])
    }

    // MARK: - Refusals

    func testBadInputIsRefusedAndNothingIsCreated() throws {
        let times: [String: Any] = ["start": "2028-10-17T17:00:00Z", "end": "2028-10-17T18:00:00Z"]
        func bad(_ extra: [String: Any]) -> String {
            refusal(["action": "create", "title": prefix, "calendar": calendar].merging(times) { $1 }.merging(extra) { $1 })
        }
        XCTAssertTrue(bad(["event_timezone": "Mars/Olympus"]).contains("unknown timezone"))
        XCTAssertTrue(bad(["recurrence": "FREQ=HOURLY"]).contains("recurrence needs FREQ"))
        XCTAssertTrue(bad(["recurrence": "FREQ=WEEKLY;BYDAY=2TU"]).contains("numbered BYDAY"))
        XCTAssertTrue(bad(["start": "next tuesday"]).contains("invalid start date"))
        XCTAssertTrue(bad(["calendar": "\(prefix) no such calendar"]).contains("no calendar found"))
        XCTAssertTrue(bad(["title": ""]).contains("title"))
        _ = bad(["end": "2028-10-17T16:00:00Z"])
        XCTAssertEqual(try listed().count, 0)
    }

    func testRefusedUpdateChangesNothing() throws {
        let id = try XCTUnwrap(create(["start": "2028-10-18T17:00:00Z", "end": "2028-10-18T18:00:00Z"])["id"] as? String)
        XCTAssertTrue(refusal(["action": "update", "id": id]).contains("nothing to update"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "span": "some", "title": "\(prefix) x"]).contains("invalid span"))
        XCTAssertTrue(refusal(["action": "delete", "id": id, "span": "some"]).contains("invalid span"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "title": ""]).contains("title can't be empty"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "title": "\(prefix) x", "event_timezone": "Mars/Olympus"])
            .contains("unknown timezone"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "title": "\(prefix) x", "end": "2028-10-18T16:00:00Z"])
            .contains("end is before start"))
        XCTAssertTrue(refusal(["action": "update", "id": id, "title": "\(prefix) x", "calendar": "\(prefix) no such calendar"])
            .contains("no calendar found"))

        // A refusal that names several changes must apply none of them.
        let got = try XCTUnwrap(listed().first)
        XCTAssertEqual(try listed().count, 1)
        XCTAssertEqual(got["title"] as? String, prefix)
        XCTAssertEqual(got["start"] as? String, "2028-10-18T17:00:00Z")
        XCTAssertEqual(got["end"] as? String, "2028-10-18T18:00:00Z")
    }

    func testReadOnlyCalendarIsRefused() throws {
        let readOnly = try XCTUnwrap(
            CalendarIntegration.allCalendars().first {
                !$0.allowsContentModifications && CalendarIntegration.resolveCalendars(name: $0.title)?.first == $0
            }?.title,
            "this Mac has no read-only calendar (a subscription or Birthdays) to be refused by")
        XCTAssertTrue(refusal(["action": "create", "title": prefix, "calendar": readOnly,
                               "start": "2028-10-19T17:00:00Z", "end": "2028-10-19T18:00:00Z"]).contains("read-only"))

        let id = try XCTUnwrap(create(["start": "2028-10-19T17:00:00Z", "end": "2028-10-19T18:00:00Z"])["id"] as? String)
        XCTAssertTrue(refusal(["action": "update", "id": id, "calendar": readOnly]).contains("read-only"))
        XCTAssertEqual(try listed().map { $0["id"] as? String }, [id], "the event must stay where it was")
    }
}
