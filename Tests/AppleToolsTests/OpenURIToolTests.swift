import XCTest
@testable import AppleToolsLib

final class OpenURIToolTests: XCTestCase {
    var tool: OpenURITool!

    override func setUp() {
        super.setUp()
        tool = OpenURITool()
    }

    // MARK: - Tool definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "open_uri")
    }

    func testToolDefinitionDescription() {
        XCTAssertTrue(tool.definition.description.contains("URI"))
    }

    func testToolDefinitionRequiresURI() {
        XCTAssertEqual(tool.definition.parameters?.required, ["uri"])
    }

    // MARK: - Parameter validation

    func testMissingURIParameter() {
        let (result, isError) = tool.handle(params: [:])
        XCTAssertTrue(isError)
        XCTAssertEqual(result, "missing required parameter: uri")
    }

    func testNilParams() {
        let (result, isError) = tool.handle(params: nil)
        XCTAssertTrue(isError)
        XCTAssertEqual(result, "missing required parameter: uri")
    }

    func testEmptyURIParameter() {
        let (result, isError) = tool.handle(params: ["uri": AnyCodable("")])
        XCTAssertTrue(isError)
        XCTAssertEqual(result, "missing required parameter: uri")
    }

    func testInvalidURI() {
        // URL(string:) rejects strings with certain invalid characters.
        let (result, isError) = tool.handle(params: ["uri": AnyCodable("ht tp://bad url with spaces")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid URI"))
    }

    // MARK: - Preflight

    func testPreflightNoPermissionsRequired() {
        let (ok, message) = tool.preflight()
        XCTAssertTrue(ok)
        XCTAssertEqual(message, "no permissions required")
    }
}
