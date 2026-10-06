import Contacts
import XCTest
@testable import AppleToolsLib

/// Live tests against the real Contacts store, using one throwaway contact
/// created and deleted per test. Skipped unless APPLE_TOOLS_CONTACTS_LIVE=1:
///
///     APPLE_TOOLS_CONTACTS_LIVE=1 swift test --filter ContactsLiveTests
final class ContactsLiveTests: XCTestCase {

    private let tool = ContactsTool()
    private let marker = "Appletoolslive" + UUID().uuidString.prefix(6).lowercased()
    private var fixture: CNMutableContact!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLE_TOOLS_CONTACTS_LIVE"] == "1",
                          "set APPLE_TOOLS_CONTACTS_LIVE=1 to run live Contacts tests")
        let c = CNMutableContact()
        c.givenName = "Test"
        c.familyName = marker
        c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 415 555 0101"))]
        c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "\(marker)@example.com" as NSString)]
        try ContactsIntegration.add(c)
        fixture = c
    }

    override func tearDown() {
        if let f = fixture { try? ContactsIntegration.remove(f) }
        super.tearDown()
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        guard !isError else { throw NSError(domain: "contacts", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func values(_ c: [String: Any], _ key: String) -> [String] {
        (c[key] as? [[String: String]] ?? []).compactMap { $0["value"] }
    }

    func testSearchAndGet() throws {
        let hits = try call(["action": "search", "query": marker])["contacts"] as? [[String: Any]] ?? []
        XCTAssertEqual(hits.compactMap { $0["id"] as? String }, [fixture.identifier])
        let byEmail = try call(["action": "search", "query": "\(marker)@example.com"])["contacts"] as? [[String: Any]] ?? []
        XCTAssertEqual(byEmail.count, 1)

        let got = try call(["action": "get", "id": fixture.identifier])
        XCTAssertEqual(got["name"] as? String, "Test \(marker)")
        XCTAssertEqual(values(got, "phones"), ["+14155550101"])
    }

    func testSetAndClearSingleFields() throws {
        let u = try call(["action": "update", "id": fixture.identifier, "job_title": "Engineer",
                          "organization": "Acme", "nickname": "Tess", "birthday": "1990-04-15"])
        XCTAssertEqual(u["job_title"] as? String, "Engineer")
        XCTAssertEqual(u["organization"] as? String, "Acme")
        XCTAssertEqual(u["nickname"] as? String, "Tess")
        XCTAssertEqual(u["birthday"] as? String, "1990-04-15")

        let cleared = try call(["action": "update", "id": fixture.identifier, "job_title": "", "birthday": "none"])
        XCTAssertNil(cleared["job_title"])
        XCTAssertNil(cleared["birthday"])
        XCTAssertEqual(cleared["organization"] as? String, "Acme", "untouched fields stay")
    }

    func testAddAndRemoveEntriesLeavesOthersAlone() throws {
        let added = try call(["action": "update", "id": fixture.identifier, "add_phone": "(415) 555-0199",
                              "add_email": "second@example.com", "add_url": "https://example.com",
                              "add_address": "1 Main St; Springfield; IL; 62701; USA", "label": "home"])
        XCTAssertEqual(Set(values(added, "phones")), ["+14155550101", "+14155550199"])
        XCTAssertEqual(values(added, "emails").count, 2)
        XCTAssertEqual(values(added, "urls"), ["https://example.com"])
        XCTAssertTrue(values(added, "addresses").first?.contains("Springfield") == true)

        // Phone removal matches by digits, regardless of formatting.
        let removed = try call(["action": "update", "id": fixture.identifier, "remove_phone": "415-555-0101",
                                "remove_email": "SECOND@example.com", "remove_url": "https://example.com",
                                "remove_address": "1 main st"])
        XCTAssertEqual(values(removed, "phones"), ["+14155550199"])
        XCTAssertEqual(values(removed, "emails"), ["\(marker)@example.com"])
        XCTAssertNil(removed["urls"])
        XCTAssertNil(removed["addresses"])
    }

    func testRemovingMissingValueIsAnError() throws {
        XCTAssertThrowsError(try call(["action": "update", "id": fixture.identifier, "remove_phone": "+1 999 555 0000"]))
        XCTAssertThrowsError(try call(["action": "update", "id": fixture.identifier]), "nothing to update")
    }
}
