import XCTest
@testable import AppleToolsLib

/// Offline tests for `notes search`. Stubs the store-backed search seam so we
/// pin the contract without touching the real Notes store:
///  - the `full_text` flag is threaded from the tool down to the lookup,
///  - pagination slices the hit list while `total` stays the full match count,
///  - the JSON output schema is unchanged (issue #13's "schema unchanged" AC).
final class NotesSearchTests: XCTestCase {

    override func tearDown() {
        NotesIntegration.searchLookup = NotesStoreSearch.search
        super.tearDown()
    }

    private func hit(_ id: String, _ title: String) -> NotesStoreSearch.Hit {
        NotesStoreSearch.Hit(id: id, title: title, modified: "2026-01-01T00:00:00Z", snippet: "snip-\(id)")
    }

    /// Capture what the integration passes to the store lookup, return canned hits.
    private func stub(_ hits: [NotesStoreSearch.Hit],
                      onCall: @escaping (String, String?, Bool) -> Void = { _, _, _ in }) {
        NotesIntegration.searchLookup = { query, folder, fullText in
            onCall(query, folder, fullText)
            return hits
        }
    }

    // MARK: - full_text flag threading

    func testDefaultSearchRequestsTitleOnly() throws {
        var seenFullText: Bool? = nil
        stub([hit("p1", "A")]) { _, _, ft in seenFullText = ft }
        _ = try NotesIntegration.searchNotes(query: "x", folder: nil, offset: 0, limit: 20)
        XCTAssertEqual(seenFullText, false, "default path must not scan bodies")
    }

    func testFullTextFlagForwarded() throws {
        var seenFullText: Bool? = nil
        var seenFolder: String? = "unset"
        stub([hit("p1", "A")]) { _, folder, ft in seenFullText = ft; seenFolder = folder }
        _ = try NotesIntegration.searchNotes(query: "x", folder: "Work", offset: 0, limit: 20, fullText: true)
        XCTAssertEqual(seenFullText, true)
        XCTAssertEqual(seenFolder, "Work")
    }

    func testToolParsesFullTextFlag() {
        var seenFullText: Bool? = nil
        stub([hit("p1", "A")]) { _, _, ft in seenFullText = ft }
        let tool = NotesTool()
        _ = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("x"),
            "full_text": AnyCodable(true),
        ])
        XCTAssertEqual(seenFullText, true)
    }

    // MARK: - Pagination

    func testPaginationSlicesButTotalIsFullCount() throws {
        let hits = (1...5).map { hit("p\($0)", "T\($0)") }
        stub(hits)
        let (total, notes) = try NotesIntegration.searchNotes(query: "x", folder: nil, offset: 1, limit: 2)
        XCTAssertEqual(total, 5, "total reflects all matches, not the page size")
        XCTAssertEqual(notes.map { $0.id }, ["p2", "p3"], "offset/limit slice the hit list")
    }

    func testOffsetPastEndYieldsEmptyPageWithFullTotal() throws {
        stub([hit("p1", "A"), hit("p2", "B")])
        let (total, notes) = try NotesIntegration.searchNotes(query: "x", folder: nil, offset: 10, limit: 5)
        XCTAssertEqual(total, 2)
        XCTAssertTrue(notes.isEmpty)
    }

    func testNegativeOffsetIsClampedNotATrap() throws {
        // dropFirst traps on a negative count; a caller-supplied offset of -1
        // must degrade to 0, not crash the process.
        stub([hit("p1", "A"), hit("p2", "B")])
        let (total, notes) = try NotesIntegration.searchNotes(query: "x", folder: nil, offset: -1, limit: 5)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(notes.map { $0.id }, ["p1", "p2"])
    }

    func testToolClampsNegativeOffset() {
        stub([hit("p1", "A")])
        let tool = NotesTool()
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("x"),
            "offset": AnyCodable(-3),
        ])
        XCTAssertFalse(isError, result)
        XCTAssertTrue(result.contains("p1"))
    }

    // MARK: - Output schema

    func testSearchJSONSchemaUnchanged() throws {
        stub([hit("p1", "Title One")])
        let tool = NotesTool()
        let (json, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("x"),
        ])
        XCTAssertFalse(isError)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["total", "offset", "limit", "count", "notes"])
        let notes = obj["notes"] as! [[String: Any]]
        XCTAssertEqual(Set(notes[0].keys), ["id", "title", "modified", "snippet"])
        XCTAssertEqual(notes[0]["id"] as? String, "p1")
        XCTAssertEqual(notes[0]["title"] as? String, "Title One")
    }
}
