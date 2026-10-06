import XCTest
@testable import AppleToolsLib

/// Live tests for the Notes actions not covered by NotesLiveTests /
/// NotesSearchLiveTests: folders, list, append, move, delete, rename-folder.
/// Skipped unless APPLE_TOOLS_NOTES_LIVE=1. Run with:
///
///     APPLE_TOOLS_NOTES_LIVE=1 swift test --filter NotesActionsLiveTests
///
/// Scripted folder deletes don't stick in iCloud (the folder comes back), so the
/// suite reuses three fixed folders and only ever deletes notes. Locked notes
/// can't be created by script, so the locked refusal is untested here.
final class NotesActionsLiveTests: XCTestCase {

    private let tool = NotesTool()
    private let run = UUID().uuidString.prefix(6)
    private let folderA = "AppleToolsLive A"
    private let folderB = "AppleToolsLive B"
    private let folderC = "AppleToolsLive C"
    private let renamedB = "AppleToolsLive B renamed"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLE_TOOLS_NOTES_LIVE"] == "1",
                          "set APPLE_TOOLS_NOTES_LIVE=1 to run live Notes tests")
    }

    override func tearDown() {
        runOsa("""
        tell application "Notes"
            repeat with f in (every folder whose name is "\(renamedB)")
                set name of f to "\(folderB)"
            end repeat
            repeat with nm in {"\(folderA)", "\(folderB)", "\(folderC)"}
                repeat with f in (every folder whose name is nm)
                    delete (every note of f whose name contains "\(run)")
                end repeat
            end repeat
        end tell
        """)
        super.tearDown()
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        guard !isError else { throw NSError(domain: "notes", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func errorText(_ params: [String: Any]) -> String {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        XCTAssertTrue(isError, "expected an error, got \(out)")
        return out
    }

    /// Every note title carries the run id so teardown deletes only this run's notes.
    private func create(_ title: String, in folder: String) throws -> String {
        try XCTUnwrap(call(["action": "create", "title": "\(title) \(run)", "body": "body", "folder": folder])["id"] as? String)
    }

    func testFoldersListAppend() throws {
        let id = try create("live list note", in: folderA)
        let folders = try call(["action": "folders"])["folders"] as? [[String: Any]] ?? []
        XCTAssertTrue(folders.contains { $0["name"] as? String == folderA })
        let listed = try call(["action": "list", "folder": folderA])["notes"] as? [[String: Any]] ?? []
        XCTAssertTrue(listed.contains { $0["id"] as? String == id })

        _ = try call(["action": "append", "id": id, "text": "appended-marker"])
        XCTAssertTrue((try call(["action": "read", "id": id])["content"] as? String ?? "").contains("appended-marker"))
    }

    func testMove() throws {
        let id = try create("live move note", in: folderA)
        _ = try create("placeholder", in: folderB)
        let moved = try call(["action": "move", "id": id, "folder": folderB])
        XCTAssertEqual(moved["folder"] as? String, folderB)
        XCTAssertEqual(try call(["action": "read", "id": moved["id"] as! String])["folder"] as? String, folderB)

        XCTAssertTrue(errorText(["action": "move", "id": id, "folder": "AppleToolsLive Nope"]).contains("no folder named"))
    }

    func testDeleteRefusesAmbiguousTitleAndSkipsTrash() throws {
        let title = "live dup \(run)"
        let first = try create("live dup", in: folderA)
        _ = try create("live dup", in: folderA)

        XCTAssertTrue(errorText(["action": "delete", "title": title]).contains("more than one note"))
        XCTAssertEqual(try call(["action": "delete", "id": first])["id"] as? String, first)
        // The first copy now sits in Recently Deleted; the title is unambiguous again.
        XCTAssertNoThrow(try call(["action": "delete", "title": title]))
        XCTAssertTrue(errorText(["action": "delete", "title": title]).contains("not found"))
    }

    func testRenameFolder() throws {
        _ = try create("n", in: folderB)
        _ = try create("n", in: folderC)
        let renamed = try call(["action": "rename-folder", "folder": folderB, "name": renamedB])
        XCTAssertEqual(renamed["name"] as? String, renamedB)
        let names = (try call(["action": "folders"])["folders"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains(renamedB))
        XCTAssertFalse(names.contains(folderB))

        XCTAssertTrue(errorText(["action": "rename-folder", "folder": folderC, "name": renamedB]).contains("already exists"))
    }

    @discardableResult
    private func runOsa(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
