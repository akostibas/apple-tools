import Contacts
import XCTest
@testable import AppleToolsLib

/// Live tests against the real Contacts store, using one throwaway contact
/// created and deleted per test. Run with `bin/check --slow --tool contacts`.
final class ContactsLiveTests: XCTestCase {

    private let tool = ContactsTool()
    // Letters only: digits in the marker would phone-match unrelated contacts in search.
    private let marker = "Appletoolslive" + String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    private var fixture: CNMutableContact!
    private static let testName = "apple-tools live test"

    override func setUpWithError() throws {
        try LiveTest.writes("contacts", "search", "read", "create", "update", "delete")
        let c = CNMutableContact()
        c.givenName = Self.testName
        c.familyName = marker
        c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 415 555 0101"))]
        c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "\(marker)@example.com" as NSString)]
        try ContactsIntegration.add(c)
        fixture = c
    }

    private var created: [String] = []

    override func tearDown() {
        for id in [fixture?.identifier].compactMap({ $0 }) + created {
            let (out, isError) = tool.handle(params: ["action": AnyCodable("delete"), "id": AnyCodable(id)])
            // Already gone is fine (the delete test removes its own); anything else is a leak.
            if isError && !out.contains("no contact found") { XCTFail("left a test contact behind (\(id)): \(out)") }
        }
        super.tearDown()
    }

    func testCreateShowsAccountAndRefusesDuplicates() throws {
        let c = try call(["action": "create", "given_name": "\(Self.testName) new", "family_name": marker,
                          "add_phone": "+1 415 555 0177", "label": "mobile", "job_title": "Pilot"])
        let id = try XCTUnwrap(c["id"] as? String)
        created.append(id)
        XCTAssertEqual(c["job_title"] as? String, "Pilot")
        XCTAssertEqual(values(c, "phones"), ["+14155550177"])
        let accounts = try XCTUnwrap(c["accounts"] as? [String])
        XCTAssertFalse(accounts.isEmpty)
        XCTAssertEqual(try call(["action": "read", "id": id])["accounts"] as? [String], accounts)

        for dup: [String: Any] in [
            ["given_name": "\(Self.testName) NEW", "family_name": marker],               // same name, any case
            ["given_name": "\(Self.testName) other", "add_phone": "(415) 555-0177"],     // same phone, other formatting
            ["organization": "\(Self.testName) org", "add_email": "\(marker)@example.com"], // fixture's email
        ] {
            let (out, isError) = tool.handle(params: dup.merging(["action": "create"]) { $1 }.mapValues { AnyCodable($0) })
            XCTAssertTrue(isError && out.contains("already exists"), "expected duplicate refusal for \(dup), got \(out)")
            // A wrongly-accepted create must still be cleaned up.
            if !isError, let o = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], let leaked = o["id"] as? String {
                created.append(leaked)
            }
        }
    }

    func testCreateRefusesUnknownAccountAndEmpty() throws {
        XCTAssertThrowsError(try call(["action": "create", "given_name": "\(Self.testName) \(marker)", "account": "Nope-\(marker)"])) {
            XCTAssertTrue("\($0)".contains("Available:"))
        }
        XCTAssertThrowsError(try call(["action": "create", "job_title": "only a title"]))
    }

    func testDeleteRemovesContactAndReportsMissing() throws {
        let hits = try call(["action": "search", "query": marker])["contacts"] as? [[String: Any]] ?? []
        let id = try XCTUnwrap(hits.first?["id"] as? String)

        let deleted = try call(["action": "delete", "id": id])
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        XCTAssertEqual(deleted["name"] as? String, "\(Self.testName) \(marker)")
        XCTAssertEqual(try call(["action": "search", "query": marker])["count"] as? Int, 0)

        for action in ["delete", "read"] {
            XCTAssertThrowsError(try call(["action": action, "id": id])) {
                XCTAssertTrue($0.localizedDescription.contains("no contact found"), "\($0)")
            }
        }
        XCTAssertThrowsError(try call(["action": "delete"]), "id is required")
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

        let got = try call(["action": "read", "id": fixture.identifier])
        XCTAssertEqual(got["name"] as? String, "\(Self.testName) \(marker)")
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
