import Contacts
import XCTest
@testable import AppleToolsLib

/// Pure-logic coverage for the batched number→name resolution helpers (#8).
/// The live CNContactStore enumeration is not exercised here (it needs the
/// real address book + permission); these tests pin the country-code-tolerant
/// phone key and the display-name preference order.
final class ContactsIntegrationTests: XCTestCase {

    func testPhoneKeyDropsCountryCodeForLongNumbers() {
        // E.164 (+1) and a 10-digit national number collapse to the same key.
        XCTAssertEqual(
            ContactsIntegration.phoneKey("15551234567"),
            ContactsIntegration.phoneKey("5551234567")
        )
        XCTAssertEqual(ContactsIntegration.phoneKey("15551234567"), "5551234567")
    }

    func testPhoneKeyKeepsShortCodesWhole() {
        // Short codes (< 11 digits) are matched exactly, not suffix-trimmed.
        XCTAssertEqual(ContactsIntegration.phoneKey("262966"), "262966")
    }

    func testResolvedNamePrefersFullName() {
        let c = CNMutableContact()
        c.givenName = "Jane"
        c.familyName = "Doe"
        c.nickname = "JD"
        c.organizationName = "Acme"
        XCTAssertEqual(ContactsIntegration.resolvedName(for: c), "Jane Doe")
    }

    func testResolvedNameFallsBackToNicknameThenOrg() {
        let nick = CNMutableContact()
        nick.nickname = "Shadow"
        XCTAssertEqual(ContactsIntegration.resolvedName(for: nick), "Shadow")

        let org = CNMutableContact()
        org.organizationName = "Acme Corp"
        XCTAssertEqual(ContactsIntegration.resolvedName(for: org), "Acme Corp")
    }

    func testResolveNamesEmptyInputShortCircuits() {
        // Empty / whitespace-only input must not touch Contacts (returns empty).
        XCTAssertTrue(ContactsIntegration.resolveNames(forIdentifiers: []).isEmpty)
        XCTAssertTrue(ContactsIntegration.resolveNames(forIdentifiers: ["", "  "]).isEmpty)
    }
}
