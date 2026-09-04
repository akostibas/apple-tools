import XCTest
@testable import AppleToolsLib

/// Offline tests for `notes list`. Same seam trick as NotesSearchTests: stub
/// the store lookup so the contract is pinned without reading the real store.
final class NotesListTests: XCTestCase {

    override func tearDown() {
        NotesIntegration.listLookup = NotesStoreSearch.list
        super.tearDown()
    }

    private func hit(_ id: String, _ modified: String) -> NotesStoreSearch.Hit {
        NotesStoreSearch.Hit(id: id, title: "title-\(id)", modified: modified, snippet: "")
    }

    func testFolderForwardedAndAllNotesReturned() throws {
        var seenFolder: String? = "unset"
        NotesIntegration.listLookup = { folder in
            seenFolder = folder
            return [self.hit("p1", "2026-01-02T00:00:00Z"), self.hit("p2", "2026-01-01T00:00:00Z")]
        }
        let (total, notes) = try NotesIntegration.listNotes(folder: "Work", offset: 0, limit: 50)
        XCTAssertEqual(seenFolder, "Work")
        XCTAssertEqual(total, 2)
        XCTAssertEqual(notes.map { $0.id }, ["p1", "p2"])
        XCTAssertEqual(notes.first?.modified, "2026-01-02T00:00:00Z",
                       "modification time is the whole point — it is what change detection diffs on")
    }

    /// `total` must stay the full count while the page is sliced, or a caller
    /// paging a big folder cannot tell it was truncated.
    func testPaginationSlicesButTotalIsFullCount() throws {
        NotesIntegration.listLookup = { _ in (1...5).map { self.hit("p\($0)", "2026-01-0\($0)T00:00:00Z") } }
        let (total, notes) = try NotesIntegration.listNotes(folder: nil, offset: 1, limit: 2)
        XCTAssertEqual(total, 5)
        XCTAssertEqual(notes.map { $0.id }, ["p2", "p3"])
    }

    func testListActionReturnsJSONWithModifiedTimes() throws {
        NotesIntegration.listLookup = { _ in [self.hit("p1", "2026-01-02T00:00:00Z")] }
        let (result, isError) = NotesTool().handle(params: [
            "action": AnyCodable("list"),
            "folder": AnyCodable("Work"),
        ])
        XCTAssertFalse(isError)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(json["total"] as? Int, 1)
        let notes = try XCTUnwrap(json["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.first?["id"] as? String, "p1")
        XCTAssertEqual(notes.first?["modified"] as? String, "2026-01-02T00:00:00Z")
    }
}
