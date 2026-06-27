import XCTest
@testable import AppleToolsLib

/// Pins the canonical E.164 phone output shared by Contacts and Messages.
/// Before PhoneFormatting existed, the same number rendered differently per
/// source — Contacts returned the raw `CNContact` string, Messages the raw
/// handle (issue #12). These tests lock the single format and the conservative
/// "leave non-numbers untouched" contract so it can't drift.
final class PhoneFormattingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Pin the region so bare-national expansion is deterministic regardless
        // of the machine the tests run on.
        PhoneFormatting.defaultRegion = "US"
    }

    override func tearDown() {
        // Restore the system default for any other test.
        PhoneFormatting.defaultRegion = Locale.current.region?.identifier ?? "US"
        super.tearDown()
    }

    // MARK: - e164: numbers that should canonicalize

    // Use a real, valid NANP number (650-253-0000). Note: 555-prefixed numbers
    // are fictional/reserved and libphonenumber rejects them — see
    // testFictionalNumberIsRejected.
    func testWellFormedUSNumberToE164() {
        XCTAssertEqual(PhoneFormatting.e164("(650) 253-0000"), "+16502530000")
    }

    func testVariousUSFormatsConvergeToSameE164() {
        for input in ["(650) 253-0000", "650.253.0000", "650-253-0000", "6502530000", "+1 650 253 0000"] {
            XCTAssertEqual(PhoneFormatting.e164(input), "+16502530000", "input: \(input)")
        }
    }

    func testAlreadyE164Unchanged() {
        XCTAssertEqual(PhoneFormatting.e164("+16502530000"), "+16502530000")
    }

    func testFictionalNumberIsRejected() {
        // 555-line numbers are reserved/fictional; hard validation rejects them,
        // so they pass through unchanged rather than becoming a fake E.164.
        XCTAssertNil(PhoneFormatting.e164("(555) 123-4567"))
        XCTAssertEqual(PhoneFormatting.normalized("(555) 123-4567"), "(555) 123-4567")
    }

    func testInternationalNumberWithPlusRespectsItsOwnCountryCode() {
        // A +44 number must NOT be reinterpreted under the US default region.
        XCTAssertEqual(PhoneFormatting.e164("+44 20 7031 3000"), "+442070313000")
    }

    // MARK: - e164: things that are NOT phone numbers → nil (left untouched)

    func testEmailReturnsNil() {
        XCTAssertNil(PhoneFormatting.e164("alice@example.com"))
    }

    func testShortcodeReturnsNil() {
        // 5–6 digit marketing short codes must not be coerced into a fake number.
        XCTAssertNil(PhoneFormatting.e164("262966"))
        XCTAssertNil(PhoneFormatting.e164("88811"))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(PhoneFormatting.e164("not a phone"))
        XCTAssertNil(PhoneFormatting.e164(""))
        XCTAssertNil(PhoneFormatting.e164("   "))
    }

    func testSpamSuffixedHandleIsNormalizedSuffixStripped() {
        // PhoneNumberKit strips trailing junk like the (smsfp) SMS-filter suffix
        // and parses the underlying number. The caller keeps the raw chat_id
        // (suffix included) verbatim and gets this as an additive field.
        XCTAssertEqual(PhoneFormatting.e164("+13092434459(smsfp)"), "+13092434459")
    }

    func testSpamSuffixedFictionalNumberStillRejected() {
        // ...but a suffix can't rescue an otherwise-invalid (fictional 555) number.
        XCTAssertNil(PhoneFormatting.e164("+15551234567(smsfp)"))
    }

    // MARK: - normalized: in-place form passes unparseable through unchanged

    func testNormalizedCanonicalizesValid() {
        XCTAssertEqual(PhoneFormatting.normalized("(650) 253-0000"), "+16502530000")
    }

    func testNormalizedLeavesNonNumberUnchanged() {
        XCTAssertEqual(PhoneFormatting.normalized("262966"), "262966")
        XCTAssertEqual(PhoneFormatting.normalized("alice@example.com"), "alice@example.com")
        XCTAssertEqual(PhoneFormatting.normalized("not a phone"), "not a phone")
    }

    // MARK: - defaultRegion override

    func testDefaultRegionGovernsBareNationalExpansion() {
        // The same bare national digits expand to different countries by region.
        PhoneFormatting.defaultRegion = "GB"
        // A UK national number (020 7031 3000) under region GB → +44…
        XCTAssertEqual(PhoneFormatting.e164("020 7031 3000"), "+442070313000")
    }
}
