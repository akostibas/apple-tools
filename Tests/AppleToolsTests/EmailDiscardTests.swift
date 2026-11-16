import XCTest
@testable import AppleToolsLib

/// `discard` must be unable to delete real mail: everything that isn't a draft is refused.
final class EmailDiscardTests: XCTestCase {
    private var savedRunner: (
        (String, [String: String], (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?)
    )!
    private var savedMailRunning: (() -> Bool)!
    private let draftsURL = "imap://ABC-UUID/Drafts"

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

    // MARK: - Refusals decided before Mail is asked anything

    func testDiscardRequiresID() {
        let (result, isError) = EmailTool(host: .test()).handle(params: ["action": AnyCodable("discard")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("id"), result)
    }

    func testDiscardIsAWriteAction() {
        guard case .perAction(let map) = EmailTool(host: .test()).accessPolicy else { return XCTFail() }
        XCTAssertEqual(map["discard"], .readWrite)
    }

    func testDraftsMailboxesAreAccepted() {
        XCTAssertNil(EmailTool.discardRefusal(mailboxURL: draftsURL))
        XCTAssertNil(EmailTool.discardRefusal(mailboxURL: "imap://ABC-UUID/%5BGmail%5D/Drafts"))
    }

    func testReceivedAndSentMailIsRefused() {
        for box in ["INBOX", "Sent%20Messages", "%5BGmail%5D/Sent%20Mail", "%5BGmail%5D/All%20Mail",
                    "Archive", "Trash", "Deleted%20Messages", "Junk"] {
            let refusal = EmailTool.discardRefusal(mailboxURL: "imap://ABC-UUID/\(box)")
            XCTAssertEqual(refusal?.hasPrefix("not a draft"), true, "\(box) must be refused: \(refusal ?? "accepted")")
        }
    }

    func testLookalikeMailboxesAreRefused() {
        for box in ["Archive/Drafts", "Drafts/Old", "Drafts%20Backup", "drafts", ""] {
            XCTAssertNotNil(EmailTool.discardRefusal(mailboxURL: "imap://ABC-UUID/\(box)"), "\(box) must be refused")
        }
    }

    func testUntestedAccountTypesAreRefused() {
        for url in ["local://Local/Drafts", "ews://ABC-UUID/Drafts"] {
            let refusal = EmailTool.discardRefusal(mailboxURL: url)
            XCTAssertEqual(refusal?.contains("kind of account"), true, "\(url): \(refusal ?? "accepted")")
        }
    }

    // MARK: - What Mail is asked to do

    func testNeverLaunchesMail() {
        EmailIntegration.isMailRunning = { false }
        var ran = false
        EmailIntegration.runAppleScript = { _, _, _ in ran = true; return ("OK", nil) }
        XCTAssertThrowsError(try EmailIntegration.discardDraft(rowID: 7, mailboxURL: draftsURL)) { error in
            guard case EmailIntegration.EmailError.mailNotRunning = error else {
                return XCTFail("expected mailNotRunning, got \(error)")
            }
        }
        XCTAssertFalse(ran, "must not script Mail when it isn't running")
    }

    func testDeleteRunsOnlyAfterMailConfirmsADraftAndATrash() throws {
        var script = ""
        EmailIntegration.runAppleScript = { source, _, _ in script = source; return ("OK", nil) }
        try EmailIntegration.discardDraft(rowID: 7, mailboxURL: draftsURL)
        let draftCheck = try XCTUnwrap(script.range(of: "every message of drafts mailbox whose id is 7"))
        let trashCheck = try XCTUnwrap(script.range(of: "move deleted messages to trash"))
        let delete = try XCTUnwrap(script.range(of: "delete theMsg"))
        XCTAssertLessThan(draftCheck.lowerBound, delete.lowerBound)
        XCTAssertLessThan(trashCheck.lowerBound, delete.lowerBound)
    }

    func testMailSayingNotADraftIsAnError() {
        for answer in ["NOT_DRAFT", "NO_TRASH", "NOT_FOUND"] {
            EmailIntegration.runAppleScript = { _, _, _ in (answer, nil) }
            XCTAssertThrowsError(try EmailIntegration.discardDraft(rowID: 7, mailboxURL: draftsURL), answer)
        }
    }

    // MARK: - Drafting stays off the screen

    func testDraftIsSavedWithoutAWindow() throws {
        var script = ""
        EmailIntegration.runAppleScript = { source, _, _ in script = source; return ("1", nil) }
        try EmailIntegration.createOutgoingMessage(to: "a@example.com", subject: "s", body: "b", cc: [], attachments: [])
        XCTAssertTrue(script.contains("visible:false"), script)
        XCTAssertFalse(script.contains("visible:true"), script)
        // `save` alone leaves Mail autosaving the message, which resurrects a discarded draft.
        XCTAssertTrue(script.contains("close newMsg saving yes"), script)
        XCTAssertFalse(script.contains("save newMsg"), script)
        XCTAssertFalse(script.contains("activate"), script)

        try EmailIntegration.createOutgoingMessage(to: "a@example.com", subject: "s", body: "b", cc: [],
                                                   attachments: [], htmlBody: "<div>b</div>")
        XCTAssertTrue(script.contains("visible:false"), script)
        XCTAssertFalse(script.contains("visible:true"), script)
    }
}

/// Drafts, then discards, one real message addressed to example.com. Mail must be running:
///
///     APPLE_TOOLS_EMAIL_LIVE=1 xcrun swift test --filter EmailDiscardLiveTests
final class EmailDiscardLiveTests: XCTestCase {
    func testDraftThenDiscard() throws {
        guard ProcessInfo.processInfo.environment["APPLE_TOOLS_EMAIL_LIVE"] == "1" else {
            throw XCTSkip("set APPLE_TOOLS_EMAIL_LIVE=1 to run live email tests")
        }
        guard EmailIntegration.isMailRunning() else { throw XCTSkip("Mail is not running; this test never launches it") }
        let tool = EmailTool(host: .test())
        let subject = "apple-tools live test \(UUID().uuidString)"

        let (drafted, draftFailed) = tool.handle(params: [
            "action": AnyCodable("draft"), "to": AnyCodable("nobody@example.com"),
            "subject": AnyCodable(subject), "body": AnyCodable("Created by a test; safe to delete."),
        ])
        XCTAssertFalse(draftFailed, drafted)
        let id = try XCTUnwrap(json(drafted)["id"] as? String, "draft returned no id: \(drafted)")

        // Clean up even if an assertion below fails.
        var discarded = false
        defer { if !discarded { _ = tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)]) } }

        let (windows, err) = EmailIntegration.runAppleScript(
            "tell application \"Mail\" to return (name of every window) as text", [:], nil)
        XCTAssertNil(err)
        XCTAssertFalse(windows.contains(subject), "drafting must not open a window")
        let loc = try XCTUnwrap(EmailSearch.resolveMessageID(id))
        XCTAssertTrue(EmailSearch.isDraftsMailbox(loc.mailboxURL), loc.mailboxURL)

        let (result, failed) = tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)])
        discarded = true
        XCTAssertFalse(failed, result)
        XCTAssertEqual(json(result)["discarded"] as? Bool, true, result)
        let after = try XCTUnwrap(EmailSearch.resolveMessageID(id), "the draft must be in Trash, not erased")
        XCTAssertFalse(EmailSearch.isDraftsMailbox(after.mailboxURL), after.mailboxURL)

        // Now that it's in Trash it is no longer a draft, so a second discard is refused.
        let (again, refused) = tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)])
        XCTAssertTrue(refused, again)
        XCTAssertTrue(again.hasPrefix("not a draft"), again)
    }

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
}
