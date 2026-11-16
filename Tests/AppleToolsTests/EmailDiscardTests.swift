import SQLite3
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

    func testOnlyDraftIDsAreAccepted() {
        for id in ["<abc@example.com>", "abc@example.com", "12345", "not-a-uuid"] {
            let (result, isError) = EmailTool(host: .test()).handle(params: [
                "action": AnyCodable("discard"), "id": AnyCodable(id),
            ])
            XCTAssertTrue(isError)
            XCTAssertTrue(result.hasPrefix("not a draft id"), result)
        }
    }

    func testSentCopyOfADraftIsNeverPicked() {
        let sent = EmailSearch.MessageLocation(rowID: 9, mailboxURL: "imap://ABC-UUID/Sent%20Messages")
        let allMail = EmailSearch.MessageLocation(rowID: 8, mailboxURL: "imap://ABC-UUID/%5BGmail%5D/All%20Mail")
        let draft = EmailSearch.MessageLocation(rowID: 7, mailboxURL: draftsURL)
        XCTAssertNil(EmailTool.draftRow([sent, allMail]))
        XCTAssertNil(EmailTool.draftRow([]))
        XCTAssertEqual(EmailTool.draftRow([sent, allMail, draft])?.rowID, 7)
    }

    func testDraftIDFollowsADraftAcrossReSavesAndIntoSent() throws {
        let path = NSTemporaryDirectory() + "apple-tools-discard-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let doc = UUID(), other = UUID()
        func hex(_ u: UUID) -> String { u.uuidString.replacingOccurrences(of: "-", with: "") }
        let setup = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, document_id, mailbox INTEGER, deleted INTEGER, date_received INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://ABC-UUID/Drafts'), (2, 'imap://ABC-UUID/Sent');
        INSERT INTO messages VALUES (10, x'\(hex(doc))', 1, 1, 100), (11, x'\(hex(doc))', 1, 0, 120),
                                    (12, x'\(hex(doc))', 2, 0, 130), (13, x'\(hex(other))', 1, 0, 140), (14, NULL, 2, 0, 150);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertEqual(EmailSearch.documentID(rowID: 11, dbPath: path), doc)
        XCTAssertNil(EmailSearch.documentID(rowID: 14, dbPath: path), "received mail has no draft id")
        let rows = try EmailSearch.rows(documentID: doc, dbPath: path)
        XCTAssertEqual(rows.map { $0.rowID }, [12, 11], "newest first, the superseded save left out")
        XCTAssertEqual(EmailTool.draftRow(rows)?.rowID, 11)
        XCTAssertEqual(rows.last?.date, Date(timeIntervalSince1970: 120))
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
///     make test-slow TOOL=email
final class EmailDiscardLiveTests: XCTestCase {
    func testDraftThenDiscard() throws {
        try LiveTest.writes("email", "draft", "discard")
        guard EmailIntegration.isMailRunning() else { throw XCTSkip("Mail is not running; this test never launches it") }
        let tool = EmailTool(host: .test())
        let subject = "apple-tools live test \(UUID().uuidString)"

        let attachment = NSTemporaryDirectory() + "apple-tools-live-\(UUID().uuidString).txt"
        try "attached by a test".write(toFile: attachment, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: attachment) }

        let (drafted, draftFailed) = tool.handle(params: [
            "action": AnyCodable("draft"), "to": AnyCodable("nobody@example.com"),
            "subject": AnyCodable(subject), "body": AnyCodable("Created by a test; safe to delete."),
            "attachments": AnyCodable([attachment]),
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
        let documentID = try XCTUnwrap(UUID(uuidString: id), "draft id should be Mail's document id: \(id)")
        XCTAssertNotNil(EmailTool.draftRow(try EmailSearch.rows(documentID: documentID)), "draft should be in Drafts")

        // Slow on purpose: discard stays until Mail can no longer save the new draft again.
        let (result, failed) = tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)])
        discarded = true
        XCTAssertFalse(failed, result)
        XCTAssertEqual(json(result)["discarded"] as? Bool, true, result)
        let after = try EmailSearch.rows(documentID: documentID)
        XCTAssertFalse(after.isEmpty, "the draft must be in Trash, not erased")
        XCTAssertNil(EmailTool.draftRow(after), "nothing may be left in Drafts")

        // Now that it's in Trash it is no longer a draft, so a second discard is refused.
        let (again, refused) = tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)])
        XCTAssertTrue(refused, again)
        XCTAssertTrue(again.hasPrefix("not a draft"), again)
    }

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
}
