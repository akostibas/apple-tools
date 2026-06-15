import XCTest
@testable import AppleToolsLib

final class EmailMessageTests: XCTestCase {

    // MARK: - RFC 2047 encoded-word decoding

    func testRFC2047DecodeBase64() {
        // "Hello, World!" in UTF-8 base64
        let input = "=?UTF-8?B?SGVsbG8sIFdvcmxkIQ==?="
        XCTAssertEqual(EmailMessage.decodeRFC2047(input), "Hello, World!")
    }

    func testRFC2047DecodeQ() {
        // "Olá" via Q-encoding (UTF-8)
        let input = "=?UTF-8?Q?Ol=C3=A1?="
        XCTAssertEqual(EmailMessage.decodeRFC2047(input), "Olá")
    }

    func testRFC2047QDecodesUnderscoreAsSpace() {
        // "Hi There" encoded as Hi_There — underscores in Q mean space.
        let input = "=?UTF-8?Q?Hi_There?="
        XCTAssertEqual(EmailMessage.decodeRFC2047(input), "Hi There")
    }

    func testRFC2047PassesThroughNonEncodedText() {
        XCTAssertEqual(EmailMessage.decodeRFC2047("Plain subject"), "Plain subject")
    }

    func testRFC2047MixedEncodedAndPlain() {
        // Real-world shape: encoded-word followed by plain text.
        let input = "=?UTF-8?B?SGVsbG8=?= world"
        XCTAssertEqual(EmailMessage.decodeRFC2047(input), "Hello world")
    }

    // MARK: - Quoted-printable

    func testQuotedPrintableBasic() {
        let input = "Caf=C3=A9".data(using: .ascii)!
        let out = EmailMessage.decodeQuotedPrintable(input)
        XCTAssertEqual(String(data: out, encoding: .utf8), "Café")
    }

    func testQuotedPrintableSoftLineBreak() {
        // '=' at end-of-line is a soft break and should be elided.
        let input = "Line one =\nLine two".data(using: .ascii)!
        let out = EmailMessage.decodeQuotedPrintable(input)
        XCTAssertEqual(String(data: out, encoding: .utf8), "Line one Line two")
    }

    // MARK: - Content-Type parsing

    func testContentTypeParsesParamsAndQuotes() {
        let ct = EmailMessage.parseContentType("multipart/alternative; boundary=\"abc123\"; charset=\"UTF-8\"")
        XCTAssertEqual(ct.mime, "multipart/alternative")
        XCTAssertEqual(ct.boundary, "abc123")
        XCTAssertEqual(ct.charset, "UTF-8")
    }

    func testContentTypeBareValue() {
        let ct = EmailMessage.parseContentType("text/plain")
        XCTAssertEqual(ct.mime, "text/plain")
        XCTAssertNil(ct.boundary)
        XCTAssertNil(ct.charset)
    }

    // MARK: - Header / body split

    func testHeadersBodySplitLF() {
        let data = "Subject: hi\n\nbody here".data(using: .utf8)!
        let (headers, body) = EmailMessage.splitHeadersAndBody(data)
        XCTAssertTrue(headers.contains("Subject: hi"))
        XCTAssertEqual(String(data: body, encoding: .utf8), "body here")
    }

    func testHeadersBodySplitCRLF() {
        let data = "Subject: hi\r\n\r\nbody here".data(using: .utf8)!
        let (headers, body) = EmailMessage.splitHeadersAndBody(data)
        XCTAssertTrue(headers.contains("Subject: hi"))
        XCTAssertEqual(String(data: body, encoding: .utf8), "body here")
    }

    // MARK: - End-to-end parseRFC822

