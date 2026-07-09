import XCTest
@testable import AppleToolsLib

final class DocumentsToolTests: XCTestCase {
    var tool: DocumentsTool!
    var tempDir: String = ""

    override func setUp() {
        super.setUp()
        tool = DocumentsTool(host: .test())

        // Create a temp directory structure under ~/Documents for testing.
        // We use a unique subdirectory to avoid interfering with real files.
        tempDir = "._apple_tools_test_\(UUID().uuidString)"
        let base = NSHomeDirectory() + "/Documents/" + tempDir
        let fm = FileManager.default
        try! fm.createDirectory(atPath: base + "/subdir", withIntermediateDirectories: true)
        fm.createFile(atPath: base + "/hello.txt", contents: "hello world".data(using: .utf8))
        fm.createFile(atPath: base + "/photo.jpg", contents: Data([0xFF, 0xD8, 0xFF]))
        fm.createFile(atPath: base + "/subdir/nested.txt", contents: "nested".data(using: .utf8))
    }

    override func tearDown() {
        let base = NSHomeDirectory() + "/Documents/" + tempDir
        try? FileManager.default.removeItem(atPath: base)
        super.tearDown()
    }

    // All tool paths are namespaced by root name; the default root is "Documents".
    private var docs: String { "Documents/" + tempDir }

    // MARK: - List

