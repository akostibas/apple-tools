import XCTest
@testable import AppleToolsLib

/// Mail indexes a message on arrival but only writes the `.emlx` when
/// something reads it, so mail filed without ever being opened is in every
/// search and absent from disk. These cover the repair: ask Mail for the body,
/// addressed inside its own mailbox rather than over INBOX.
final class EmailDownloadBodyTests: XCTestCase {
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

    // MARK: - Mailbox addressing

    func testParsesNestedGmailMailbox() {
        let loc = EmailIntegration.accountAndMailbox(
            fromMailboxURL: "imap://ABC-UUID/%5BGmail%5D/All%20Mail")
        XCTAssertEqual(loc?.account, "ABC-UUID")
        // Mail names nested mailboxes with slashes, so the decoded path is
        // already the AppleScript name — no lookup table.
        XCTAssertEqual(loc?.mailbox, "[Gmail]/All Mail")
    }

    func testParsesTopLevelMailbox() {
        let loc = EmailIntegration.accountAndMailbox(fromMailboxURL: "imap://ABC-UUID/Archive")
        XCTAssertEqual(loc?.account, "ABC-UUID")
        XCTAssertEqual(loc?.mailbox, "Archive")
    }

    func testRejectsNonIMAPMailbox() {
        XCTAssertNil(EmailIntegration.accountAndMailbox(fromMailboxURL: "local://Notes"))
    }

    // MARK: - Never launches Mail

    func testRefusesWhenMailIsNotRunning() {
        EmailIntegration.isMailRunning = { false }
        var ran = false
        EmailIntegration.runAppleScript = { _, _, _ in ran = true; return ("OK", nil) }

        XCTAssertThrowsError(
            try EmailIntegration.downloadMessageBody(rowID: 199_489,
                                                     mailboxURL: "imap://ABC-UUID/Archive")
        ) { error in
            guard case EmailIntegration.EmailError.mailNotRunning = error else {
                return XCTFail("expected mailNotRunning, got \(error)")
            }
        }
        // The point of the guard: a background run must not put Mail on screen.
        XCTAssertFalse(ran, "must not drive Mail when Mail is not already running")
    }

    // MARK: - Addressing the message

    func testAddressesTheRowInsideItsOwnMailbox() throws {
        var seenScript = ""
        var seenEnv: [String: String] = [:]
        EmailIntegration.runAppleScript = { script, env, _ in
            seenScript = script
            seenEnv = env
            return ("OK", nil)
        }

        try EmailIntegration.downloadMessageBody(rowID: 199_489,
                                                 mailboxURL: "imap://ABC-UUID/Archive")

        XCTAssertEqual(seenEnv["APPLE_TOOLS_MAIL_ACCOUNT"], "ABC-UUID")
        XCTAssertEqual(seenEnv["APPLE_TOOLS_MAIL_MAILBOX"], "Archive")
        XCTAssertTrue(seenScript.contains("whose id is 199489"))
        // Reading `content` IS the fetch — Mail has no download verb. If this
        // ever becomes a header-only read, the body never lands on disk.
        XCTAssertTrue(seenScript.contains("get content of"))
        // The INBOX-only scoping is exactly what made archived mail
        // unreachable; the whole point is that this script does not do it.
        XCTAssertFalse(seenScript.contains("\"INBOX\""))
    }

    func testReportsMessageNotFound() {
        EmailIntegration.runAppleScript = { _, _, _ in ("NOT_FOUND", nil) }
        XCTAssertThrowsError(
            try EmailIntegration.downloadMessageBody(rowID: 1, mailboxURL: "imap://A/Archive")
        ) { error in
            guard case EmailIntegration.EmailError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testReportsScriptFailure() {
        EmailIntegration.runAppleScript = { _, _, _ in ("", "Mail got an error: -1728") }
        XCTAssertThrowsError(
            try EmailIntegration.downloadMessageBody(rowID: 1, mailboxURL: "imap://A/Archive")
        ) { error in
            guard case EmailIntegration.EmailError.scriptFailed = error else {
                return XCTFail("expected scriptFailed, got \(error)")
            }
        }
    }
}
