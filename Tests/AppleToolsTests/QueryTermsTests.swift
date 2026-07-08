import XCTest
@testable import AppleToolsLib

/// Pure-logic coverage for the shared free-text query primitive (#45/#46).
/// Pins the two contracts every consumer relies on: tokenization (lowercase,
/// whitespace split, pluggable stopwords) and AND-of-terms substring matching.
final class QueryTermsTests: XCTestCase {

    // MARK: - tokenize

    func testTokenizeLowercasesAndSplitsOnWhitespace() {
        XCTAssertEqual(QueryTerms.tokenize("Kostibas  Neighbors"), ["kostibas", "neighbors"])
        // Tabs/newlines are whitespace too; empty tokens are dropped.
        XCTAssertEqual(QueryTerms.tokenize("garage\tdoor\ncode"), ["garage", "door", "code"])
    }

    func testTokenizeDropsStopwordsByDefault() {
        // "of"/"the" are in commonStopwords; "plan" survives.
        XCTAssertEqual(QueryTerms.tokenize("the plan of attack"), ["plan", "attack"])
    }

    func testTokenizeWithoutStopwordsKeepsEverything() {
        // Name matching passes stopwords: [] so short tokens survive.
        XCTAssertEqual(QueryTerms.tokenize("Mike Walter", stopwords: []), ["mike", "walter"])
        XCTAssertEqual(QueryTerms.tokenize("the a", stopwords: []), ["the", "a"])
    }

    func testTokenizeEmptyWhenAllStopwordsOrBlank() {
        XCTAssertTrue(QueryTerms.tokenize("the of and").isEmpty)
        XCTAssertTrue(QueryTerms.tokenize("   ").isEmpty)
    }

    // MARK: - allTermsMatch

    func testAllTermsMatchRequiresEveryTermAcrossFields() {
        // Both terms present, split across two fields → match.
        XCTAssertTrue(QueryTerms.allTermsMatch(["kostibas", "neighbor"],
                                               inAnyOf: ["Kostibas dinner", "the neighbors came over"]))
    }

    func testAllTermsMatchFailsWhenOneTermMissing() {
        XCTAssertFalse(QueryTerms.allTermsMatch(["kostibas", "dentist"],
                                                inAnyOf: ["Kostibas dinner", "the neighbors came over"]))
    }

    func testAllTermsMatchEmptyTermsIsNeverAMatch() {
        XCTAssertFalse(QueryTerms.allTermsMatch([], inAnyOf: ["anything at all"]))
    }

    func testAllTermsMatchIsCaseInsensitiveSubstring() {
        // Substring, not word-boundary: "cat" matches inside "category".
        XCTAssertTrue(QueryTerms.allTermsMatch(["cat"], inAnyOf: ["Category theory"]))
        // Case folding on the field side.
        XCTAssertTrue(QueryTerms.allTermsMatch(["neighbor"], inAnyOf: ["NEIGHBORS"]))
    }
}
