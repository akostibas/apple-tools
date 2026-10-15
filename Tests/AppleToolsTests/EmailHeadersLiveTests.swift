import XCTest
@testable import AppleToolsLib

/// Reads one real message's headers from disk and via Mail.app; both must agree.
/// Mail must be running. Skipped unless given a Message-ID that's on disk:
///
///     APPLE_TOOLS_EMAIL_LIVE_ID='<id@host>' swift test --filter EmailHeadersLiveTests
final class EmailHeadersLiveTests: XCTestCase {
    func testAppleScriptFallbackMatchesDisk() throws {
        guard let id = ProcessInfo.processInfo.environment["APPLE_TOOLS_EMAIL_LIVE_ID"] else {
            throw XCTSkip("set APPLE_TOOLS_EMAIL_LIVE_ID to run live email header tests")
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
