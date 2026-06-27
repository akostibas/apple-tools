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

    // MARK: - Email search flags (from-email scalpel + spam filter)

    func testEmailFromEmailFlagMapsExactValue() throws {
        // --from-email maps to the from_email param against the real email schema,
        // preserving the FULL address (the scalpel keeps the domain).
        let email = EmailTool(host: .test())
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--from-email", "pinbot@pinterest.com"],
            schema: email.definition.parameters, action: "search")
        XCTAssertEqual(p["from_email"]?.value as? String, "pinbot@pinterest.com")
        XCTAssertEqual(p["action"]?.value as? String, "search")
    }

    func testEmailExcludeSpamBareFlagIsTrue() throws {
        let email = EmailTool(host: .test())
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--exclude-spam"],
            schema: email.definition.parameters, action: "search")
        XCTAssertEqual(p["exclude_spam"]?.value as? Bool, true)
    }

    func testEmailHumansOnlyBareFlagIsTrue() throws {
        let email = EmailTool(host: .test())
        let p = try CLIArgumentMapper.buildParams(
            tokens: ["--humans-only"],
            schema: email.definition.parameters, action: "search")
        XCTAssertEqual(p["humans_only"]?.value as? Bool, true)
    }
}
