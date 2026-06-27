import XCTest
@testable import AppleToolsLib

final class PhotosToolTests: XCTestCase {
    var tool: PhotosTool!

    override func setUp() {
        super.setUp()
        tool = PhotosTool(host: .test())
    }

    // MARK: - Tool definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "photos")
    }

    func testToolDefinitionHasRequiredAction() {
        XCTAssertEqual(tool.definition.parameters?.required, ["action"])
    }

    func testToolDefinitionProperties() {
        let props = tool.definition.parameters?.properties
        XCTAssertNotNil(props?["action"])
        XCTAssertNotNil(props?["query"])
        XCTAssertNotNil(props?["album"])
        XCTAssertNotNil(props?["start_date"])
        XCTAssertNotNil(props?["end_date"])
        XCTAssertNotNil(props?["limit"])
        XCTAssertNotNil(props?["id"])
        XCTAssertNotNil(props?["full_resolution"])
        XCTAssertNotNil(props?["person"])
        XCTAssertNotNil(props?["match"])
    }

    // MARK: - Person name normalization / matching (pure logic)

    func testNormalizePersonNameTrimsAndLowercases() {
        XCTAssertEqual(PhotosIntegration.normalizePersonName("  Sandy   Ford "), "sandy ford")
        XCTAssertEqual(PhotosIntegration.normalizePersonName("SANDY\tFORD"), "sandy ford")
    }

    func testMatchPeoplePrefersExactOverSubstring() {
        let people = [
            PhotosIntegration.NamedPerson(pk: 1, fullName: "Sandy Ford", displayName: "Sandy"),
            PhotosIntegration.NamedPerson(pk: 2, fullName: "Sandra Fordham", displayName: nil),
        ]
        // Exact full-name match wins; the substring candidate is excluded.
        let matched = PhotosIntegration.matchPeople(people, query: "sandy ford")
        XCTAssertEqual(matched.map { $0.pk }, [1])
    }

    func testMatchPeopleExactDisplayName() {
        let people = [
            PhotosIntegration.NamedPerson(pk: 1, fullName: "Sandy Ford", displayName: "Sandy"),
            PhotosIntegration.NamedPerson(pk: 2, fullName: "John Cole Kostibas", displayName: "John"),
        ]
        let matched = PhotosIntegration.matchPeople(people, query: "Sandy")
        XCTAssertEqual(matched.map { $0.pk }, [1])
    }

    func testMatchPeopleSubstringMatchesMultiple() {
        let people = [
            PhotosIntegration.NamedPerson(pk: 1, fullName: "John Kostibas", displayName: "John"),
            PhotosIntegration.NamedPerson(pk: 2, fullName: "John Cole Kostibas", displayName: nil),
            PhotosIntegration.NamedPerson(pk: 3, fullName: "Sandy Ford", displayName: nil),
        ]
        // No exact match for "kostibas" -> substring matches both Kostibases.
        let matched = PhotosIntegration.matchPeople(people, query: "kostibas")
        XCTAssertEqual(Set(matched.map { $0.pk }), [1, 2])
    }

    func testMatchPeopleEmptyQueryReturnsNothing() {
        let people = [PhotosIntegration.NamedPerson(pk: 1, fullName: "Sandy Ford", displayName: nil)]
        XCTAssertTrue(PhotosIntegration.matchPeople(people, query: "   ").isEmpty)
    }

    func testNamedPersonLabelFallsBackToDisplayName() {
        XCTAssertEqual(PhotosIntegration.NamedPerson(pk: 1, fullName: nil, displayName: "Tim").label, "Tim")
        XCTAssertEqual(PhotosIntegration.NamedPerson(pk: 1, fullName: "", displayName: "Tim").label, "Tim")
        XCTAssertEqual(PhotosIntegration.NamedPerson(pk: 1, fullName: "Tim Smith", displayName: "Tim").label, "Tim Smith")
    }

    // MARK: - Parameter validation

    func testNilParams() {
        let (result, isError) = tool.handle(params: nil)
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    func testMissingAction() {
        let (result, isError) = tool.handle(params: [:])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    func testUnknownAction() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("delete"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown action"))
        XCTAssertTrue(result.contains("search or fetch"))
    }

    func testFetchMissingID() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("fetch"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    func testFetchEmptyID() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("fetch"),
            "id": AnyCodable(""),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    // MARK: - Search (requires Photos access)
    // These tests exercise search with actual Photos library access.
    // They will be skipped if Photos permission is denied.

    func testSearchReturnsResults() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "limit": AnyCodable(5),
        ])
        // If access denied, that's OK in CI — just verify the error message is correct.
        if isError {
            XCTAssertTrue(result.contains("Photos access denied"))
            return
        }
        XCTAssertTrue(result.contains("\"count\""))
        XCTAssertTrue(result.contains("\"photos\""))
    }

    func testSearchWithInvalidStartDate() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "start_date": AnyCodable("not-a-date"),
        ])
        if isError && result.contains("Photos access denied") { return }
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid start_date format"))
    }

    func testSearchWithInvalidEndDate() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "end_date": AnyCodable("not-a-date"),
        ])
        if isError && result.contains("Photos access denied") { return }
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid end_date format"))
    }

    func testSearchNonexistentAlbum() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "album": AnyCodable("This Album Does Not Exist 12345"),
        ])
        if isError && result.contains("Photos access denied") { return }
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("no album found"))
    }

    func testFetchNonexistentPhoto() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("fetch"),
            "id": AnyCodable("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/L0/001"),
        ])
        if isError && result.contains("Photos access denied") { return }
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("no photo found"))
    }
}
