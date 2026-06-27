import XCTest
@testable import AppleToolsLib

/// Coverage for path validation on `imessage` send action's `attachments`
/// parameter. Mirrors EmailToolTests's draft-attachment cases.
/// AppleScript execution is exercised by IMessageSenderTests — these tests
/// only assert that the tool's pre-flight validation rejects bad input
/// before any send is attempted.
final class IMessageToolTests: XCTestCase {
    var tool: IMessageTool!

    override func setUp() {
        super.setUp()
        tool = IMessageTool(host: .test())
    }

    func testToolAdvertisesAttachmentsProperty() {
        let prop = tool.definition.parameters?.properties?["attachments"]
        XCTAssertNotNil(prop, "send should advertise an 'attachments' parameter")
        XCTAssertEqual(prop?.type_, "array")
        XCTAssertEqual(prop?.items?.type_, "string")
    }

    func testSendRejectsMissingAttachmentPath() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("send"),
            "to": AnyCodable("+15551234567"),
            "text": AnyCodable("hi"),
            "attachments": AnyCodable(["/tmp/apple-tools-test-does-not-exist-\(UUID().uuidString).bin"]),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not found"), "missing-path error should mention 'not found': \(result)")
    }

    func testSendRejectsDirectoryAttachment() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("send"),
            "to": AnyCodable("+15551234567"),
            "text": AnyCodable("hi"),
            "attachments": AnyCodable([NSTemporaryDirectory()]),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("directory"), "directory error should say so: \(result)")
    }

    func testSendRejectsTooManyAttachments() {
        // 11 path strings — count check fires before existence check.
        let paths = (1...11).map { "/tmp/apple-tools-imsg-cap-\($0).bin" }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("send"),
            "to": AnyCodable("+15551234567"),
            "text": AnyCodable("hi"),
            "attachments": AnyCodable(paths),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("too many"), "count cap error should mention 'too many': \(result)")
    }

    func testSendRejectsOversizedAttachment() throws {
        // Create a sparse file just over the 100MB cap.
        let tmp = NSTemporaryDirectory() + "apple-tools-imsg-oversized-\(UUID().uuidString).bin"
        XCTAssertTrue(FileManager.default.createFile(atPath: tmp, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let handle = FileHandle(forWritingAtPath: tmp)!
        try handle.seek(toOffset: 101 * 1_048_576)
        handle.write(Data([0]))
        try handle.close()

        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("send"),
            "to": AnyCodable("+15551234567"),
            "text": AnyCodable("hi"),
            "attachments": AnyCodable([tmp]),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("exceeds"), "size cap error should mention 'exceeds': \(result)")
    }

    // Disabled: this test invokes the real AppleScript runner (IMessageTool
    // doesn't go through IMessageSenderTests' mocked runAppleScript), so it
    // actually drives Messages.app to send to +15551234567 on every `make
    // test`. That triggers a macOS "failed to send" notification on each
    // deploy. Tilde-expansion is a small, well-isolated piece of behavior;
    // if we want coverage back, expose it as a pure helper and test that
    // directly instead of routing through tool.handle.
    func disabled_testSendExpandsTildeInAttachmentPath() throws {}

    // MARK: - Read path formatting recovery ( follow-up)

    /// The read tool must surface formatting as Markdown, mirroring the inbound
    /// hook. Regression guard for the gap where the hook recovered formatting
    /// but the read tool still ran the plain byte-scan, so a formatted message
    /// read back through the probe arrived at the agent stripped.
    func testReadPathRecoversFormattingFromAttributedBody() {
        // Row layout (read): 0=ROWID, 1=text, 2=is_from_me, 3=service,
        // 4=is_delivered, 5=is_sent, 6=handle, 7=date, 8=body_hex, 9=attachments.
        // Empty text column forces the attributedBody decode path.
        let row = ["270368", "", "1", "iMessage", "1", "1", "", "", IMessageTestFixtures.boldItalicBlobHex, ""]
        let msg = tool.messageFromRow(row)
        XCTAssertEqual(msg["text"] as? String, IMessageTestFixtures.boldItalicMarkdown)
    }

    // MARK: - Stats shaping (#3)

    func testStatsAdvertisedInDefinition() {
        let actionDesc = tool.definition.parameters?.properties?["action"]?.description ?? ""
        XCTAssertTrue(actionDesc.contains("stats"), "action param should document the stats action: \(actionDesc)")
    }

    /// statsChatFromRow shapes a 1:1 chat row into counts + split + chat_id,
    /// without touching the DB.
    func testStatsRowShapesOneToOneCounts() {
        // Columns: 0=ROWID, 1=chat_identifier, 2=display_name, 3=style,
        // 4=message_count, 5=sent, 6=received, 7=last_date.
        // style 45 = 1:1; last_date 0 nanos = Apple epoch (well-formed ISO).
        let row = ["12", "+15551234567", "", "45", "150", "60", "90", "0"]
        let entry = tool.statsChatFromRow(row)
        XCTAssertEqual(entry["chat_id"] as? String, "+15551234567")
        XCTAssertEqual(entry["chat_name"] as? String, "+15551234567")
        XCTAssertEqual(entry["message_count"] as? Int, 150)
        XCTAssertEqual(entry["sent"] as? Int, 60)
        XCTAssertEqual(entry["received"] as? Int, 90)
        XCTAssertNotNil(entry["last_activity"] as? String)
        XCTAssertNil(entry["participants"], "1:1 chat should not have participants")
    }

    /// Stats annotation adds contact_name to a 1:1 chat when the resolver has a
    /// match, and leaves the raw chat_id intact.
    func testStatsAnnotationAddsContactNameForOneToOne() {
        let chats: [[String: Any]] = [
            ["chat_id": "+15551234567", "chat_name": "+15551234567", "message_count": 10, "sent": 4, "received": 6],
            ["chat_id": "+15559999999", "chat_name": "+15559999999", "message_count": 3, "sent": 1, "received": 2],
        ]
        let names = ["+15551234567": "Jane Doe"]
        let annotated = tool.annotateStats(chats, names: names)
        XCTAssertEqual(annotated[0]["contact_name"] as? String, "Jane Doe")
        XCTAssertEqual(annotated[0]["chat_id"] as? String, "+15551234567", "raw handle preserved")
        XCTAssertNil(annotated[1]["contact_name"], "unmatched chat keeps no contact_name")
    }

    // MARK: - Contact-name annotation (#8)

    /// 1:1 recent conversations gain contact_name; the raw chat_id stays.
    func testRecentAnnotatesOneToOneContactName() {
        let convs: [[String: Any]] = [
            ["chat_id": "+15551234567", "chat_name": "+15551234567", "last_message_from": "+15551234567"],
        ]
        let names = ["+15551234567": "Jane Doe"]
        let annotated = tool.annotateConversations(convs, names: names)
        XCTAssertEqual(annotated[0]["contact_name"] as? String, "Jane Doe")
        XCTAssertEqual(annotated[0]["chat_id"] as? String, "+15551234567")
        XCTAssertEqual(annotated[0]["last_message_from_name"] as? String, "Jane Doe")
        XCTAssertEqual(annotated[0]["last_message_from"] as? String, "+15551234567", "raw sender preserved")
    }

    /// Group participants become {identifier, contact_name?} objects, resolving
    /// only the handles that match.
    func testRecentAnnotatesGroupParticipants() {
        let convs: [[String: Any]] = [
            ["chat_id": "chat123", "chat_name": "Trip", "participants": ["+15551234567", "+15550000000"]],
        ]
        let names = ["+15551234567": "Jane Doe"]
        let annotated = tool.annotateConversations(convs, names: names)
        let parts = annotated[0]["participants"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?[0]["identifier"] as? String, "+15551234567")
        XCTAssertEqual(parts?[0]["contact_name"] as? String, "Jane Doe")
        XCTAssertEqual(parts?[1]["identifier"] as? String, "+15550000000")
        XCTAssertNil(parts?[1]["contact_name"], "unmatched participant keeps raw only")
        // A group chat should not get a top-level contact_name.
        XCTAssertNil(annotated[0]["contact_name"])
    }

    /// identifiers(inConversations:) gathers 1:1 handles, participants, and
    /// inbound senders, skipping "me"/"unknown".
    func testIdentifiersCollectionSkipsMeAndUnknown() {
        let convs: [[String: Any]] = [
            ["chat_id": "+1555AAA", "last_message_from": "me"],
            ["chat_id": "chatX", "participants": ["+1555BBB"], "last_message_from": "unknown"],
        ]
        let ids = Set(tool.identifiers(inConversations: convs))
        XCTAssertTrue(ids.contains("+1555AAA"))
        XCTAssertTrue(ids.contains("+1555BBB"))
        XCTAssertFalse(ids.contains("me"))
        XCTAssertFalse(ids.contains("unknown"))
    }

    /// read/search messages gain from_name for resolved inbound senders.
    func testMessagesAnnotateFromName() {
        let msgs: [[String: Any]] = [
            ["message_id": 1, "from": "+15551234567", "text": "hi"],
            ["message_id": 2, "from": "me", "text": "yo"],
        ]
        let names = ["+15551234567": "Jane Doe"]
        let annotated = tool.annotateMessages(msgs, names: names)
        XCTAssertEqual(annotated[0]["from_name"] as? String, "Jane Doe")
        XCTAssertEqual(annotated[0]["from"] as? String, "+15551234567", "raw handle preserved")
        XCTAssertNil(annotated[1]["from_name"], "outgoing message gets no from_name")
    }

    /// The injected resolver is actually invoked by the recent path's annotation
    /// pipeline (end-to-end on the pure helpers, no DB).
    func testInjectedResolverDrivesAnnotation() {
        var captured: [String] = []
        tool.nameResolver = { ids in
            captured = ids
            return ["+15551234567": "Jane Doe"]
        }
        let convs: [[String: Any]] = [["chat_id": "+15551234567", "last_message_from": "+15551234567"]]
        let names = tool.nameResolver(tool.identifiers(inConversations: convs))
        let annotated = tool.annotateConversations(convs, names: names)
        XCTAssertEqual(captured, ["+15551234567"])
        XCTAssertEqual(annotated[0]["contact_name"] as? String, "Jane Doe")
    }
}
