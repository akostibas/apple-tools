import XCTest

/// Pins the "none, or broken?" ladder that the read-only group relies on.
final class LiveTargetsTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-targets-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func run(refresh: Bool = false, discover: [String], present: Set<String>) throws -> LiveTargets.Outcome {
        try LiveTargets(file: file, refresh: refresh, stamp: "then")
            .evaluate("k", settle: .lookIn(app: "Podcasts"), discover: { discover }, find: { present.contains($0) })
    }

    private func isLost(_ o: LiveTargets.Outcome) -> Bool { if case .lost = o { return true }; return false }
    private func isNothing(_ o: LiveTargets.Outcome) -> Bool { if case .nothingToCheck = o { return true }; return false }

    func testEmptyMacIsNothingToCheckNotAPass() throws {
        XCTAssertTrue(isNothing(try run(discover: [], present: [])))
    }

    func testFirstRunRemembersAndLaterRunsDoNotRediscover() throws {
        XCTAssertEqual(try run(discover: ["a", "b"], present: ["a", "b"]), .ok(found: 2, of: 2))
        // Discovery now returns nothing (the store moved): memory must still drive the check.
        XCTAssertTrue(isLost(try run(discover: [], present: [])))
    }

    func testOrdinaryDriftIsNotAnAlarm() throws {
        _ = try run(discover: ["a", "b", "c"], present: ["a", "b", "c"])
        XCTAssertEqual(try run(discover: [], present: ["c"]), .ok(found: 1, of: 3))
    }

    func testRefreshReplacesTargetsButNeverForgetsOnEmpty() throws {
        _ = try run(discover: ["a"], present: ["a"])
        XCTAssertEqual(try run(refresh: true, discover: ["z"], present: ["z"]), .ok(found: 1, of: 1))
        XCTAssertTrue(isLost(try run(refresh: true, discover: [], present: [])))
        XCTAssertEqual(try run(discover: [], present: ["z"]), .ok(found: 1, of: 1))
    }

    func testListedButNotFindableIsALoss() throws {
        XCTAssertTrue(isLost(try run(discover: ["a"], present: [])))
    }

    func testGateIsOptInAndCanBeLimitedToTools() {
        func reason(_ env: [String: String]) -> String? {
            LiveTest.skipReason(env: env, flag: LiveTest.readVar, tool: "notes", hint: "make test")
        }
        XCTAssertNotNil(reason([:]))
        XCTAssertNil(reason([LiveTest.readVar: "1"]))
        XCTAssertNil(reason([LiveTest.readVar: "1", LiveTest.toolsVar: "notes,calendar"]))
        XCTAssertNotNil(reason([LiveTest.readVar: "1", LiveTest.toolsVar: "calendar"]))
    }
}
