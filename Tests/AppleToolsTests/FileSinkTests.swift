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

    func testPreExistingWorldReadableDirIsTightenedTo0700() throws {
        // A pre-existing 0755 output dir must be tightened — createDirectory only
        // sets the mode on dirs it creates (#19.1).
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        _ = LocalFileSink(outputDir: dir).deliver(filename: "x", data: Data("hi".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }

    func testWrittenFileIsOwnerOnly() throws {
        guard case .success(let ref) = LocalFileSink(outputDir: dir)
            .deliver(filename: "secret.txt", data: Data("s".utf8)) else {
            return XCTFail("expected success")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: ref.value)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testDoesNotWriteThroughPlantedSymlink() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // An attacker plants a dangling symlink named like our expected output,
        // pointing at a file outside the output dir. `fileExists` would follow it
        // and `data.write` would create the target — an arbitrary-write primitive.
        let outsideTarget = NSTemporaryDirectory() + "apple-tools-victim-\(UUID().uuidString).txt"
        let linkPath = (dir as NSString).appendingPathComponent("screenshot.png")
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: outsideTarget)

        guard case .success(let ref) = LocalFileSink(outputDir: dir)
            .deliver(filename: "screenshot.png", data: Data("payload".utf8)) else {
            return XCTFail("expected success")
        }
        // The victim path must NOT have been created by following the symlink.
        XCTAssertFalse(fm.fileExists(atPath: outsideTarget), "must not write through the symlink target")
        // A distinct, real file was written instead.
        XCTAssertNotEqual((ref.value as NSString).lastPathComponent, "screenshot.png")
        XCTAssertTrue(ref.value.hasPrefix(dir))
        XCTAssertEqual(try String(contentsOfFile: ref.value, encoding: .utf8), "payload")

        try? fm.removeItem(atPath: outsideTarget)
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
