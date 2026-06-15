import XCTest
@testable import AppleToolsLib

final class RemindersToolTests: XCTestCase {
    var tool: RemindersTool!

    override func setUp() {
        super.setUp()
        tool = RemindersTool()
    }

    // MARK: - Parameter validation

    func testMissingAction() {
        let (result, isError) = tool.handle(params: [:])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    func testUnknownAction() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("delete"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown action"))
        XCTAssertTrue(result.contains("lists, search, get, create, or complete"))
    }

    func testCreateMissingTitle() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("create"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: title"))
    }

    func testCreateEmptyTitle() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("create"),
            "title": AnyCodable(""),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: title"))
    }

    func testCompleteMissingID() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("complete"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    func testCompleteEmptyID() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("complete"),
            "id": AnyCodable(""),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    func testSearchNoFilters() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("search requires at least one of"))
    }

    func testGetMissingID() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("get"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    func testGetEmptyID() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("get"),
            "id": AnyCodable(""),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    func testNilParams() {
        let (result, isError) = tool.handle(params: nil)
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    // MARK: - Tool definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "reminders")
    }

    func testToolDefinitionHasRequiredAction() {
        XCTAssertEqual(tool.definition.parameters?.required, ["action"])
    }

    func testToolDefinitionProperties() {
        let props = tool.definition.parameters?.properties
        XCTAssertNotNil(props?["action"])
        XCTAssertNotNil(props?["list_name"])
        XCTAssertNotNil(props?["title"])
        XCTAssertNotNil(props?["due_date"])
        XCTAssertNotNil(props?["due_date_end"])
        XCTAssertNotNil(props?["notes"])
        XCTAssertNotNil(props?["id"])
        XCTAssertNotNil(props?["query"])
        XCTAssertNotNil(props?["show_completed"])
    }

    // MARK: - EventKit integration tests
    // These tests require Reminders TCC access. They create and clean up
    // their own reminders so they're safe to run on a dev machine.
    // If access is denied, the tests skip rather than fail.

    func testListLists() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("lists"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertFalse(isError, result)

        // Should be a JSON array
        let data = result.data(using: .utf8)!
        let lists = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        // Every macOS user has at least one reminder list
        XCTAssertGreaterThan(lists.count, 0)

        // Each list should have name and id
        for list in lists {
            XCTAssertNotNil(list["name"])
            XCTAssertNotNil(list["id"])
        }
    }

    func testCreateAndCompleteReminder() throws {
        // Create
        let testTitle = "apple-tools probe test \(UUID().uuidString.prefix(8))"
        let (createResult, createError) = tool.handle(params: [
            "action": AnyCodable("create"),
            "title": AnyCodable(testTitle),
            "notes": AnyCodable("Auto-created by RemindersToolTests"),
        ])

        if createError && createResult.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertFalse(createError, createResult)

        let createJSON = parseJSON(createResult)
        let id = createJSON["id"] as! String
        XCTAssertEqual(createJSON["title"] as? String, testTitle)
        XCTAssertFalse(id.isEmpty)

        // Verify it shows up in search by keyword
        let (searchResult, searchError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(testTitle),
        ])
        XCTAssertFalse(searchError, searchResult)
        let searchJSON = parseJSON(searchResult)
        XCTAssertEqual(searchJSON["count"] as? Int, 1)

        // Verify get returns full details
        let (getResult, getError) = tool.handle(params: [
            "action": AnyCodable("get"),
            "id": AnyCodable(id),
        ])
        XCTAssertFalse(getError, getResult)
        let getJSON = parseJSON(getResult)
        XCTAssertEqual(getJSON["title"] as? String, testTitle)
        XCTAssertEqual(getJSON["notes"] as? String, "Auto-created by RemindersToolTests")

        // Complete it
        let (completeResult, completeError) = tool.handle(params: [
            "action": AnyCodable("complete"),
            "id": AnyCodable(id),
        ])
        XCTAssertFalse(completeError, completeResult)

        let completeJSON = parseJSON(completeResult)
        XCTAssertEqual(completeJSON["completed"] as? Bool, true)

        // Should not appear in incomplete search
        let (searchAfter, searchAfterError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(testTitle),
        ])
        XCTAssertFalse(searchAfterError, searchAfter)
        let searchAfterJSON = parseJSON(searchAfter)
        XCTAssertEqual(searchAfterJSON["count"] as? Int, 0)

        // But should appear with show_completed
        let (searchCompleted, searchCompletedError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(testTitle),
            "show_completed": AnyCodable(true),
        ])
        XCTAssertFalse(searchCompletedError, searchCompleted)
        let searchCompletedJSON = parseJSON(searchCompleted)
        XCTAssertEqual(searchCompletedJSON["count"] as? Int, 1)
    }

    func testCreateWithDueDate() throws {
        let testTitle = "apple-tools due date test \(UUID().uuidString.prefix(8))"
        let (createResult, createError) = tool.handle(params: [
            "action": AnyCodable("create"),
            "title": AnyCodable(testTitle),
            "due_date": AnyCodable("2099-12-31T12:00:00Z"),
            "notes": AnyCodable("Auto-created by RemindersToolTests"),
        ])

        if createError && createResult.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertFalse(createError, createResult)

        // Search by keyword and verify due date is present
        let (searchResult, _) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(testTitle),
        ])
        let searchJSON = parseJSON(searchResult)
        let reminders = searchJSON["reminders"] as! [[String: Any]]
        XCTAssertEqual(reminders.count, 1)
        XCTAssertNotNil(reminders[0]["due_date"])

        // Clean up: complete it
        let id = reminders[0]["id"] as! String
        _ = tool.handle(params: [
            "action": AnyCodable("complete"),
            "id": AnyCodable(id),
        ])
    }

    func testCreateWithInvalidDueDate() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("create"),
            "title": AnyCodable("test"),
            "due_date": AnyCodable("not-a-date"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid due_date format"))
    }

    func testSearchWithInvalidListName() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "list_name": AnyCodable("Nonexistent List \(UUID().uuidString)"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("no reminder list found"))
    }

    func testCompleteNonexistentReminder() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("complete"),
            "id": AnyCodable("nonexistent-id-\(UUID().uuidString)"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("reminder not found"))
    }

    func testGetNonexistentReminder() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("get"),
            "id": AnyCodable("nonexistent-id-\(UUID().uuidString)"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("reminder not found"))
    }

    func testSearchWithDateRange() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "due_date": AnyCodable("2099-01-01T00:00:00Z"),
            "due_date_end": AnyCodable("2099-12-31T23:59:59Z"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertFalse(isError, result)
        let json = parseJSON(result)
        XCTAssertNotNil(json["count"])
        XCTAssertNotNil(json["reminders"])
    }

    func testSearchWithInvalidDueDate() throws {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "due_date": AnyCodable("garbage"),
        ])

        if isError && result.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }

        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid due_date format"))
    }

    func testSearchTruncatesLongNotes() throws {
        let longNotes = String(repeating: "a", count: 200)
        let testTitle = "apple-tools truncate test \(UUID().uuidString.prefix(8))"
        let (createResult, createError) = tool.handle(params: [
            "action": AnyCodable("create"),
            "title": AnyCodable(testTitle),
            "notes": AnyCodable(longNotes),
        ])

        if createError && createResult.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }
        XCTAssertFalse(createError, createResult)

        // Search should truncate notes
        let (searchResult, searchError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(testTitle),
        ])
        XCTAssertFalse(searchError, searchResult)
        let searchJSON = parseJSON(searchResult)
        let reminders = searchJSON["reminders"] as! [[String: Any]]
        XCTAssertEqual(reminders.count, 1)
        let notes = reminders[0]["notes"] as! String
        XCTAssertLessThanOrEqual(notes.count, 101 + 1) // 100 chars + ellipsis
        XCTAssertTrue(notes.hasSuffix("…"))

        // Get should return full notes
        let id = reminders[0]["id"] as! String
        let (getResult, getError) = tool.handle(params: [
            "action": AnyCodable("get"),
            "id": AnyCodable(id),
        ])
        XCTAssertFalse(getError, getResult)
        let getJSON = parseJSON(getResult)
        XCTAssertEqual(getJSON["notes"] as? String, longNotes)

        // Clean up
        _ = tool.handle(params: [
            "action": AnyCodable("complete"),
            "id": AnyCodable(id),
        ])
    }

    func testSearchByListName() throws {
        // First get the list names
        let (listsResult, listsError) = tool.handle(params: [
            "action": AnyCodable("lists"),
        ])

        if listsError && listsResult.contains("access denied") {
            throw XCTSkip("Reminders access not granted")
        }
        XCTAssertFalse(listsError, listsResult)

        let data = listsResult.data(using: .utf8)!
        let lists = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        guard let firstList = lists.first, let listName = firstList["name"] as? String else {
            throw XCTSkip("No reminder lists available")
        }

        // Search by list name only (no query)
        let (searchResult, searchError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "list_name": AnyCodable(listName),
        ])
        XCTAssertFalse(searchError, searchResult)
        let json = parseJSON(searchResult)
        XCTAssertNotNil(json["count"])
        XCTAssertNotNil(json["reminders"])
    }

    // MARK: - Helpers

    private func parseJSON(_ str: String) -> [String: Any] {
        let data = str.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
