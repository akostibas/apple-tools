import XCTest
@testable import AppleToolsLib

final class FilesToolTests: XCTestCase {
    var tool: FilesTool!
    var tempDir: String = ""

    override func setUp() {
        super.setUp()
        tool = FilesTool(host: .test())

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

    // MARK: - List

    func testListRoot() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable(tempDir),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["path"] as? String, tempDir)
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

    func testListDefaultsToDocumentsRoot() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["path"] as? String, ".")
        XCTAssertGreaterThan(json["total"] as! Int, 0)
    }

    func testListPagination() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable(tempDir),
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
            "path": AnyCodable(tempDir + "/hello.txt"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not a directory"))
    }

    func testListPathTraversal() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("../../etc"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"))
    }

    // A sibling of ~/Documents whose name shares the "Documents" prefix
    // (e.g. "~/Documents Backup") must be rejected — a bare hasPrefix
    // check on the string form would accept it.
    func testListSiblingPrefixEscape() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("list"),
            "path": AnyCodable("../Documents Backup"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"), result)
    }

    func testFetchSiblingPrefixEscape() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("fetch"),
            "path": AnyCodable("../Documents_backup/secret.txt"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"), result)
    }

    func testInfoSiblingPrefixEscape() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable("../DocumentsX"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("path escapes"), result)
    }

    // MARK: - Info

    func testInfoFile() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(tempDir + "/hello.txt"),
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
            "path": AnyCodable(tempDir + "/subdir"),
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
            "path": AnyCodable(tempDir + "/photo.jpg"),
        ])
        XCTAssertFalse(isError, result)

        let json = parseJSON(result)
        XCTAssertEqual(json["content_type"] as? String, "image/jpeg")
    }

    func testInfoNotFound() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable(tempDir + "/nope.txt"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not found"))
    }

    func testInfoPathTraversal() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("info"),
            "path": AnyCodable("../../etc/passwd"),
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
