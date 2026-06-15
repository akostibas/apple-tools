import XCTest
@testable import AppleToolsLib

final class IMessageFormattingTests: XCTestCase {

    func testRealBlobDecodesToMarkdown() {
        let md = IMessageFormatting.attributedBodyToMarkdown(hex: IMessageTestFixtures.boldItalicBlobHex)
        XCTAssertEqual(md, IMessageTestFixtures.boldItalicMarkdown)
    }

    func testGarbageBlobReturnsNil() {
        // A non-typedstream blob must decode to nil (caller falls back to the
        // plain decoder) — never crash.
        XCTAssertNil(IMessageFormatting.attributedBodyToMarkdown(hex: "deadbeef"))
        XCTAssertNil(IMessageFormatting.attributedBodyToMarkdown(hex: ""))
        XCTAssertNil(IMessageFormatting.attributedBodyToMarkdown(hex: "zznothex"))
    }

    // MARK: - bodyText: shared decode policy for all chat.db readers

    func testBodyTextRecoversFormatting() {
        // A formatted message must come back as Markdown, not stripped.
        XCTAssertEqual(IMessageFormatting.bodyText(hex: IMessageTestFixtures.boldItalicBlobHex),
                       IMessageTestFixtures.boldItalicMarkdown)
    }

    func testBodyTextReturnsNilForGarbage() {
        // Both decoders fail -> nil so callers fall back to the empty string.
        XCTAssertNil(IMessageFormatting.bodyText(hex: "deadbeef"))
        XCTAssertNil(IMessageFormatting.bodyText(hex: ""))
    }

    // MARK: - Run -> Markdown emission (synthetic NSAttributedString)

    private func attr(_ pieces: [(String, [String])]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, keys) in pieces {
            var attrs: [NSAttributedString.Key: Any] = [:]
            for k in keys { attrs[NSAttributedString.Key(rawValue: k)] = NSNumber(value: 1) }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    func testPlainRunsReturnNil() {
        // No formatting anywhere -> nil so the caller keeps the plain path.
        let a = attr([("just plain text", ["__kIMMessagePartAttributeName"])])
        XCTAssertNil(IMessageFormatting.runsToMarkdown(a))
    }

    func testWhitespaceKeptOutsideMarkers() {
        let a = attr([
            ("see ", []),
            ("bold word", ["__kIMTextBoldAttributeName"]),
            (" after", []),
        ])
        XCTAssertEqual(IMessageFormatting.runsToMarkdown(a), "see **bold word** after")
    }

    func testStrikethrough() {
        let a = attr([("gone", ["__kIMTextStrikethroughAttributeName"])])
        XCTAssertEqual(IMessageFormatting.runsToMarkdown(a), "~~gone~~")
    }

    func testAttachmentPlaceholderRunDropped() {
        let a = attr([
            ("\u{FFFC}", ["__kIMFileTransferGUIDAttributeName"]),
            ("caption", ["__kIMTextBoldAttributeName"]),
        ])
        XCTAssertEqual(IMessageFormatting.runsToMarkdown(a), "**caption**")
    }
}
