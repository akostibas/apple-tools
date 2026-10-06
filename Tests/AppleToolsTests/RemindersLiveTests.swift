import XCTest
@testable import AppleToolsLib

/// Live round-trip tests against the real Reminders store. Skipped unless
/// APPLE_TOOLS_REMINDERS_LIVE=1, because they create and delete reminders in
/// the default list. Run with:
///
///     APPLE_TOOLS_REMINDERS_LIVE=1 swift test --filter RemindersLiveTests
final class RemindersLiveTests: XCTestCase {

    private let tool = RemindersTool()
    private var created: [String] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLE_TOOLS_REMINDERS_LIVE"] == "1",
                          "set APPLE_TOOLS_REMINDERS_LIVE=1 to run live Reminders tests")
    }

    override func tearDown() {
        for id in created { _ = tool.handle(params: ["action": AnyCodable("delete"), "id": AnyCodable(id)]) }
        super.tearDown()
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        guard !isError else { throw NSError(domain: "reminders", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func create(_ extra: [String: Any] = [:]) throws -> [String: Any] {
        var p: [String: Any] = ["action": "create", "title": "apple-tools live test \(UUID().uuidString.prefix(8))"]
        p.merge(extra) { $1 }
        let r = try call(p)
        created.append(try XCTUnwrap(r["id"] as? String))
        return r
    }

    func testCreateRepeatingWithPriorityAndFlag() throws {
        let r = try create(["due_date": "2027-03-02T09:00:00Z", "recurrence": "FREQ=WEEKLY;BYDAY=TU",
                            "priority": "high", "flagged": true])
        XCTAssertEqual(r["recurrence"] as? String, "FREQ=WEEKLY;BYDAY=TU")
        XCTAssertEqual(r["priority"] as? String, "high")
        let got = try call(["action": "get", "id": r["id"]!])
        XCTAssertEqual(got["recurrence"] as? String, "FREQ=WEEKLY;BYDAY=TU")
        XCTAssertEqual(got["is_flagged"] as? Bool, true)
    }

    func testUpdateFieldsAndClear() throws {
        let id = try create(["due_date": "2027-03-02T09:00:00Z", "recurrence": "daily"])["id"]!
        let u = try call(["action": "update", "id": id, "title": "apple-tools live renamed",
                          "notes": "n", "priority": "low", "flagged": true])
        XCTAssertEqual(u["title"] as? String, "apple-tools live renamed")
        XCTAssertEqual(u["priority"] as? String, "low")

        // Clearing the due date alone must refuse while it still repeats.
        XCTAssertThrowsError(try call(["action": "update", "id": id, "due_date": "none"]))
        let cleared = try call(["action": "update", "id": id, "due_date": "none", "recurrence": "none", "flagged": false])
        XCTAssertNil(cleared["due_date"])
        XCTAssertNil(cleared["recurrence"])
        XCTAssertEqual(try call(["action": "get", "id": id])["is_flagged"] as? Bool, false)
    }

    func testRepeatWithoutDueDateRefused() throws {
        XCTAssertThrowsError(try create(["recurrence": "weekly"]))
    }

    func testListsSearchGetComplete() throws {
        let lists = tool.handle(params: ["action": AnyCodable("lists")])
        XCTAssertFalse(lists.isError)
        XCTAssertTrue(lists.result.contains("\"is_default\" : true") || lists.result.contains("\"is_default\":true"))

        let r = try create(["due_date": "2027-03-02T09:00:00Z", "notes": "live-search-marker"])
        let id = r["id"] as! String
        let found = try call(["action": "search", "query": "live-search-marker", "flagged": false])
        XCTAssertTrue((found["reminders"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
        let byDate = try call(["action": "search", "due_date": "2027-03-01T00:00:00Z", "due_date_end": "2027-03-03T00:00:00Z"])
        XCTAssertTrue((byDate["reminders"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)

        XCTAssertEqual(try call(["action": "get", "id": id])["notes"] as? String, "live-search-marker")
        XCTAssertEqual(try call(["action": "complete", "id": id])["completed"] as? Bool, true)
        XCTAssertEqual(try call(["action": "get", "id": id])["completed"] as? Bool, true)
    }

    func testCreateList() throws {
        let name = "apple-tools live list \(UUID().uuidString.prefix(8))"
        let r = try call(["action": "create-list", "name": name])
        defer { RemindersIntegration.resolveLists(name: name)?.forEach { try? RemindersIntegration.removeList($0) } }
        XCTAssertEqual(r["name"] as? String, name)
        XCTAssertThrowsError(try call(["action": "create-list", "name": name]), "duplicate name must be refused")
        let inList = try create(["list_name": name])
        XCTAssertEqual(inList["list"] as? String, name)
    }

    func testDelete() throws {
        let id = try create()["id"] as! String
        XCTAssertEqual(try call(["action": "delete", "id": id])["deleted"] as? Bool, true)
        created.removeAll()
        XCTAssertThrowsError(try call(["action": "get", "id": id]))
    }
}
