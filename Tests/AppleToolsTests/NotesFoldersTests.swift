import XCTest
@testable import AppleToolsLib

/// Offline tests for `listFolders`' record parsing and Recently-Deleted
/// filtering. The AppleScript that detects deleted/zombie folders and emits the
/// per-folder deleted flag can only be exercised against a live Notes store;
/// these tests stub the runner and pin the pure-Swift half — that a flagged
/// folder is excluded from the listing and never acts as a path parent, and
/// that paths are still built for live nested folders.
final class NotesFoldersTests: XCTestCase {

    override func tearDown() {
        NotesIntegration.runAppleScript = NotesIntegration.defaultRunAppleScript
        super.tearDown()
    }

    private func record(_ fields: [String]) -> String {
        fields.joined(separator: NotesIntegration.fieldSep) + NotesIntegration.recordSep
    }

    private func stubFolders(_ output: String) {
        NotesIntegration.runAppleScript = { _, _, _ in (output, nil) }
    }

    func testExcludesRecentlyDeletedAndBuildsNestedPath() throws {
        // Fields: F, id, name, count, deletedFlag
        var out = ""
        out += record(["F", "id-work", "Work", "3", "0"])
        out += record(["F", "id-notes", "Notes", "10", "0"])
        out += record(["F", "id-sub", "Sub", "1", "0"])
        out += record(["F", "id-old", "Old", "0", "1"])   // Recently Deleted
        out += record(["E", "id-work", "id-sub"])          // Work -> Sub
        stubFolders(out)

        let folders = try NotesIntegration.listFolders()
        let names = folders.map { $0.name }
        XCTAssertEqual(Set(names), ["Work", "Notes", "Sub"])
        XCTAssertFalse(names.contains("Old"), "Recently-Deleted folder must be excluded")

        let sub = folders.first { $0.name == "Sub" }
        XCTAssertEqual(sub?.parentID, "id-work")
        XCTAssertEqual(sub?.path, "Work/Sub")
    }

    func testDeletedFolderNeverActsAsPathParent() throws {
        // A live child whose only parent is a deleted folder must not inherit a
        // phantom path through the trashed parent; it degrades to no path.
        var out = ""
        out += record(["F", "id-keep", "Keep", "2", "0"])
        out += record(["F", "id-old", "Old", "0", "1"])   // deleted parent
        out += record(["E", "id-old", "id-keep"])          // Old -> Keep
        stubFolders(out)

        let folders = try NotesIntegration.listFolders()
        XCTAssertEqual(folders.map { $0.name }, ["Keep"])
        let keep = folders.first { $0.name == "Keep" }
        // parentID still reflects the raw edge, but no path is built because the
        // parent isn't a live folder.
        XCTAssertNil(keep?.path)
    }

    func testMissingDeletedFlagTreatedAsLive() throws {
        // Defensive: a 4-field record (no deleted flag) is treated as live so a
        // partial/older record can't silently drop a real folder.
        let out = record(["F", "id-a", "Alpha", "2"])
        stubFolders(out)

        let folders = try NotesIntegration.listFolders()
        XCTAssertEqual(folders.map { $0.name }, ["Alpha"])
    }
}
