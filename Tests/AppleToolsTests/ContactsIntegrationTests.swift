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

    // MARK: - Multi-token name intersection (#46)

    func testIntersectAllKeepsOnlyCommonEntries() {
        // "Mike" matched {mike-smith, michael-walter}; "Walter" matched
        // {bill-walters, michael-walter} → only michael-walter is in both.
        let mike: Set<String> = ["mike-smith", "michael-walter"]
        let walter: Set<String> = ["bill-walters", "michael-walter"]
        XCTAssertEqual(ContactsIntegration.intersectAll([mike, walter]),
                       ["michael-walter"])
    }

    func testIntersectAllDisjointTokensYieldNothing() {
        // "Mike Karen" — two real people, no shared contact → empty (AC #3).
        let mike: Set<String> = ["mike-smith", "michael-walter"]
        let karen: Set<String> = ["karen-jones"]
        XCTAssertTrue(ContactsIntegration.intersectAll([mike, karen]).isEmpty)
    }

    func testIntersectAllEmptyInputIsEmpty() {
        XCTAssertTrue(ContactsIntegration.intersectAll([]).isEmpty)
    }

    func testSearchByNameTokensNeedsAtLeastTwoTokens() {
        // A single-token query is searchByName's job; the intersection pass
        // must decline it (returns [] without touching the store).
        XCTAssertTrue(ContactsIntegration.searchByNameTokens(query: "Mike", keys: []).isEmpty)
        XCTAssertTrue(ContactsIntegration.searchByNameTokens(query: "   ", keys: []).isEmpty)
    }

    // The join key is content-derived, so the *same* person joins across token
    // queries even when Apple hands back different unified identifiers, while
    // different people stay distinct. This is what makes the intersection work
    // where an identifier intersection failed (the "Mike Walter" bug).
    func testIdentityKeyIsStableOnContentNotIdentifier() {
        let viaNickname = CNMutableContact()
        viaNickname.givenName = "Michael"; viaNickname.familyName = "Walter"
        viaNickname.emailAddresses = [CNLabeledValue(label: nil, value: "mike@mikewalter.com")]

        let viaFamilyName = CNMutableContact()
        viaFamilyName.givenName = "Michael"; viaFamilyName.familyName = "Walter"
        viaFamilyName.emailAddresses = [CNLabeledValue(label: nil, value: "MIKE@mikewalter.com")]

        XCTAssertEqual(ContactsIntegration.identityKey(for: viaNickname),
                       ContactsIntegration.identityKey(for: viaFamilyName),
                       "same name + email (case-folded) must yield the same key")

        let other = CNMutableContact()
        other.givenName = "Mike"; other.familyName = "Smith"
        other.emailAddresses = [CNLabeledValue(label: nil, value: "mike@smith.com")]
        XCTAssertNotEqual(ContactsIntegration.identityKey(for: viaNickname),
                          ContactsIntegration.identityKey(for: other))
    }
}
