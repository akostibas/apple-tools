import XCTest
@testable import AppleToolsLib

/// Opens a real URI, so a window appears in front of the user: attended only.
/// Run with `make test-attended TOOL=open_uri`.
final class OpenURILiveTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try LiveTest.attended("open_uri")
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(LiveTest.label) \(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func testOpensAFolderAndRefusesAMalformedURI() {
        let tool = OpenURITool(host: .test())
        // A folder URI: Finder shows it, and nothing leaves the Mac.
        let (out, isError) = tool.handle(params: ["uri": AnyCodable(dir.absoluteString)])
        XCTAssertFalse(isError, out)
        let (bad, badIsError) = tool.handle(params: ["uri": AnyCodable("")])
        XCTAssertTrue(badIsError, "an empty URI must be refused, got: \(bad)")
    }
}
