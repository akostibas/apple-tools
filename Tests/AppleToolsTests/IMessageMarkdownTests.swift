import XCTest
@testable import AppleToolsLib

final class IMessageMarkdownTests: XCTestCase {

    private func strip(_ s: String) -> String { IMessageMarkdown.toPlainText(s) }

    // MARK: - Inline emphasis

    func testBoldStripsMarkers() {
        XCTAssertEqual(strip("Here's the **plan** for today"), "Here's the plan for today")
        XCTAssertEqual(strip("__also bold__"), "also bold")
    }

    func testItalicStripsMarkers() {
        XCTAssertEqual(strip("for *today* only"), "for today only")
        XCTAssertEqual(strip("for _today_ only"), "for today only")
    }

    func testBoldItalicTriple() {
        XCTAssertEqual(strip("***very*** important"), "very important")
        XCTAssertEqual(strip("___very___ important"), "very important")
    }

    func testStrikethrough() {
        XCTAssertEqual(strip("~~nope~~ yes"), "nope yes")
    }

    func testInlineCode() {
        XCTAssertEqual(strip("run `make dev` now"), "run make dev now")
    }

    func testMixedEmphasisOnOneLine() {
        XCTAssertEqual(strip("**bold** and *italic* and `code`"),
                       "bold and italic and code")
    }

    // MARK: - Headings

    func testHeadingsDropHashes() {
        XCTAssertEqual(strip("# Title"), "Title")
        XCTAssertEqual(strip("### Subhead"), "Subhead")
        XCTAssertEqual(strip("## **Bold heading**"), "Bold heading")
    }

    func testHashWithoutSpaceIsNotHeading() {
        // "#tag" is not an ATX heading — leave it alone.
        XCTAssertEqual(strip("#tag stays"), "#tag stays")
    }

    // MARK: - Lists (structure we keep)

    func testBulletsNormalizeToDot() {
        XCTAssertEqual(strip("- step one\n- step two"), "• step one\n• step two")
        XCTAssertEqual(strip("* star\n+ plus"), "• star\n• plus")
    }

    func testBulletInlineEmphasisStripped() {
        XCTAssertEqual(strip("- do the **thing**"), "• do the thing")
    }

    func testChecklistReducesToText() {
        XCTAssertEqual(strip("- [ ] open\n- [x] done"), "• open\n• done")
    }

    func testNestedBulletIndentPreserved() {
        XCTAssertEqual(strip("- top\n  - nested"), "• top\n  • nested")
    }

    func testNumberedListKept() {
        XCTAssertEqual(strip("1. first\n2. second"), "1. first\n2. second")
    }

    // MARK: - Links

    func testLinkRendersTextAndURL() {
        XCTAssertEqual(strip("see [the docs](https://x.com/d)"),
                       "see the docs (https://x.com/d)")
    }

    func testBareLinkCollapsesToURL() {
        XCTAssertEqual(strip("[https://x.com](https://x.com)"), "https://x.com")
    }

    func testImageRendersURL() {
        XCTAssertEqual(strip("![alt text](https://x.com/i.png)"), "https://x.com/i.png")
    }

    // MARK: - Block elements

    func testBlockquoteDropsMarker() {
        XCTAssertEqual(strip("> quoted line"), "quoted line")
    }

    func testHorizontalRuleDropped() {
        XCTAssertEqual(strip("above\n---\nbelow"), "above\nbelow")
    }

    func testFencedCodeKeptVerbatim() {
        let md = "```swift\nlet x = **notbold**\n```"
        XCTAssertEqual(strip(md), "let x = **notbold**")
    }

    // MARK: - Edge cases

    func testEscapedMarkersSurviveAsLiterals() {
        XCTAssertEqual(strip(#"a \*literal\* star"#), "a *literal* star")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(strip("just a normal sentence."), "just a normal sentence.")
    }

    func testBlankLinesPreserved() {
        XCTAssertEqual(strip("one\n\ntwo"), "one\n\ntwo")
    }

    // MARK: - Regression guards (no over-stripping)

    func testSnakeCaseUnderscoresPreserved() {
        XCTAssertEqual(strip("call user_id and order_total"),
                       "call user_id and order_total")
    }

    func testUnderscoresInBareURLPreserved() {
        XCTAssertEqual(strip("see https://x.com/a_b_c/d_e"),
                       "see https://x.com/a_b_c/d_e")
    }

    func testUnderscoresInLinkURLPreserved() {
        XCTAssertEqual(strip("see [docs](https://x.com/a_b_c)"),
                       "see docs (https://x.com/a_b_c)")
    }

    func testUnderscoresInImageURLPreserved() {
        XCTAssertEqual(strip("![x](https://x.com/a_b_c.png)"),
                       "https://x.com/a_b_c.png")
    }

    func testSpacePaddedAsterisksNotEmphasis() {
        XCTAssertEqual(strip("2 * 3 * 4 = 24"), "2 * 3 * 4 = 24")
    }

    func testUnderscoreEmphasisAtWordEdgesStillStrips() {
        XCTAssertEqual(strip("this is _important_ today"),
                       "this is important today")
    }

    func testCodeSpanContentsNotEmphasisStripped() {
        XCTAssertEqual(strip("use `a_b_c` and `x*y`"), "use a_b_c and x*y")
    }
}
