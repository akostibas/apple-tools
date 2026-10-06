import XCTest
@testable import AppleToolsLib

/// Live tests for the Notes actions not covered by NotesLiveTests /
/// NotesSearchLiveTests: folders, list, append, move, delete, rename-folder.
/// Skipped unless APPLE_TOOLS_NOTES_LIVE=1. Run with:
///
///     APPLE_TOOLS_NOTES_LIVE=1 swift test --filter NotesActionsLiveTests
///
/// Locked notes can't be created by script, so the locked refusal is untested here.
final class NotesActionsLiveTests: XCTestCase {

    private let tool = NotesTool()
    private let tag = "AppleToolsLive" + UUID().uuidString.prefix(6)
    private var folderA: String { tag + "A" }
    private var folderB: String { tag + "B" }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLE_TOOLS_NOTES_LIVE"] == "1",
                          "set APPLE_TOOLS_NOTES_LIVE=1 to run live Notes tests")
    }

    override func tearDown() {
        for suffix in ["A", "B", "B2", "C"] {
            let name = tag + suffix
            runOsa("tell application \"Notes\" to delete (every folder whose name is \"\(name)\")")
        }
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

    private func create(_ title: String, in folder: String) throws -> String {
        try XCTUnwrap(call(["action": "create", "title": title, "body": "body", "folder": folder])["id"] as? String)
    }

    func testFoldersListAppend() throws {
        let id = try create("live list note", in: folderA)
        let folders = try call(["action": "folders"])["folders"] as? [[String: Any]] ?? []
        XCTAssertTrue(folders.contains { $0["name"] as? String == folderA })
        let listed = try call(["action": "list", "folder": folderA])["notes"] as? [[String: Any]] ?? []
        XCTAssertEqual(listed.compactMap { $0["id"] as? String }, [id])

        _ = try call(["action": "append", "id": id, "text": "appended-marker"])
        XCTAssertTrue((try call(["action": "read", "id": id])["content"] as? String ?? "").contains("appended-marker"))
    }

    func testMove() throws {
        let id = try create("live move note", in: folderA)
        _ = try create("placeholder", in: folderB)
        let moved = try call(["action": "move", "id": id, "folder": folderB])
        XCTAssertEqual(moved["folder"] as? String, folderB)
        XCTAssertEqual(try call(["action": "read", "id": moved["id"] as! String])["folder"] as? String, folderB)

        XCTAssertTrue(errorText(["action": "move", "id": id, "folder": tag + "Nope"]).contains("no folder named"))
    }

    func testDeleteRefusesAmbiguousTitleAndSkipsTrash() throws {
        let title = "live dup \(tag)"
        let first = try create(title, in: folderA)
        _ = try create(title, in: folderA)

        XCTAssertTrue(errorText(["action": "delete", "title": title]).contains("more than one note"))
        XCTAssertEqual(try call(["action": "delete", "id": first])["id"] as? String, first)
        // The first copy now sits in Recently Deleted; the title is unambiguous again.
        XCTAssertNoThrow(try call(["action": "delete", "title": title]))
        XCTAssertTrue(errorText(["action": "delete", "title": title]).contains("not found"))
    }

    func testRenameFolder() throws {
        _ = try create("n", in: folderB)
        _ = try create("n", in: tag + "C")
        let renamed = try call(["action": "rename-folder", "folder": folderB, "name": tag + "B2"])
        XCTAssertEqual(renamed["name"] as? String, tag + "B2")
        let names = (try call(["action": "folders"])["folders"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains(tag + "B2"))
        XCTAssertFalse(names.contains(folderB))

        XCTAssertTrue(errorText(["action": "rename-folder", "folder": tag + "C", "name": tag + "B2"]).contains("already exists"))
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
