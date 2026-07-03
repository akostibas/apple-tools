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
        XCTAssertNotNil(entry["last_message_date"] as? String)
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

    /// read/search messages gain contact_name for resolved inbound senders.
    func testMessagesAnnotateContactName() {
        let msgs: [[String: Any]] = [
            ["message_id": 1, "from": "+15551234567", "text": "hi"],
            ["message_id": 2, "from": "me", "text": "yo"],
        ]
        let names = ["+15551234567": "Jane Doe"]
        let annotated = tool.annotateMessages(msgs, names: names)
        XCTAssertEqual(annotated[0]["contact_name"] as? String, "Jane Doe")
        XCTAssertEqual(annotated[0]["from"] as? String, "+15551234567", "raw handle preserved")
        XCTAssertNil(annotated[1]["contact_name"], "outgoing message gets no contact_name")
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

    // MARK: - Spam / shortcode flagging (#9)

    /// BulkSenderClassifier shortcode shape: 5-6 bare digits are short codes;
    /// full numbers (with +), emails, and the magic suffix are handled too.
    func testClassifierShortcodeShape() {
        XCTAssertTrue(BulkSenderClassifier.isShortcode("262966"))
        XCTAssertTrue(BulkSenderClassifier.isShortcode("88202"))
        XCTAssertTrue(BulkSenderClassifier.isShortcode("24563(smsfp)"), "suffix is stripped before shape check")
        XCTAssertFalse(BulkSenderClassifier.isShortcode("+15551234567"), "full number is not a shortcode")
        XCTAssertFalse(BulkSenderClassifier.isShortcode("1234"), "4 digits too short")
        XCTAssertFalse(BulkSenderClassifier.isShortcode("alerts@txt.bank.com"), "email handle is not a shortcode")
    }

    /// SMS-filtering suffix on a full phone number flags spam but is NOT a
    /// shortcode (number shape is a real number).
    func testClassifierSuffixedFullNumberIsSpamNotShortcode() {
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulkMessage(chatID: "+12025994437(smsfp)"))
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulkMessage(chatID: "+12014623963(smsft)"))
        XCTAssertFalse(BulkSenderClassifier.isShortcode("+12025994437(smsfp)"))
    }

    /// A real contact short-circuits the flag even if the handle would
    /// otherwise look automated.
    func testClassifierContactNameShortCircuits() {
        XCTAssertFalse(BulkSenderClassifier.isLikelyBulkMessage(chatID: "262966", hasContactName: true),
                       "a resolved contact is a real person, never spam")
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulkMessage(chatID: "262966", hasContactName: false))
    }

    /// A normal 1:1 number with no suffix and no contact match is NOT flagged.
    func testClassifierPlainNumberNotFlagged() {
        XCTAssertFalse(BulkSenderClassifier.isLikelyBulkMessage(chatID: "+15551234567"))
    }

    /// recent annotation: a resolved contact is is_likely_spam=false; an
    /// unresolved shortcode is is_likely_spam=true and is_shortcode=true.
    /// Crucially this runs even when the resolver returns NO names.
    func testRecentFlagsShortcodeAndClearsContact() {
        let convs: [[String: Any]] = [
            ["chat_id": "+15551234567", "chat_name": "+15551234567"],   // real contact
            ["chat_id": "262966", "chat_name": "262966"],               // shortcode
            ["chat_id": "+12025994437(smsfp)", "chat_name": "+12025994437(smsfp)"], // suffixed
        ]
        let names = ["+15551234567": "Jane Doe"]
        let a = tool.annotateConversations(convs, names: names)
        XCTAssertEqual(a[0]["is_likely_spam"] as? Bool, false)
        XCTAssertEqual(a[0]["is_shortcode"] as? Bool, false)
        XCTAssertEqual(a[1]["is_likely_spam"] as? Bool, true)
        XCTAssertEqual(a[1]["is_shortcode"] as? Bool, true)
        XCTAssertEqual(a[2]["is_likely_spam"] as? Bool, true)
        XCTAssertEqual(a[2]["is_shortcode"] as? Bool, false, "full suffixed number is spam but not a shortcode")
        XCTAssertEqual(a[2]["chat_id"] as? String, "+12025994437(smsfp)", "raw chat_id incl. suffix preserved")
    }

    /// Flags are computed even with an empty name map (spam-only result sets).
    func testFlagsComputedWithEmptyNames() {
        let convs: [[String: Any]] = [["chat_id": "262966", "chat_name": "262966"]]
        let a = tool.annotateConversations(convs, names: [:])
        XCTAssertEqual(a[0]["is_likely_spam"] as? Bool, true)
    }

    /// Groups never get the spam flags (not bulk short-code senders).
    func testGroupChatsNotFlagged() {
        let convs: [[String: Any]] = [
            ["chat_id": "chat123", "chat_name": "Trip", "participants": ["+15551234567"]],
        ]
        let a = tool.annotateConversations(convs, names: [:])
        XCTAssertNil(a[0]["is_likely_spam"])
        XCTAssertNil(a[0]["is_shortcode"])
    }

    /// stats entries get the same flags as recent.
    func testStatsFlagsShortcode() {
        let chats: [[String: Any]] = [
            ["chat_id": "262966", "chat_name": "262966", "message_count": 5, "sent": 0, "received": 5],
            ["chat_id": "+15551234567", "chat_name": "+15551234567", "message_count": 9, "sent": 4, "received": 5],
        ]
        let a = tool.annotateStats(chats, names: ["+15551234567": "Jane Doe"])
        XCTAssertEqual(a[0]["is_likely_spam"] as? Bool, true)
        XCTAssertEqual(a[1]["is_likely_spam"] as? Bool, false)
    }

    /// read/search messages get per-inbound-message spam flags from the `from`
    /// handle (which carries the same suffix as the chat id).
    func testMessagesFlagInboundShortcode() {
        let msgs: [[String: Any]] = [
            ["message_id": 1, "from": "24563(smsfp)", "text": "VOTE NOW"],
            ["message_id": 2, "from": "+15551234567", "text": "hi"],
            ["message_id": 3, "from": "me", "text": "yo"],
        ]
        let a = tool.annotateMessages(msgs, names: ["+15551234567": "Jane Doe"])
        XCTAssertEqual(a[0]["is_likely_spam"] as? Bool, true)
        XCTAssertEqual(a[0]["is_shortcode"] as? Bool, true)
        XCTAssertEqual(a[1]["is_likely_spam"] as? Bool, false)
        XCTAssertNil(a[2]["is_likely_spam"], "outgoing message gets no spam flag")
    }

    /// Schema advertises the opt-in spam filter flags, mirroring EmailTool.
    func testSchemaAdvertisesSpamFlags() {
        XCTAssertEqual(tool.definition.parameters?.properties?["exclude_spam"]?.type_, "boolean")
        XCTAssertEqual(tool.definition.parameters?.properties?["humans_only"]?.type_, "boolean")
    }

    // MARK: - LIKE wildcard escaping (#33)

    /// User text bound into a LIKE pattern must have `%`/`_`/`\` escaped so they
    /// match literally (paired with `ESCAPE '\'`). Otherwise `100%` matches any
    /// message containing `100` and `is_a` matches `isla`.
    func testEscapeLIKEEscapesWildcardsAndEscapeChar() {
        XCTAssertEqual(IMessageTool.escapeLIKE("100%"), "100\\%")
        XCTAssertEqual(IMessageTool.escapeLIKE("is_a"), "is\\_a")
        XCTAssertEqual(IMessageTool.escapeLIKE("a\\b"), "a\\\\b")
        // Order matters: the escape char is doubled first so we don't
        // double-escape the backslashes we introduce for % and _.
        XCTAssertEqual(IMessageTool.escapeLIKE("%_\\"), "\\%\\_\\\\")
        XCTAssertEqual(IMessageTool.escapeLIKE("plain text"), "plain text")
    }

    // MARK: - Date filter parsing (#20, #23)

    /// A raw apple-nanos cursor (as emitted for next_before) round-trips
    /// exactly, so pagination never floors same-second messages (#20).
    func testDateFilterParsesRawAppleNanosCursor() {
        let cursor = "742000000123456789"
        XCTAssertEqual(IMessageIntegration.parseDateFilterToAppleNanos(cursor), 742000000123456789)
    }

    /// Full ISO, fractional ISO, and bare date/date-time forms all parse (#23).
    func testDateFilterParsesISOAndDateForms() {
        XCTAssertNotNil(IMessageIntegration.parseDateFilterToAppleNanos("2026-07-03T12:00:00Z"))
        XCTAssertNotNil(IMessageIntegration.parseDateFilterToAppleNanos("2026-07-03T12:00:00.500Z"))
        XCTAssertNotNil(IMessageIntegration.parseDateFilterToAppleNanos("2026-07-03"))
        XCTAssertNotNil(IMessageIntegration.parseDateFilterToAppleNanos("2026-07-03 12:00:00"))
        // Date-only resolves to UTC midnight of that day.
        XCTAssertEqual(IMessageIntegration.parseDateFilterToAppleNanos("2026-07-03"),
                       IMessageIntegration.parseDateFilterToAppleNanos("2026-07-03T00:00:00Z"))
    }

    /// Unparseable / empty values return nil so the caller can raise a tool
    /// error instead of silently dropping the filter and looping page 1 (#23).
    func testDateFilterRejectsUnparseableAndEmpty() {
        XCTAssertNil(IMessageIntegration.parseDateFilterToAppleNanos("not a date"))
        XCTAssertNil(IMessageIntegration.parseDateFilterToAppleNanos(""))
        XCTAssertNil(IMessageIntegration.parseDateFilterToAppleNanos("  "))
        XCTAssertNil(IMessageIntegration.parseDateFilterToAppleNanos("2026"))
    }

    /// The read/search/recent/stats tool actions surface a clear error (not a
    /// silent unfiltered page) on a malformed since/before value (#23).
    func testSearchRejectsMalformedBefore() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("hi"),
            "before": AnyCodable("garbage"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid 'before'"), "expected date-filter error: \(result)")
    }

    // MARK: - Attachment list parsing (#22)

    /// Attachments are joined by the unit separator (char 31), not ", ", so a
    /// filename containing a comma stays one entry; each entry splits on the
    /// FIRST colon; an empty mime yields no `type` key (no colon leak).
    func testAttachmentParsingHandlesCommasAndEmptyMime() {
        let sep = "\u{1F}"
        // Entry 1: comma in the filename. Entry 2: empty mime (was NULL).
        // Entry 3: a colon inside the filename.
        let attachments = ["image/png:report, final.pdf",
                           ":no_mime.bin",
                           "text/plain:weird:name.txt"].joined(separator: sep)
        // read layout: attachments at index 9.
        let row = ["1", "", "1", "iMessage", "1", "1", "", "0", "", attachments]
        let msg = tool.messageFromRow(row)
        guard let atts = msg["attachments"] as? [[String: String]] else {
            return XCTFail("expected attachments array: \(msg)")
        }
        XCTAssertEqual(atts.count, 3, "comma in filename must not split the entry")
        XCTAssertEqual(atts[0]["type"], "image/png")
        XCTAssertEqual(atts[0]["filename"], "report, final.pdf")
        XCTAssertNil(atts[1]["type"], "empty mime must not leak a bare colon as a type")
        XCTAssertEqual(atts[1]["filename"], "no_mime.bin")
        XCTAssertEqual(atts[2]["type"], "text/plain")
        XCTAssertEqual(atts[2]["filename"], "weird:name.txt", "only the first colon splits mime from name")
    }

    // MARK: - Recipient handle matching (#21)

    /// A national / formatted phone number also matches its E.164 form, since
    /// chat.db stores handles canonically as E.164. Emails match verbatim only.
    func testHandleMatchClauseIncludesE164ForPhoneNumbers() {
        PhoneFormatting.defaultRegion = "US"
        let clause = IMessageIntegration.handleMatchClause(column: "h.id", handle: "6502530000")
        XCTAssertTrue(clause.contains("'6502530000'"), "raw input preserved: \(clause)")
        XCTAssertTrue(clause.contains("'+16502530000'"), "E.164 form added: \(clause)")
        XCTAssertTrue(clause.hasPrefix("h.id IN ("), "uses an IN predicate on the column: \(clause)")

        let emailClause = IMessageIntegration.handleMatchClause(column: "h.id", handle: "a@b.com")
        XCTAssertEqual(emailClause, "h.id IN ('a@b.com')", "email matches verbatim only")
    }

    // MARK: - attributedBody length decode (#35)

    /// A >65535-byte message uses the 0x82 (4-byte little-endian) length marker;
    /// the fallback decoder must read it rather than return garbage.
    func testDecodeAttributedBodyHandles0x82LengthMarker() {
        let text = "hello world"
        var bytes: [UInt8] = Array("NSString".utf8)
        bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05])  // 5-byte preamble
        let len = UInt32(text.utf8.count)
        bytes.append(0x82)
        bytes.append(UInt8(len & 0xFF))
        bytes.append(UInt8((len >> 8) & 0xFF))
        bytes.append(UInt8((len >> 16) & 0xFF))
        bytes.append(UInt8((len >> 24) & 0xFF))
        bytes.append(contentsOf: Array(text.utf8))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(IMessageIntegration.decodeAttributedBody(hex: hex), text)
    }
}
