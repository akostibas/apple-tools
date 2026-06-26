import XCTest
@testable import AppleToolsLib

final class FileSinkTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "apple-tools-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testDeliverWritesFileAndReturnsPath() throws {
        let sink = LocalFileSink(outputDir: dir)
        let bytes = Data("hello".utf8)
        let result = sink.deliver(filename: "note.txt", data: bytes)
        guard case .success(let ref) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(ref.key, "path")
        let path = ref.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertTrue(path.hasPrefix(dir))
    }

    func testDeliverAvoidsClobberingExistingFile() throws {
        let sink = LocalFileSink(outputDir: dir)
        guard case .success(let r1) = sink.deliver(filename: "a.txt", data: Data("one".utf8)),
              case .success(let r2) = sink.deliver(filename: "a.txt", data: Data("two".utf8)) else {
            return XCTFail("expected both deliveries to succeed")
        }
        let p1 = r1.value, p2 = r2.value
        XCTAssertNotEqual(p1, p2)
        XCTAssertEqual(try String(contentsOfFile: p1, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOfFile: p2, encoding: .utf8), "two")
    }

    func testOutputDirIsOwnerOnly() throws {
        _ = LocalFileSink(outputDir: dir).deliver(filename: "x", data: Data())
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }

    func testFilenameIsReducedToLastPathComponent() {
        guard case .success(let ref) = LocalFileSink(outputDir: dir)
            .deliver(filename: "../../etc/evil.txt", data: Data()) else {
            return XCTFail("expected success")
        }
        let path = ref.value
        XCTAssertEqual((path as NSString).lastPathComponent, "evil.txt")
        XCTAssertTrue(path.hasPrefix(dir))
    }
}
