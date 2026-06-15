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
        tool = IMessageTool(fileSink: LocalFileSink())
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
}
