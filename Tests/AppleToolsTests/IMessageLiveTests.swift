import Contacts
import XCTest
@testable import AppleToolsLib

/// Live send against the real Messages app. A sent message can't be deleted, so each run
/// sends exactly ONE, only to the user's own me-card handle, and leaves it in that
/// conversation. Run with `make test-slow TOOL=imessage`.
final class IMessageLiveTests: XCTestCase {

    private var outDir: String!
    private var tool: IMessageTool { IMessageTool(host: .test(fileSink: LocalFileSink(outputDir: outDir))) }

    override func setUpWithError() throws {
        try LiveTest.writes("imessage", "send", "fetch_attachment", "read", "search")
        try LiveTest.requireRunning("Messages")
        outDir = NSTemporaryDirectory() + "apple-tools-imessage-live-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = outDir { try? FileManager.default.removeItem(atPath: d) }
        super.tearDown()
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        guard !isError else { throw NSError(domain: "imessage", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    /// The user's own phones (E.164) then emails, from the Contacts "me" card. Empty when there is none.
    private func meHandles() -> [String] {
        let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        guard ContactsIntegration.requestAccess(),
              let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else { return [] }
        return me.phoneNumbers.map { PhoneFormatting.normalized($0.value.stringValue) }
            + me.emailAddresses.map { $0.value as String }
    }

    private func mine(_ messages: Any?) -> [[String: Any]] {
        (messages as? [[String: Any]] ?? []).filter { $0["from"] as? String == "me" }
    }

    private func wait<T>(for what: String, _ probe: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if let found = try probe() { return found }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        throw NSError(domain: "imessage", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "send was accepted, but \(what) never appeared in the Messages store within 30s"])
    }

    func testOneSendToSelfIsSearchableReadableAndItsAttachmentFetches() throws {
        let handles = meHandles()
        // Prefer the handle the user already messages themselves on; never anyone off the me card.
        guard let to = handles.first(where: { IMessageIntegration.hasOneToOneChatForHandle($0) == true }) ?? handles.first else {
            throw XCTSkip("No \"My Card\" with a phone number or email in Contacts, so there is no safe recipient. Set one in Contacts and re-run.")
        }

        let id = UUID().uuidString.prefix(8).lowercased()
        let text = "\(LiveTest.label) \(id)"
        let name = "apple-tools-live-test-\(id).txt"
        let source = outDir + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: source))

        guard meHandles().contains(to) else { return XCTFail("refusing to send: the recipient is not on the me card") }
        let sent = try call(["action": "send", "to": to, "text": text, "attachments": [source]])
        XCTAssertEqual(sent["status"] as? String, "sending")
        try FileManager.default.removeItem(atPath: source)

        let hit = try wait(for: "the message") {
            self.mine(try self.call(["action": "search", "query": id, "limit": 5])["messages"]).first
        }
        XCTAssertEqual(hit["text"] as? String, text)
        let chat = try XCTUnwrap(hit["chat_id"] as? String)

        // Messages stores the text and the file as two rows, so the attachment has its own message_id.
        let carrier = try wait(for: "its attachment") { () -> [String: Any]? in
            let page = try self.call(["action": "read", "chat": chat, "limit": 10])
            if page["multiple_matches"] != nil {
                throw NSError(domain: "imessage", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "read can't open the chat_id that search returned: several conversations share it"])
            }
            let messages = self.mine(page["messages"])
            XCTAssertTrue(messages.contains { $0["message_id"] as? Int == hit["message_id"] as? Int }, "read misses the sent text")
            return messages.first { ($0["attachments"] as? [[String: Any]])?.contains { $0["filename"] as? String == name } == true }
        }

        let fetched = try call(["action": "fetch_attachment", "message_id": try XCTUnwrap(carrier["message_id"] as? Int),
                                "filename": name])
        let path = try XCTUnwrap(fetched["path"] as? String)
        XCTAssertTrue(path.hasPrefix(outDir), "fetched outside the test's output dir: \(path)")
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data(text.utf8))
    }
}
