import XCTest
@testable import AppleToolsLib

/// Move and reply against real Mail. Only drafts these tests create are changed;
/// received and sent mail is read at most. Mail must be running:
///
///     make test-slow TOOL=email
final class EmailActionsLiveTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    /// Where the message carrying this run's token is now: one entry per copy Mail holds.
    private func copies(_ tool: EmailTool, _ token: String) -> [[String: Any]] {
        let (out, _) = tool.handle(params: [
            "action": AnyCodable("search"), "query": AnyCodable(token), "exclude_self": AnyCodable(false),
        ])
        return json(out)["messages"] as? [[String: Any]] ?? []
    }

    private func isDrafts(_ copy: [String: Any]) -> Bool {
        ["Drafts", "[Gmail]/Drafts"].contains(copy["mailbox"] as? String ?? "")
    }

    func testOwnTrashedDraftMovesToAnotherMailboxAndBack() throws {
        try LiveTest.writes("email", "move")
        try LiveTest.requireRunning("Mail")
        let tool = EmailTool(host: .test())

        // The tool drafts in Mail's default account, which may be Gmail, so this draft names its sender.
        // An address two accounts share wouldn't pin the account, so it must be unique.
        let boxes = try EmailSearch.mailboxes()
        func email(_ accountID: String) -> String? { EmailSearch.accountFields(accountID)["account_email"] as? String }
        let emails = Set(boxes.map(\.accountID)).compactMap(email)
        func archive(_ accountID: String) -> EmailSearch.Mailbox? {
            boxes.first { $0.accountID == accountID && $0.name == "Archive" }
        }
        guard let home = boxes.first(where: { box in
            EmailSearch.isDraftsMailbox(box.url) && !EmailSearch.isGmail(accountID: box.accountID, in: boxes)
                && archive(box.accountID) != nil && emails.filter { $0 == email(box.accountID) }.count == 1
        }), let sender = email(home.accountID), let destination = archive(home.accountID)?.name else {
            throw XCTSkip("Nothing to check for move: it needs an iCloud or other IMAP account that isn't Gmail, has an Archive mailbox and an address no other account uses, and Mail has none.")
        }
        let account = EmailSearch.accountFields(home.accountID)["account"] as? String ?? sender

        let token = UUID().uuidString
        let subject = "\(LiveTest.label) \(token)"
        let since = MailDraftVerifier.snapshotMaxRowID()
        let (_, scriptError) = EmailIntegration.runAppleScript("""
            set theSubject to do shell script "printenv APPLE_TOOLS_EMAIL_SUBJECT"
            set theSender to do shell script "printenv APPLE_TOOLS_EMAIL_SENDER"
            tell application "Mail"
                set newMsg to make new outgoing message with properties {subject:theSubject, content:"Created by a test; safe to delete.", sender:theSender, visible:false}
                tell newMsg to make new to recipient at end of to recipients with properties {address:"nobody@example.com"}
                close newMsg saving yes
            end tell
            """, ["APPLE_TOOLS_EMAIL_SUBJECT": subject, "APPLE_TOOLS_EMAIL_SENDER": sender], nil)
        XCTAssertNil(scriptError)
        let id = try XCTUnwrap(
            MailDraftVerifier.savedDraftID(recipient: "nobody@example.com", subject: subject, sinceROWID: since, deadline: 30),
            "TEST DRAFT LEFT BEHIND, delete it in Mail: subject '\(subject)', in Drafts of \(account) or of Mail's default account")
        let documentID = try XCTUnwrap(UUID(uuidString: id))
        func discard() -> (String, Bool) { tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)]) }
        // Whatever fails below, the draft must not stay in Drafts.
        defer {
            if EmailTool.draftRow((try? EmailSearch.rows(documentID: documentID)) ?? []) != nil {
                let (out, failed) = discard()
                if failed { XCTFail("test draft '\(subject)' is still in Drafts of \(account); delete it in Mail: \(out)") }
            }
        }

        let (discardResult, discardFailed) = discard()
        XCTAssertFalse(discardFailed, discardResult)
        let trashed = try XCTUnwrap(copies(tool, token).first { !isDrafts($0) }, "the discarded test draft is not in Trash")
        XCTAssertEqual(trashed["account"] as? String, account, "Mail did not save the draft in the sender's account")
        let messageID = try XCTUnwrap(trashed["id"] as? String)
        let trash = try XCTUnwrap(trashed["mailbox"] as? String)
        func move(to mailbox: String) -> (String, Bool) {
            tool.handle(params: ["action": AnyCodable("move"), "id": AnyCodable(messageID),
                                 "mailbox": AnyCodable(mailbox), "account": AnyCodable(account)])
        }
        // A set: discard can trash two copies under one Message-ID, and move takes them together.
        func mailboxesNow() -> Set<String> {
            Set(copies(tool, token).filter { $0["id"] as? String == messageID }.compactMap { $0["mailbox"] as? String })
        }
        defer {
            if mailboxesNow().contains(destination) {
                _ = move(to: trash)
                if mailboxesNow().contains(destination) {
                    XCTFail("TEST MESSAGE LEFT BEHIND, delete it in Mail: subject '\(subject)', in \(destination) of \(account)")
                }
            }
        }

        let (intoDrafts, draftsRefused) = move(to: home.name)
        XCTAssertTrue(draftsRefused && intoDrafts.contains("into Drafts"), intoDrafts)
        XCTAssertEqual(mailboxesNow(), [trash], "a refused move must leave the message where it was")

        let (there, thereFailed) = move(to: destination)
        XCTAssertFalse(thereFailed, there)
        XCTAssertEqual(json(there)["moved"] as? Bool, true, there)
        XCTAssertEqual(mailboxesNow(), [destination])

        let (back, backFailed) = move(to: trash)
        XCTAssertFalse(backFailed, back)
        XCTAssertEqual(json(back)["moved"] as? Bool, true, back)
        XCTAssertEqual(mailboxesNow(), [trash])
        XCTAssertNil(copies(tool, token).first(where: isDrafts), "nothing may be left in Drafts")
    }

    /// The safest inbox message to reply to: one the user sent themselves, else one from a no-reply address.
    private func safeReplyTarget(_ tool: EmailTool) throws -> (id: String, address: String, read: Bool) {
        let (boxes, _) = tool.handle(params: ["action": AnyCodable("mailboxes")])
        let own = Set((json(boxes)["accounts"] as? [[String: Any]] ?? [])
            .compactMap { ($0["account_email"] as? String)?.lowercased() })
        let (inbox, inboxFailed) = tool.handle(params: ["action": AnyCodable("inbox"), "limit": AnyCodable(50)])
        XCTAssertFalse(inboxFailed, inbox)
        let candidates = (json(inbox)["messages"] as? [[String: Any]] ?? []).compactMap { m -> (id: String, address: String, read: Bool)? in
            guard let id = m["id"] as? String, let from = m["from"] as? String else { return nil }
            return (id, EmailIntegration.extractEmailAddress(from).lowercased(), m["read"] as? Bool ?? false)
        }
        func noReply(_ address: String) -> Bool {
            let local = address.split(separator: "@").first.map(String.init) ?? ""
            return local.contains("reply") && BulkSenderClassifier.isLikelyBulk(address: address)
        }
        guard let target = candidates.first(where: { own.contains($0.address) })
                ?? candidates.first(where: { noReply($0.address) }) else {
            throw XCTSkip("Nothing to check for reply: no inbox message is from yourself or from a no-reply sender, and this test won't draft a reply to anyone else. Email yourself and re-run.")
        }
        return target
    }

    func testReplyIsDraftedToASafeSenderThenDiscarded() throws {
        try LiveTest.writes("email", "reply")
        try LiveTest.requireRunning("Mail")
        let tool = EmailTool(host: .test())
        let target = try safeReplyTarget(tool)

        func windows() -> String {
            EmailIntegration.runAppleScript("tell application \"Mail\" to return (name of every window) as text", [:], nil).0
        }
        let windowsBefore = windows()
        let since = MailDraftVerifier.snapshotMaxRowID()
        let (replied, replyFailed) = tool.handle(params: [
            "action": AnyCodable("reply"), "id": AnyCodable(target.id),
            "body": AnyCodable("\(LiveTest.label) \(UUID().uuidString). Created by a test; safe to delete."),
        ])
        XCTAssertFalse(replyFailed, replied)
        let result = json(replied)
        let subject = result["subject"] as? String ?? "(unknown subject)"
        let to = result["to"] as? String ?? target.address
        // The tool gives up on the id after 10s; a draft with no id can't be discarded, so look longer.
        let id = replyFailed ? nil : result["id"] as? String
            ?? MailDraftVerifier.savedDraftID(recipient: to, subject: subject, sinceROWID: since, deadline: 30)

        addTeardownBlock {
            guard !replyFailed else { return }
            let left = "REPLY DRAFT LEFT BEHIND, delete it in Mail: subject '\(subject)', addressed to \(to)"
            guard let id, let documentID = UUID(uuidString: id) else {
                return XCTFail("\(left), in the Drafts of Mail's default sending account. Mail never showed it, so there is no id to discard it by.")
            }
            let row = EmailTool.draftRow((try? EmailSearch.rows(documentID: documentID)) ?? [])
            let account = row.flatMap { EmailSearch.accountFields($0.mailboxURL)["account"] as? String } ?? "unknown"
            let (out, failed) = tool.handle(params: ["action": AnyCodable("discard"), "id": AnyCodable(id)])
            let stillThere = EmailTool.draftRow((try? EmailSearch.rows(documentID: documentID)) ?? []) != nil
            if failed || stillThere || self.json(out)["discarded"] as? Bool != true {
                XCTFail("\(left), in Drafts of account \(account). Discard answered: \(out)")
            }
        }

        XCTAssertEqual(to.lowercased(), target.address, "a reply goes to the original sender only")
        XCTAssertEqual(result["reply_all"] as? Bool, false)
        XCTAssertTrue(subject.lowercased().hasPrefix("re:"), subject)
        XCTAssertNotNil(result["id"], "reply returned no id to discard the draft by: \(replied)")
        // The original may already be open in a window of the same name, hence the before.
        XCTAssertFalse(windows().contains(subject) && !windowsBefore.contains(subject), "replying must not open a window")
        if let id, let documentID = UUID(uuidString: id) {
            XCTAssertNotNil(EmailTool.draftRow(try EmailSearch.rows(documentID: documentID)), "reply should be in Drafts")
        }

        let (inbox, _) = tool.handle(params: ["action": AnyCodable("inbox"), "limit": AnyCodable(50)])
        let original = (json(inbox)["messages"] as? [[String: Any]] ?? []).first { $0["id"] as? String == target.id }
        XCTAssertEqual(original?["read"] as? Bool, target.read, "replying must not change the original's read state")
    }
}
