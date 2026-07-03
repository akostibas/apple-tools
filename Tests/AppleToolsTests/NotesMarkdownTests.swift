import XCTest
@testable import AppleToolsLib

final class NotesMarkdownTests: XCTestCase {

    // MARK: - Markdown -> HTML (write)

    func testWriteHeadings() {
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("# Big"), "<div><h1>Big</h1></div>")
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("## Med"), "<div><h2>Med</h2></div>")
    }

    func testWriteInlineEmphasis() {
        XCTAssertEqual(NotesMarkdown.inlineToHTML("a **b** c"), "a <b>b</b> c")
        XCTAssertEqual(NotesMarkdown.inlineToHTML("a *b* c"), "a <i>b</i> c")
        XCTAssertEqual(NotesMarkdown.inlineToHTML("a ~~b~~ c"), "a <strike>b</strike> c")
        XCTAssertEqual(NotesMarkdown.inlineToHTML("a `b` c"), "a <tt>b</tt> c")
    }

    func testWriteBoldBeforeItalic() {
        XCTAssertEqual(NotesMarkdown.inlineToHTML("**bold**"), "<b>bold</b>")
    }

    func testWriteCodeSpanContentsNotReinterpreted() {
        // `__init__` must stay literal inside the code span — the underscores
        // must not be read as bold (issue #37).
        XCTAssertEqual(NotesMarkdown.inlineToHTML("`__init__`"), "<tt>__init__</tt>")
        // Emphasis outside the span still applies; the span is untouched.
        XCTAssertEqual(NotesMarkdown.inlineToHTML("**b** `*x*` *i*"),
                       "<b>b</b> <tt>*x*</tt> <i>i</i>")
    }

    func testWriteLinksDegradeToText() {
        // Notes strips href, so the URL is preserved as plain text.
        XCTAssertEqual(NotesMarkdown.inlineToHTML("see [here](https://x.com)"),
                       "see here (https://x.com)")
    }

    func testWriteBulletList() {
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("- one\n- two"),
                       "<ul><li>one</li><li>two</li></ul>")
    }

    func testWriteNumberedList() {
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("1. one\n2. two"),
                       "<ol><li>one</li><li>two</li></ol>")
    }

    func testWriteChecklistBecomesPlainBullet() {
        // Notes can't store real checkboxes; markers are dropped to text.
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("- [ ] todo\n- [x] done"),
                       "<ul><li>todo</li><li>done</li></ul>")
    }

    func testWriteEscapesHTML() {
        XCTAssertEqual(NotesMarkdown.inlineToHTML("a < b & c"), "a &lt; b &amp; c")
    }

    func testWriteEmptyVsWhitespaceLine() {
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("a\n\nb"),
                       "<div>a</div><div><br></div><div>b</div>")
        // A whitespace-only line is preserved verbatim (escaping-corpus invariant).
        XCTAssertEqual(NotesMarkdown.markdownToNotesHTML("a\n \nb"),
                       "<div>a</div><div> </div><div>b</div>")
    }

    // MARK: - HTML -> Markdown (read)

    func testReadHeadingSpanForm() {
        // Notes normalizes <h1> to bold + a 24px span; we must read it back.
        let html = #"<div><b><span style="font-size: 24px">Big</span></b></div><div>body</div>"#
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "# Big\nbody")
    }

    func testReadHeadingTagForm() {
        let html = "<div><h1>Title</h1></div><div>body</div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "# Title\nbody")
    }

    func testReadInlineEmphasis() {
        let html = "<div><b>bold</b> <i>italic</i> <strike>strike</strike></div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "**bold** *italic* ~~strike~~")
    }

    func testReadBulletList() {
        let html = "<ul>\n<li>one</li>\n<li>two</li>\n</ul>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "- one\n- two")
    }

    func testReadNumberedList() {
        let html = "<ol>\n<li>one</li>\n<li>two</li>\n</ol>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "1. one\n2. two")
    }

    func testReadStripsLeadingTitle() {
        let html = "<div><h1>My Note</h1></div><div>content</div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html, title: "My Note"), "content")
    }

    func testReadDecodesEntities() {
        let html = "<div>a &lt; b &amp; c</div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "a < b & c")
    }

    func testReadDoesNotDoubleDecodeEntities() {
        // Visible text `&lt;` is stored doubly-escaped as `&amp;lt;`. Decoding
        // `&amp;` last (never first) keeps it as `&lt;`, not `<` (issue #29).
        let html = "<div>&amp;lt;script&amp;gt;</div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "&lt;script&gt;")
    }

    func testReadChecklistOverlay() {
        // AppleScript gives plain bullets; overlay marks state by text match.
        let html = "<ul>\n<li>One</li>\n<li>Two</li>\n<li>Three</li>\n</ul>"
        let checklist = [("One", false), ("Two", true), ("Three", false)]
            .map { (text: $0.0, done: $0.1) }
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html, checklist: checklist),
                       "- [ ] One\n- [x] Two\n- [ ] Three")
    }

    func testReadMonospacedFontForm() {
        // Notes stores monospaced as a Courier font wrapper, not <tt>.
        let mid = #"<div>and <font face="Courier"><span style="font-size: 12px">mono</span></font> ok</div>"#
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(mid), "and `mono` ok")
        // tt-only form (whole-line monospaced) carries both font and <tt>;
        // must not double the backticks.
        let solo = #"<div><font face="Courier"><tt>mono</tt></font></div>"#
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(solo), "`mono`")
    }

    func testReadLink() {
        let html = #"<div>see <a href="https://x.com">here</a></div>"#
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "see here (https://x.com)")
    }

    func testReadLinkUnquotedHrefPreservesCase() {
        // Real Notes form: unquoted href, case-sensitive path/query must survive.
        let html = "<div><a href=https://x.com/Path?Q=AbC>label</a></div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "label (https://x.com/Path?Q=AbC)")
    }

    func testReadBareLinkNotDuplicated() {
        // When the anchor text already is the URL, don't render "URL (URL)".
        let html = "<div><a href=https://x.com/p>https://x.com/p</a></div>"
        XCTAssertEqual(NotesMarkdown.notesHTMLToMarkdown(html), "https://x.com/p")
    }

    // MARK: - Link overlay (protobuf URL recovery)

    func testOverlayLinkWrapsDisplayText() {
        let md = "Visit Lawrence Hall of Science today."
        let out = NotesMarkdown.overlayLinks(md, links: [("Lawrence Hall of Science", "https://lhs.org/")])
        XCTAssertEqual(out, "Visit [Lawrence Hall of Science](https://lhs.org/) today.")
    }

    func testOverlayBareLinkLeftAsURL() {
        // text == url: already visible as the URL; don't make [url](url).
        let md = "See https://x.com/p for details"
        let out = NotesMarkdown.overlayLinks(md, links: [("https://x.com/p", "https://x.com/p")])
        XCTAssertEqual(out, "See https://x.com/p for details")
    }

    func testOverlaySkipsAlreadyLinked() {
        // In-body href already produced [text](url); don't double-wrap.
        let md = "Open [here](https://x.com/a)"
        let out = NotesMarkdown.overlayLinks(md, links: [("here", "https://x.com/a")])
        XCTAssertEqual(out, "Open [here](https://x.com/a)")
    }

    func testOverlayRepeatedTextMapsInOrder() {
        // "here" appears twice; forward cursor binds each to the right URL.
        let md = "Click here and also here."
        let out = NotesMarkdown.overlayLinks(md, links: [
            ("here", "https://x.com/1"),
            ("here", "https://x.com/2"),
        ])
        XCTAssertEqual(out, "Click [here](https://x.com/1) and also [here](https://x.com/2).")
    }

    func testOverlayMissingTextSkipped() {
        let md = "no match here"
        let out = NotesMarkdown.overlayLinks(md, links: [("absent", "https://x.com")])
        XCTAssertEqual(out, "no match here")
    }

    func testOverlaySameURLDifferentDisplayTextBothLinked() {
        // Two spans share a URL but have different display text. A global
        // "already linked" guard would skip the second once the first wrapped
        // it; the cursor-scoped guard links both (issue #37).
        let md = "See docs and also guide."
        let out = NotesMarkdown.overlayLinks(md, links: [
            ("docs", "https://x.com/d"),
            ("guide", "https://x.com/d"),
        ])
        XCTAssertEqual(out, "See [docs](https://x.com/d) and also [guide](https://x.com/d).")
    }

    // MARK: - Round-trip (pure, no Notes)

    func testRoundTripFormatting() {
        let md = "# Title\n\nSome **bold** and *italic*.\n\n- one\n- two"
        let html = NotesMarkdown.markdownToNotesHTML(md)
        let back = NotesMarkdown.notesHTMLToMarkdown(html)
        XCTAssertEqual(back, md)
    }

    // MARK: - composeBodyWithTitle (create path — single title line)

    func testComposePrependsTitleWhenBodyHasNoTitle() {
        let out = NotesIntegration.composeBodyWithTitle(title: "My Note", body: "Body line one.")
        XCTAssertEqual(out, "# My Note\n\nBody line one.")
    }

    func testComposeDropsDuplicateHeadingTitle() {
        // The LLM naturally leads with the title as an H1; it must not appear twice.
        let body = "# My Note\n\nBody line one."
        let out = NotesIntegration.composeBodyWithTitle(title: "My Note", body: body)
        XCTAssertEqual(out, "# My Note\n\nBody line one.")
    }

    func testComposeDropsDuplicatePlainTitle() {
        // A leading plain (non-heading) line repeating the title is also dropped.
        let body = "My Note\n\nBody line one."
        let out = NotesIntegration.composeBodyWithTitle(title: "My Note", body: body)
        XCTAssertEqual(out, "# My Note\n\nBody line one.")
    }

    func testComposeKeepsDistinctLeadingHeading() {
        let body = "# Section One\n\nBody."
        let out = NotesIntegration.composeBodyWithTitle(title: "My Note", body: body)
        XCTAssertEqual(out, "# My Note\n\n# Section One\n\nBody.")
    }

    func testComposeEmptyBodyIsTitleOnly() {
        let out = NotesIntegration.composeBodyWithTitle(title: "My Note", body: "")
        XCTAssertEqual(out, "# My Note")
    }
}