    func testSinglePartPlainText() throws {
        let raw = """
        From: Alice <alice@example.com>
        To: Bob <bob@example.com>
        Subject: Hello
        Date: Mon, 1 Jan 2026 12:00:00 +0000
        Content-Type: text/plain; charset=UTF-8

        Hi Bob, how are you?
        """
        let parsed = try EmailMessage.parseRFC822(raw.data(using: .utf8)!)
        XCTAssertEqual(parsed.subject, "Hello")
        XCTAssertEqual(parsed.from, "Alice <alice@example.com>")
        XCTAssertEqual(parsed.to, "Bob <bob@example.com>")
        XCTAssertTrue(parsed.body.contains("Hi Bob"))
        XCTAssertFalse(parsed.bodyIsHTMLOnly)
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testBase64Body() throws {
        // Body "Secret\n" → "U2VjcmV0Cg==" in base64.
        let raw = """
        Subject: Enc
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: base64

        U2VjcmV0Cg==
        """
        let parsed = try EmailMessage.parseRFC822(raw.data(using: .utf8)!)
        XCTAssertTrue(parsed.body.contains("Secret"),
                      "expected decoded base64 body, got: \(parsed.body)")
    }

    func testMultipartAlternativePrefersPlain() throws {
        let raw = """
        Subject: Mixed
        Content-Type: multipart/alternative; boundary="BOUNDARY"

        --BOUNDARY
        Content-Type: text/plain; charset=UTF-8

        PLAIN BODY
        --BOUNDARY
        Content-Type: text/html; charset=UTF-8

        <p>HTML BODY</p>
        --BOUNDARY--
        """
        let parsed = try EmailMessage.parseRFC822(raw.data(using: .utf8)!)
        XCTAssertTrue(parsed.body.contains("PLAIN BODY"))
        XCTAssertFalse(parsed.body.contains("HTML BODY"))
        XCTAssertFalse(parsed.bodyIsHTMLOnly)
    }

    func testHTMLOnlyFallbackStripsTags() throws {
        let raw = """
        Subject: HTML only
        Content-Type: text/html; charset=UTF-8

        <p>Hello <b>world</b></p>
        """
        let parsed = try EmailMessage.parseRFC822(raw.data(using: .utf8)!)
        XCTAssertTrue(parsed.bodyIsHTMLOnly)
        XCTAssertTrue(parsed.body.contains("Hello"))
        XCTAssertFalse(parsed.body.contains("<p>"))
    }

    func testEncodedSubjectIsDecoded() throws {
        let raw = """
        Subject: =?UTF-8?B?SGVsbG8sIFdvcmxkIQ==?=
        Content-Type: text/plain

        body
        """
        let parsed = try EmailMessage.parseRFC822(raw.data(using: .utf8)!)
        XCTAssertEqual(parsed.subject, "Hello, World!")
    }

    func testAttachmentIsEnumeratedAndNotInBody() throws {
        let raw = """
        Subject: With attach
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        --B
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        SGVsbG8=
        --B--
        """
        let parsed = try EmailMessage.parseRFC822(raw.data(using: .utf8)!)
        XCTAssertTrue(parsed.body.contains("see attached"))
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(parsed.attachments.first?.mimeType, "application/pdf")
    }

    // MARK: - loadAttachment

    /// Write an RFC 822 blob into a temp `.emlx` file (byte-count header + body).
    /// Returns the path. The caller is responsible for cleanup; tests use XCTest's
    /// default temp dir which the harness cleans up between runs.
    private func writeEmlx(rfc822: String, file: StaticString = #file, line: UInt = #line) throws -> String {
        let body = rfc822.data(using: .utf8)!
        var emlx = Data()
        emlx.append("\(body.count)\n".data(using: .ascii)!)
        emlx.append(body)
        let path = NSTemporaryDirectory() + "apple-tools-emlx-test-\(UUID().uuidString).emlx"
        try emlx.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testLoadAttachmentSinglePicksIt() throws {
        // "hello" base64-encoded = "aGVsbG8=".
        let raw = """
        Subject: With one
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        --B
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        aGVsbG8=
        --B--
        """
        let path = try writeEmlx(rfc822: raw)
        let att = try EmailMessage.loadAttachment(atPath: path, filename: nil)
        XCTAssertEqual(att.filename, "report.pdf")
        XCTAssertEqual(att.mimeType, "application/pdf")
        XCTAssertEqual(String(data: att.data, encoding: .utf8), "hello")
    }

    func testLoadAttachmentSelectsByFilename() throws {
        // Two attachments with distinct base64 payloads. "A" → "QQ==", "B" → "Qg==".
        let raw = """
        Subject: Two atts
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        body
        --B
        Content-Type: application/octet-stream; name="a.bin"
        Content-Disposition: attachment; filename="a.bin"
        Content-Transfer-Encoding: base64

        QQ==
        --B
        Content-Type: application/octet-stream; name="b.bin"
        Content-Disposition: attachment; filename="b.bin"
        Content-Transfer-Encoding: base64

        Qg==
        --B--
        """
        let path = try writeEmlx(rfc822: raw)

        let a = try EmailMessage.loadAttachment(atPath: path, filename: "a.bin")
        XCTAssertEqual(String(data: a.data, encoding: .utf8), "A")

        let b = try EmailMessage.loadAttachment(atPath: path, filename: "b.bin")
        XCTAssertEqual(String(data: b.data, encoding: .utf8), "B")
    }

    func testLoadAttachmentAmbiguousWhenMultipleAndNoFilename() throws {
        let raw = """
        Subject: Two atts
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: application/octet-stream; name="a.bin"
        Content-Disposition: attachment; filename="a.bin"

        hello
        --B
        Content-Type: application/octet-stream; name="b.bin"
        Content-Disposition: attachment; filename="b.bin"

        world
        --B--
        """
        let path = try writeEmlx(rfc822: raw)
        XCTAssertThrowsError(try EmailMessage.loadAttachment(atPath: path, filename: nil)) { err in
            guard let e = err as? EmailMessage.LoadError else {
                return XCTFail("expected LoadError, got \(err)")
            }
            if case .ambiguous(let candidates) = e {
                XCTAssertEqual(Set(candidates), Set(["a.bin", "b.bin"]))
                return
            }
            XCTFail("expected .ambiguous, got \(e)")
        }
    }

    func testLoadAttachmentNotFoundWithCandidates() throws {
        let raw = """
        Subject: One att
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: application/pdf; name="real.pdf"
        Content-Disposition: attachment; filename="real.pdf"

        pdfbytes
        --B--
        """
        let path = try writeEmlx(rfc822: raw)
        XCTAssertThrowsError(try EmailMessage.loadAttachment(atPath: path, filename: "nope.pdf")) { err in
            guard let e = err as? EmailMessage.LoadError else {
                return XCTFail("expected LoadError, got \(err)")
            }
            if case .notFound(let candidates) = e {
                XCTAssertEqual(candidates, ["real.pdf"])
                return
            }
            XCTFail("expected .notFound, got \(e)")
        }
    }

    func testLoadAttachmentNoAttachments() throws {
        let raw = """
        Subject: Plain text
        Content-Type: text/plain; charset=UTF-8

        just a body
        """
        let path = try writeEmlx(rfc822: raw)
        XCTAssertThrowsError(try EmailMessage.loadAttachment(atPath: path, filename: nil)) { err in
            guard let e = err as? EmailMessage.LoadError else {
                return XCTFail("expected LoadError, got \(err)")
            }
            if case .noAttachments = e { return }
            XCTFail("expected .noAttachments, got \(e)")
        }
    }

    func testLoadAttachmentReturnsEmptyDataForIMAPStub() throws {
        // IMAP-synced .emlx files may have the MIME structure for an
        // attachment but an empty body (Mail fetches the data on demand).
        // loadAttachment should still succeed — the caller checks for
        // empty data and looks in the on-disk Attachments/ directory.
        let raw = """
        Subject: PDF stub
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        --B
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"
        Content-Transfer-Encoding: base64

        --B--
        """
        let path = try writeEmlx(rfc822: raw)
        let att = try EmailMessage.loadAttachment(atPath: path, filename: nil)
        XCTAssertEqual(att.filename, "invoice.pdf")
        XCTAssertEqual(att.mimeType, "application/pdf")
        XCTAssertTrue(att.data.isEmpty,
                      "IMAP stub should produce empty attachment data, got \(att.data.count) bytes")
    }

    // MARK: - On-disk attachment lookup

    func testLoadAttachmentFromDiskFindsFile() throws {
        // Simulate Mail's on-disk layout:
        //   …/Data/0/Messages/1000.emlx
        //   …/Data/0/Attachments/1000/2/report.pdf
        let base = NSTemporaryDirectory() + "apple-tools-att-test-\(UUID().uuidString)"
        let messagesDir = "\(base)/Data/0/Messages"
        let attachmentsDir = "\(base)/Data/0/Attachments/1000/2"
        let fm = FileManager.default
        try fm.createDirectory(atPath: messagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: attachmentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }

        // Write a dummy .emlx and attachment file.
        let emlxPath = "\(messagesDir)/1000.emlx"
        try Data("dummy".utf8).write(to: URL(fileURLWithPath: emlxPath))
        let pdfData = Data("fake-pdf-content".utf8)
        try pdfData.write(to: URL(fileURLWithPath: "\(attachmentsDir)/report.pdf"))

        let result = EmailMessage.loadAttachmentFromDisk(
            emlxPath: emlxPath, rowID: 1000, filename: "report.pdf"
        )
        XCTAssertEqual(result, pdfData)
    }

    func testLoadAttachmentFromDiskReturnsNilWhenMissing() throws {
        let base = NSTemporaryDirectory() + "apple-tools-att-test-\(UUID().uuidString)"
        let messagesDir = "\(base)/Data/0/Messages"
        let fm = FileManager.default
        try fm.createDirectory(atPath: messagesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }

        let emlxPath = "\(messagesDir)/1000.emlx"
        try Data("dummy".utf8).write(to: URL(fileURLWithPath: emlxPath))

        // No Attachments/ directory at all.
        let result = EmailMessage.loadAttachmentFromDisk(
            emlxPath: emlxPath, rowID: 1000, filename: "report.pdf"
        )
        XCTAssertNil(result)
    }

    func testLoadAttachmentFromDiskReturnsNilForWrongFilename() throws {
        let base = NSTemporaryDirectory() + "apple-tools-att-test-\(UUID().uuidString)"
        let messagesDir = "\(base)/Data/0/Messages"
        let attachmentsDir = "\(base)/Data/0/Attachments/1000/2"
        let fm = FileManager.default
        try fm.createDirectory(atPath: messagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: attachmentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }

        let emlxPath = "\(messagesDir)/1000.emlx"
        try Data("dummy".utf8).write(to: URL(fileURLWithPath: emlxPath))
        try Data("content".utf8).write(to: URL(fileURLWithPath: "\(attachmentsDir)/other.pdf"))

        let result = EmailMessage.loadAttachmentFromDisk(
            emlxPath: emlxPath, rowID: 1000, filename: "report.pdf"
        )
        XCTAssertNil(result)
    }

    // MARK: - .emlx path derivation (computed, not filesystem-dependent)

    func testEmlxPathReturnsNilForLocalScheme() {
        // Local mailboxes aren't wired up yet — should return nil so the
        // caller falls back to AppleScript.
        let path = EmailMessage.emlxPath(rowID: 42, mailboxURL: "local://On%20My%20Mac/Sent")
        XCTAssertNil(path)
    }

    func testEmlxPathReturnsNilForMalformedURL() {
        XCTAssertNil(EmailMessage.emlxPath(rowID: 42, mailboxURL: ""))
        XCTAssertNil(EmailMessage.emlxPath(rowID: 42, mailboxURL: "not a url"))
    }
}
