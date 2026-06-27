import XCTest
@testable import AppleToolsLib

final class CLIArgumentMapperTests: XCTestCase {

    private func schema() -> ParameterSchema {
        ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: nil),
                "calendar_name": PropertySchema(type_: "string", description: nil),
                "limit": PropertySchema(type_: "integer", description: nil),
                "verbose": PropertySchema(type_: "boolean", description: nil),
                "attachments": PropertySchema(type_: "array", description: nil, items: ItemsSchema(type_: "string")),
            ],
            required: ["action"]
        )
    }

    func testInjectsActionAndCoercesTypes() throws {
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--calendar-name", "Work", "--limit", "5"],
            schema: schema(),
            action: "list"
        )
        XCTAssertEqual(p["action"]?.value as? String, "list")
        XCTAssertEqual(p["calendar_name"]?.value as? String, "Work")
        XCTAssertEqual(p["limit"]?.value as? Int, 5)
    }

    func testDashAndUnderscoreFlagsBothMap() throws {
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--calendar_name", "Home"], schema: schema(), action: nil)
        XCTAssertEqual(p["calendar_name"]?.value as? String, "Home")
    }

    func testBareBooleanFlagIsTrue() throws {
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--verbose"], schema: schema(), action: nil)
        XCTAssertEqual(p["verbose"]?.value as? Bool, true)
    }

    func testArrayFlagSplitsAndAccumulates() throws {
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--attachments", "a.txt,b.txt", "--attachments", "c.txt"],
            schema: schema(), action: nil)
        let arr = (p["attachments"]?.value as? [Any])?.compactMap { $0 as? String }
        XCTAssertEqual(arr, ["a.txt", "b.txt", "c.txt"])
    }

    func testUnknownFlagDefaultsToString() throws {
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--whatever", "123"], schema: schema(), action: nil)
        XCTAssertEqual(p["whatever"]?.value as? String, "123")
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(
            try CLIArgumentMapper.buildParams(tokens: ["--calendar-name"], schema: schema(), action: nil)
        ) { error in
            XCTAssertEqual(error as? CLIArgumentMapper.MappingError, .missingValue(flag: "calendar_name"))
        }
    }

    func testNonFlagPositionalThrows() {
        XCTAssertThrowsError(
            try CLIArgumentMapper.buildParams(tokens: ["oops"], schema: schema(), action: nil)
        ) { error in
            XCTAssertEqual(error as? CLIArgumentMapper.MappingError, .unexpectedArgument("oops"))
        }
    }

    /// The new `imessage stats` interface (#3) rides the generic dispatch: the
    /// real tool schema must map `stats --since … --limit …` with no per-tool
    /// argument code, coercing limit to Int.
    func testImessageStatsActionMapsAgainstToolSchema() throws {
        let imsg = IMessageTool(host: .test())
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--since", "2026-01-01T00:00:00Z", "--limit", "5"],
            schema: imsg.definition.parameters,
            action: "stats"
        )
        XCTAssertEqual(p["action"]?.value as? String, "stats")
        XCTAssertEqual(p["since"]?.value as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(p["limit"]?.value as? Int, 5)
    }
}
