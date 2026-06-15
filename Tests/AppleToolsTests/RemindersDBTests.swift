import XCTest
@testable import AppleToolsLib

final class RemindersDBTests: XCTestCase {

    // MARK: - Graceful degradation

    func testSubtasksForNonexistentParent() {
        // Should return empty array, not crash
        let result = RemindersDB.subtasks(forParentID: "nonexistent-\(UUID().uuidString)")
        XCTAssertEqual(result.count, 0)
    }

    func testParentForNonexistentChild() {
        // Should return nil, not crash
        let result = RemindersDB.parent(forChildID: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testBatchParentsEmptyInput() {
        let result = RemindersDB.parents(forChildIDs: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testBatchSubtasksEmptyInput() {
        let result = RemindersDB.subtasks(forParentIDs: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSubtasksWithBogusDBPath() {
        // Should return empty, not crash, when the DB doesn't exist
        let result = RemindersDB.subtasks(forParentID: "anything", dbPath: "/nonexistent/path.sqlite")
        XCTAssertEqual(result.count, 0)
    }

    func testParentWithBogusDBPath() {
        let result = RemindersDB.parent(forChildID: "anything", dbPath: "/nonexistent/path.sqlite")
        XCTAssertNil(result)
    }

    // MARK: - Integration tests (require readable Reminders DB)

    func testSubtasksForKnownParent() throws {
        // Find a parent with subtasks by scanning the DB. If the DB isn't
        // accessible or has no subtask relationships, skip.
        guard let (parentID, expectedCount) = findParentWithSubtasks() else {
            throw XCTSkip("No readable Reminders DB or no subtask relationships found")
        }

        let subs = RemindersDB.subtasks(forParentID: parentID)
        XCTAssertEqual(subs.count, expectedCount, "Expected \(expectedCount) subtasks for parent \(parentID)")
        for sub in subs {
            XCTAssertFalse(sub.id.isEmpty)
            XCTAssertFalse(sub.title.isEmpty)
        }
    }

    func testParentForKnownChild() throws {
        guard let (parentID, _) = findParentWithSubtasks() else {
            throw XCTSkip("No readable Reminders DB or no subtask relationships found")
        }

        // Get a child of this parent, then verify we can look up the parent
        let subs = RemindersDB.subtasks(forParentID: parentID)
        guard let firstChild = subs.first else {
            throw XCTSkip("Subtasks disappeared between calls")
        }

        let parent = RemindersDB.parent(forChildID: firstChild.id)
        XCTAssertNotNil(parent)
        XCTAssertEqual(parent?.id, parentID)
    }

    func testBatchParentsIntegration() throws {
        guard let (parentID, _) = findParentWithSubtasks() else {
            throw XCTSkip("No readable Reminders DB or no subtask relationships found")
        }

        let subs = RemindersDB.subtasks(forParentID: parentID)
        let childIDs = subs.map { $0.id }
        let parentMap = RemindersDB.parents(forChildIDs: childIDs)

        // Every child should map to the same parent
        for childID in childIDs {
            XCTAssertEqual(parentMap[childID]?.id, parentID)
        }
    }

    func testBatchSubtasksIntegration() throws {
        guard let (parentID, expectedCount) = findParentWithSubtasks() else {
            throw XCTSkip("No readable Reminders DB or no subtask relationships found")
        }

        let subtaskMap = RemindersDB.subtasks(forParentIDs: [parentID])
        XCTAssertEqual(subtaskMap[parentID]?.count, expectedCount)
    }

    // MARK: - Helpers

    /// Scans the Reminders DB for any parent that has subtasks.
    /// Returns (parentEKID, childCount) or nil if not available.
    private func findParentWithSubtasks() -> (String, Int)? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storesDir = "\(home)/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: storesDir) else { return nil }

        let dbFiles = entries
            .filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }
            .map { "\(storesDir)/\($0)" }

        for path in dbFiles {
            guard FileManager.default.isReadableFile(atPath: path) else { continue }
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db = db else { continue }
            defer { sqlite3_close(db) }

            let sql = """
                SELECT p.ZDACALENDARITEMUNIQUEIDENTIFIER, COUNT(*)
                FROM ZREMCDREMINDER c
                JOIN ZREMCDREMINDER p ON c.ZPARENTREMINDER = p.Z_PK
                WHERE c.ZMARKEDFORDELETION = 0 AND p.ZMARKEDFORDELETION = 0
                GROUP BY p.ZDACALENDARITEMUNIQUEIDENTIFIER
                HAVING COUNT(*) > 0
                LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { continue }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW,
               let cStr = sqlite3_column_text(stmt, 0) {
                let parentID = String(cString: cStr)
                let count = Int(sqlite3_column_int(stmt, 1))
                return (parentID, count)
            }
        }
        return nil
    }
}

import SQLite3
