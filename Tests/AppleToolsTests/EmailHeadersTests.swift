import XCTest
@testable import AppleToolsLib

final class EmailHeadersTests: XCTestCase {
    private var savedRunner: (
        (String, [String: String], (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?)
    )!
    private var savedMailRunning: (() -> Bool)!

    override func setUp() {
        super.setUp()
        savedRunner = EmailIntegration.runAppleScript
        savedMailRunning = EmailIntegration.isMailRunning
        EmailIntegration.isMailRunning = { true }
    }

    override func tearDown() {
        EmailIntegration.runAppleScript = savedRunner
        EmailIntegration.isMailRunning = savedMailRunning
        super.tearDown()
    }

    func testGroupsUnfoldsAndKeepsRepeats() {
        let raw = """
        Received: from a
        Received: from b
        DKIM-Signature: v=1; a=rsa-sha256;
        \tb=abc
        Sender: Google Calendar <calendar-notification@google.com>
        Subject: =?UTF-8?Q?Ol=C3=A1?=
        """
        let h = EmailMessage.groupHeaders(raw)
        XCTAssertEqual(h["received"], ["from a", "from b"])
        XCTAssertEqual(h["dkim-signature"], ["v=1; a=rsa-sha256; b=abc"])
        XCTAssertEqual(h["sender"], ["Google Calendar <calendar-notification@google.com>"])
        XCTAssertEqual(h["subject"], ["Olá"])
    }

    func testLoadsHeadersFromPartialEmlxWithoutBody() throws {
        let msg = "X-Google-Calendar-Notification: eventCreated\nSubject: hi\n"
        let path = NSTemporaryDirectory() + UUID().uuidString + ".partial.emlx"
        try "\(msg.utf8.count)\n\(msg)".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let h = try EmailMessage.loadHeaders(atPath: path)
        XCTAssertEqual(h["x-google-calendar-notification"], ["eventCreated"])
    }

    func testAppleScriptFallbackAsksForHeadersNotContent() throws {
        var seen = ""
        EmailIntegration.runAppleScript = { script, _, _ in
            seen = script
            return ("OKSender: x\rX-Foo: y\r", nil)
        }
        let raw = try EmailIntegration.headersViaAppleScript(rowID: 42, mailboxURL: "imap://A/Archive")
        XCTAssertTrue(seen.contains("all headers of theMsg"))
        // Reading content would download the body — the cost this action exists to avoid.
        XCTAssertFalse(seen.contains("content of"))
        XCTAssertEqual(EmailMessage.groupHeaders(raw)["x-foo"], ["y"])
    }

    func testHeadersRequiresID() {
        let (result, isError) = EmailTool(host: .test()).handle(params: ["action": AnyCodable("headers")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }
}
