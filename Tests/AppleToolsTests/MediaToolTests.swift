import XCTest
@testable import AppleToolsLib

final class MediaToolTests: XCTestCase {
    var tool: MediaTool!

    override func setUp() {
        super.setUp()
        tool = MediaTool()
    }

    private func json(_ result: String) -> [String: Any] {
        let data = result.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - Definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "media")
    }

    func testToolDefinitionRequiresAction() {
        XCTAssertEqual(tool.definition.parameters?.required, ["action"])
    }

    func testRecentActionIsReadOnly() {
        guard case .perAction(let map) = tool.accessPolicy else { return XCTFail() }
        XCTAssertEqual(map["recent"], .read)
    }

    // MARK: - Validation

    func testNilParams() {
        let (result, isError) = tool.handle(params: nil)
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    func testUnknownAction() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("bogus")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown action"))
    }

    func testRejectsNonPositiveHours() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("recent"),
            "hours": AnyCodable(0),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("hours must be positive"))
    }

    // MARK: - Envelope

    /// Runs against whatever real stores exist. On a machine with no Podcasts
    /// DB the window is simply empty — but the envelope shape must hold either
    /// way (count present, items an array, window echoed).
    func testRecentReturnsWellFormedEnvelope() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("recent"),
            "hours": AnyCodable(1),
        ])
        XCTAssertFalse(isError)
        let obj = json(result)
        XCTAssertEqual(obj["window_hours"] as? Int, 1)
        XCTAssertNotNil(obj["count"] as? Int)
        XCTAssertNotNil(obj["items"] as? [Any])
    }
}
