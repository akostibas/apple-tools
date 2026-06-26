import XCTest
@testable import AppleToolsLib

final class ScreenshotToolTests: XCTestCase {
    var tool: ScreenshotTool!

    override func setUp() {
        super.setUp()
        tool = ScreenshotTool(host: .test())
    }

    // MARK: - Tool definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "screenshot")
    }

    func testToolDefinitionDescription() {
        XCTAssertTrue(tool.definition.description.contains("screenshot"))
    }

    func testToolDefinitionHasNoRequiredParams() {
        XCTAssertNil(tool.definition.parameters?.required)
    }
}
