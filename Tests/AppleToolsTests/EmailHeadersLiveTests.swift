import XCTest
@testable import AppleToolsLib

/// Reads one real message's headers from disk and via Mail.app; both must agree.
/// Read-only; uses the newest inbox message. Run with `bin/check --tool email`.
final class EmailHeadersLiveTests: ReadOnlyCase {
    func testAppleScriptFallbackMatchesDisk() throws {
        try LiveTest.reads("email", "headers")
        try requireRunning("Mail")
        let inbox = rows(try call(EmailTool(host: host), ["action": "inbox", "limit": 1]), "messages")
        guard let id = inbox.first?["id"] as? String else {
            throw XCTSkip("no inbox message to check. Either this Mac has none or the lookup is broken: open Mail and see whether it shows any.")
        }
        let loc = try XCTUnwrap(EmailSearch.resolveMessageID(id), "id not in Envelope Index")
        let path = try XCTUnwrap(EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL), "not on disk")
        let disk = try EmailMessage.loadHeaders(atPath: path)
        let mail = EmailMessage.groupHeaders(
            try EmailIntegration.headersViaAppleScript(rowID: loc.rowID, mailboxURL: loc.mailboxURL))
        XCTAssertEqual(mail["message-id"], disk["message-id"])
        XCTAssertEqual(mail["sender"], disk["sender"])
        XCTAssertEqual(mail["received"]?.count, disk["received"]?.count)
    }
}