    func testListRoot() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable(docs),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["path"] as? String, docs)
        XCTAssertEqual(json["total"] as? Int, 3) // subdir, hello.txt, photo.jpg

        let results = json["results"] as! [[String: Any]]
        // Directories come first
        XCTAssertEqual(results[0]["name"] as? String, "subdir")
        XCTAssertEqual(results[0]["type"] as? String, "directory")
        // Then files alphabetically
        XCTAssertEqual(results[1]["name"] as? String, "hello.txt")
        XCTAssertEqual(results[1]["type"] as? String, "file")
        XCTAssertEqual(results[2]["name"] as? String, "photo.jpg")
    }

    // An empty path lists the configured roots, not ~/Documents contents.
    func testListEmptyPathListsRoots() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["path"] as? String, ".")
        XCTAssertEqual(json["total"] as? Int, 1)

        let results = json["results"] as! [[String: Any]]
        XCTAssertEqual(results[0]["name"] as? String, "Documents")
        XCTAssertEqual(results[0]["type"] as? String, "directory")
    }

    // A bare root name lists that root's top level.
    func testListBareRootName() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("Documents"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["path"] as? String, "Documents")
        XCTAssertGreaterThan(json["total"] as! Int, 0)
    }

    func testListPagination() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable(docs),
            "offset": AnyCodable(1),
            "limit": AnyCodable(1),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["total"] as? Int, 3)
        XCTAssertEqual(json["offset"] as? Int, 1)
        XCTAssertEqual(json["limit"] as? Int, 1)

        let results = json["results"] as! [[String: Any]]
        XCTAssertEqual(results.count, 1)
        // Offset 1 skips the directory, lands on first file
        XCTAssertEqual(results[0]["name"] as? String, "hello.txt")
    }

    func testListNotADirectory() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable(docs + "/hello.txt"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not a directory"))
    }

    func testListPathTraversal() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("Documents/../../etc"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"))
    }

    // A path whose first component is not a configured root is rejected with
    // an error naming the valid roots — including absolute-looking paths.
    func testUnknownRoot() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("Desktop/stuff"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown root 'Desktop'"), result)
        XCTAssertTrue(result.contains("Documents"), result)
    }

    func testUnknownRootAbsolutePath() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable("/etc/passwd"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown root"), result)
    }

    // A sibling of ~/Documents whose name shares the "Documents" prefix
    // (e.g. "~/Documents Backup") must be rejected — a bare hasPrefix
    // check would accept it.
    func testListSiblingPrefixEscape() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("Documents/../Documents Backup"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"), result)
    }

    func testFetchSiblingPrefixEscape() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("fetch"),
            "path": AnyCodable("Documents/../Documents_backup/secret.txt"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"), result)
    }

    func testInfoSiblingPrefixEscape() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable("Documents/../DocumentsX"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"), result)
    }

    // MARK: - Info

    func testInfoFile() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(docs + "/hello.txt"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["name"] as? String, "hello.txt")
        XCTAssertEqual(json["type"] as? String, "file")
        XCTAssertEqual(json["size"] as? Int, 11) // "hello world"
        XCTAssertEqual(json["content_type"] as? String, "text/plain")
        XCTAssertNotNil(json["created"])
        XCTAssertNotNil(json["modified"])
    }

    func testInfoDirectory() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(docs + "/subdir"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["name"] as? String, "subdir")
        XCTAssertEqual(json["type"] as? String, "directory")
        // Directories should not have content_type
        XCTAssertNil(json["content_type"])
    }

    func testInfoImageMimeType() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(docs + "/photo.jpg"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["content_type"] as? String, "image/jpeg")
    }

    func testInfoNotFound() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(docs + "/nope.txt"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not found"))
    }

    func testInfoPathTraversal() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable("Documents/../../etc/passwd"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"))
    }

    func testInfoMissingPath() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter"))
    }

    // MARK: - Multiple roots

    /// A tool with a second root outside ~/Documents.
    private func makeMultiRootTool() -> (tool: DocumentsTool, base: String) {
        let base = NSTemporaryDirectory() + "apple_tools_root_\(UUID().uuidString)"
        let fm = FileManager.default
        try! fm.createDirectory(atPath: base + "/inner", withIntermediateDirectories: true)
        fm.createFile(atPath: base + "/shared.txt", contents: "shared doc".data(using: .utf8))
        let tool = DocumentsTool(host: .test(), roots: [
            .documents,
            DocumentRoot(name: "samlexi", path: base),
        ])
        addTeardownBlock { try? fm.removeItem(atPath: base) }
        return (tool, base)
    }

    func testMultiRootListRoots() {
        let (multi, _) = makeMultiRootTool()
        let (result, isError) = multi.handle(params: ["action": AnyCodable("list")])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["total"] as? Int, 2)
        let names = (json["results"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertEqual(names, ["Documents", "samlexi"])
    }

    func testMultiRootListAndInfo() {
        let (multi, _) = makeMultiRootTool()
        let (result, isError) = multi.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("samlexi"),
        ])
        XCTAssertFalse(isError, result)
        let names = (parseJSON(result)["results"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertEqual(names, ["inner", "shared.txt"])

        let (info, infoErr) = multi.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable("samlexi/shared.txt"),
        ])
        XCTAssertFalse(infoErr, info)
        XCTAssertEqual(parseJSON(info)["size"] as? Int, 10) // "shared doc"
    }

    // Escaping one root must fail even when the destination is inside a
    // *different* configured root — the jail is per-root.
    func testMultiRootCrossRootTraversal() {
        let (multi, base) = makeMultiRootTool()
        let escape = "samlexi/" + String(repeating: "../", count: base.split(separator: "/").count)
            + NSHomeDirectory().dropFirst() + "/Documents/\(tempDir)/hello.txt"
        let (result, isError) = multi.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(escape),
        ])
        XCTAssertTrue(isError, result)
        XCTAssertTrue(result.contains("path escapes root 'samlexi'"), result)
    }

    // Search-hit mapping: absolute paths map back to namespaced tool paths
    // via the longest matching root; unrelated paths map to nil.
    func testToolPathMapping() {
        let (multi, base) = makeMultiRootTool()
        let standardizedBase = ((base as NSString).standardizingPath)
        XCTAssertEqual(
            multi.toolPath(forAbsolutePath: standardizedBase + "/inner/x.txt"),
            "samlexi/inner/x.txt")
        XCTAssertEqual(
            multi.toolPath(forAbsolutePath: NSHomeDirectory() + "/Documents/a.pdf"),
            "Documents/a.pdf")
        XCTAssertEqual(multi.toolPath(forAbsolutePath: standardizedBase), "samlexi")
        XCTAssertNil(multi.toolPath(forAbsolutePath: "/etc/passwd"))
        // Sibling-prefix absolute path maps to no root.
        XCTAssertNil(multi.toolPath(forAbsolutePath: NSHomeDirectory() + "/Documents Backup/a.pdf"))
    }

    // The schema is generated from the configured roots so the model knows
    // what's searchable.
    func testDefinitionNamesRoots() {
        let (multi, _) = makeMultiRootTool()
        let def = multi.definition
        XCTAssertTrue(def.description.contains("'Documents'"), def.description)
        XCTAssertTrue(def.description.contains("'samlexi'"), def.description)
        let pathHelp = def.parameters!.properties!["path"]!.description!
        XCTAssertTrue(pathHelp.contains("Documents, samlexi"), pathHelp)
    }

    // Zero roots would make every action an error; the tool falls back to
    // the default root instead.
    func testEmptyRootsFallsBackToDefault() {
        let empty = DocumentsTool(host: .test(), roots: [])
        XCTAssertEqual(empty.roots.map(\.name), ["Documents"])
    }

    // Tilde expansion in configured root paths (config files use "~/...").
    func testRootTildeExpansion() {
        let root = DocumentRoot(name: "x", path: "~/Documents")
        XCTAssertEqual(root.path, NSHomeDirectory() + "/Documents")
    }

    // MARK: - Action validation

    func testUnknownAction() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("delete"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown action"))
    }

    func testMissingAction() {
        let (result, isError) = tool.handle(params: [:])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    // MARK: - Helpers

    private func parseJSON(_ str: String) -> [String: Any] {
        let data = str.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
