import XCTest
@testable import AppleToolsLib

final class IMessageSenderTests: XCTestCase {

    /// Saves and restores the global injectables so tests don't leak.
    private var savedRunner: ((String, [String: String], (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?))!
    private var savedLookup: ((String, Int64) -> IMessageIntegration.OutgoingStatus)!
    private var savedMaxROWID: (() -> Int64)!
    private var savedChatExists: ((String) -> Bool?)!
    private var savedDeadline: TimeInterval = 0
    private var savedSMSDeadline: TimeInterval = 0
    private var savedPollInterval: TimeInterval = 0

    override func setUp() {
        super.setUp()
        savedRunner = IMessageSender.runAppleScript
        savedLookup = IMessageSender.lookupOutgoingStatus
        savedMaxROWID = IMessageSender.currentMaxROWID
        savedChatExists = IMessageSender.chatExistsForHandle
        savedDeadline = IMessageSender.deliveryDeadline
        savedSMSDeadline = IMessageSender.smsDeliveryDeadline
        savedPollInterval = IMessageSender.deliveryPollInterval

        // Default test fixtures: AppleScript succeeds, send is confirmed in
        // chat.db. Individual tests override as needed. Tight deadline keeps
        // tests fast.
        IMessageSender.runAppleScript = { _, _, _ in ("", nil) }
        IMessageSender.currentMaxROWID = { 0 }
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .sent, rowID: 1, error: 0, isSent: true, isDelivered: true)
        }
        // Default: chat already exists — preserves legacy buddy-send
        // behavior for all pre-existing tests. First-contact-path tests
        // override to return false.
        IMessageSender.chatExistsForHandle = { _ in true }
        IMessageSender.deliveryDeadline = 0.5
        IMessageSender.smsDeliveryDeadline = 0.5
        IMessageSender.deliveryPollInterval = 0.02
    }

    override func tearDown() {
        IMessageSender.runAppleScript = savedRunner
        IMessageSender.lookupOutgoingStatus = savedLookup
        IMessageSender.currentMaxROWID = savedMaxROWID
        IMessageSender.chatExistsForHandle = savedChatExists
        IMessageSender.deliveryDeadline = savedDeadline
        IMessageSender.smsDeliveryDeadline = savedSMSDeadline
        IMessageSender.deliveryPollInterval = savedPollInterval
        super.tearDown()
    }

    /// Fires N concurrent `send` calls whose fake AppleScript runner records
    /// how many invocations overlap. Asserts the max concurrency observed is
    /// 1 — i.e. all AppleScript execution is serialized by the probe-wide
    /// send queue. This is the contract that keeps NSAppleScript (which is
    /// not thread-safe) from racing across call sites.
    func testSendSerializesConcurrentCallers() {
        let inFlight = AtomicCounter()
        let maxObserved = AtomicCounter()

        IMessageSender.runAppleScript = { _, _, _ in
            let current = inFlight.increment()
            maxObserved.updateMax(current)
            // Hold the "critical section" long enough that, without
            // serialization, overlap would be nearly certain.
            Thread.sleep(forTimeInterval: 0.01)
            inFlight.decrement()
            return ("", nil)
        }

        let concurrent = 20
        let group = DispatchGroup()
        for i in 0..<concurrent {
            DispatchQueue.global().async(group: group) {
                _ = IMessageSender.send(to: "+1555000\(i)", text: "msg \(i)")
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "sends did not complete in time")

        XCTAssertEqual(maxObserved.value, 1,
            "expected serialized AppleScript execution; observed \(maxObserved.value) concurrent invocations")
    }

    /// Sanity check: the happy-path `send` returns success when the runner
    /// reports no error.
    func testSendReturnsSuccessFromFakeRunner() {
        IMessageSender.runAppleScript = { _, _, _ in ("", nil) }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.transport, "iMessage")
    }

    // MARK: - Group chat ID detection

    func testIsGroupChatID() {
        // Chat identifiers used by group chats
        XCTAssertTrue(IMessageSender.isGroupChatID("chat6711433889022879"))
        XCTAssertTrue(IMessageSender.isGroupChatID("chat123"))
        XCTAssertTrue(IMessageSender.isGroupChatID("iMessage;+;chat123@icloud.com"))

        // Phone numbers and emails are not chat IDs
        XCTAssertFalse(IMessageSender.isGroupChatID("+15551234567"))
        XCTAssertFalse(IMessageSender.isGroupChatID("user@example.com"))
        XCTAssertFalse(IMessageSender.isGroupChatID("5551234567"))

        // Email local-parts that merely START with "chat" must not be
        // misrouted to the group path (issue #35) — the real form is
        // `chat` + digits.
        XCTAssertFalse(IMessageSender.isGroupChatID("chatter@example.com"))
        XCTAssertFalse(IMessageSender.isGroupChatID("chatty.person@icloud.com"))
        XCTAssertFalse(IMessageSender.isGroupChatID("chat"))
    }

    /// Multi-line bodies must reach Messages with their LFs intact. `do shell
    /// script` converts LF→CR unless invoked `without altering line endings`,
    /// so the script that reads the payload from the environment must carry
    /// that phrase (issue #35).
    func testPayloadShellReadPreservesLineEndings() {
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }
        _ = IMessageSender.send(to: "+15551234567", text: "line one\nline two")
        guard let s = capturedScript else { return XCTFail("no script captured") }
        XCTAssertTrue(s.contains(#"do shell script "printenv APPLE_TOOLS_IMSG_TEXT" without altering line endings"#),
            "payload read must preserve LFs: \(s)")
    }

    /// When sending to a group chat ID, the AppleScript should use `chat id`
    /// addressing instead of `buddy` addressing.
    func testGroupChatSendUsesChatIDScript() {
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }

        // chatGUID lookup will hit real chat.db — use a fake chat ID that
        // won't be found, so we get a clean error path.
        let result = IMessageSender.send(to: "chat000000000000000", text: "hello group")

        // Since the chat ID won't exist in chat.db, we expect an error about
        // the group chat not being found.
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.message.contains("group chat not found"),
            "expected 'group chat not found' error, got: \(result.message)")
        // AppleScript should NOT have been called since guid lookup failed.
        XCTAssertNil(capturedScript, "AppleScript should not run when guid lookup fails")
    }

    // MARK: - Delivery confirmation (issue)

    /// AppleScript reports success and chat.db confirms `is_sent = 1, error = 0`.
    /// This is the happy path; user-facing message stays "Message queued via iMessage."
    func testDeliveryConfirmedReturnsSuccess() {
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .sent, rowID: 99, error: 0, isSent: true, isDelivered: true)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.transport, "iMessage")
        XCTAssertTrue(result.message.contains("queued"))
    }

    /// iMessage rejected with error=22 AND SMS fallback also failed → user
    /// sees a combined-failure message naming both errors. (Both lookups
    /// return rejected; the SMS attempt happens because error=22 is
    /// retriable for phone numbers.)
    func testDeliveryRejectedAndSMSAlsoRejectedSurfacesCombinedError() {
        IMessageSender.lookupOutgoingStatus = { _, _ in
            // Same rejected status returned for both the iMessage and SMS polls.
            IMessageIntegration.OutgoingStatus(state: .rejected, rowID: 100, error: 22, isSent: false, isDelivered: false)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertTrue(result.isError, "rejected delivery must produce isError=true")
        XCTAssertEqual(result.transport, "SMS", "transport reflects the last attempt")
        XCTAssertTrue(result.message.contains("iMessage failed"),
            "expected combined-failure message naming iMessage, got: \(result.message)")
        XCTAssertTrue(result.message.contains("SMS fallback also failed"),
            "expected combined-failure message naming SMS, got: \(result.message)")
    }

    /// chat.db row exists but is_sent=0 and error=0 throughout the deadline —
    /// Messages.app accepted the message but never transmitted.
    func testDeliveryStuckPendingSurfacesAsError() {
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .pending, rowID: 101, error: 0, isSent: false, isDelivered: false)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.message.contains("not confirmed"),
            "expected pending error wording, got: \(result.message)")
    }

    /// AppleScript succeeded but no outgoing row appeared during the poll
    /// window. Most likely Messages.app didn't actually queue the message.
    func testDeliveryNoRowSurfacesAsError() {
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .noRow, rowID: 0, error: 0, isSent: false, isDelivered: false)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.message.contains("unverified"),
            "expected unverified wording, got: \(result.message)")
    }

    /// The poll must terminate as soon as a `.sent` state is observed —
    /// not block the full deadline.
    func testDeliveryReturnsImmediatelyOnTerminalState() {
        IMessageSender.deliveryDeadline = 5.0
        IMessageSender.deliveryPollInterval = 0.02
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .sent, rowID: 1, error: 0, isSent: true, isDelivered: true)
        }
        let start = Date()
        _ = IMessageSender.send(to: "+15551234567", text: "hi")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
            "send should return promptly on terminal state, took \(elapsed)s")
    }

    // MARK: - SMS fallback (issue step 2)

    /// iMessage rejected with error=22 → SMS fallback succeeds → result is
    /// success, transport = SMS, message names the SMS path.
    func testRejectedThenSMSSucceedsReturnsSMSSuccess() {
        // Distinguish iMessage poll (cursor before iMessage send) from SMS
        // poll (cursor advanced after iMessage rejection). The simplest
        // injection: track invocation count and return rejected for the
        // first lookup, sent for the second.
        var calls = 0
        IMessageSender.currentMaxROWID = {
            calls += 1
            return Int64(calls)
        }
        IMessageSender.lookupOutgoingStatus = { _, since in
            // First poll uses cursor from iMessage send (1) → rejected.
            // Second poll uses cursor from SMS send (2) → sent.
            if since == 1 {
                return IMessageIntegration.OutgoingStatus(state: .rejected, rowID: 100, error: 22, isSent: false, isDelivered: false)
            }
            return IMessageIntegration.OutgoingStatus(state: .sent, rowID: 101, error: 0, isSent: true, isDelivered: true)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertFalse(result.isError, "expected SMS fallback to succeed, got error: \(result.message)")
        XCTAssertEqual(result.transport, "SMS")
        XCTAssertTrue(result.message.contains("SMS"),
            "expected SMS-path message, got: \(result.message)")
    }

    /// SMS fallback handed off to iPhone relay but never confirmed → return
    /// a relay-specific error so the user knows where to look.
    func testRejectedThenSMSPendingSurfacesRelayError() {
        IMessageSender.lookupOutgoingStatus = { _, since in
            if since == 0 {
                return IMessageIntegration.OutgoingStatus(state: .rejected, rowID: 100, error: 22, isSent: false, isDelivered: false)
            }
            return IMessageIntegration.OutgoingStatus(state: .pending, rowID: 101, error: 0, isSent: false, isDelivered: false)
        }
        var calls = 0
        IMessageSender.currentMaxROWID = {
            let v = Int64(calls)
            calls += 1
            return v
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.transport, "SMS")
        XCTAssertTrue(result.message.contains("iPhone"),
            "expected iPhone-relay-related error wording, got: \(result.message)")
    }

    /// iMessage rejected with error=22 for an EMAIL address → no SMS attempt
    /// (SMS doesn't support email) → original iMessage rejection surfaces.
    func testRejectedForEmailDoesNotAttemptSMS() {
        var smsAttempted = false
        IMessageSender.runAppleScript = { script, _, _ in
            if script.contains("SMS") {
                smsAttempted = true
            }
            return ("", nil)
        }
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .rejected, rowID: 100, error: 22, isSent: false, isDelivered: false)
        }
        let result = IMessageSender.send(to: "user@example.com", text: "hi")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.transport, "iMessage", "should report iMessage, not SMS")
        XCTAssertFalse(smsAttempted, "must not run SMS AppleScript for email recipients")
        XCTAssertTrue(result.message.contains("not attempted"),
            "expected explanation about SMS not being attempted, got: \(result.message)")
    }

    /// iMessage rejected with a non-22 error code → not retriable via SMS,
    /// no SMS attempt, original iMessage error surfaces.
    func testRejectedWithNonRetriableErrorDoesNotAttemptSMS() {
        var smsAttempted = false
        IMessageSender.runAppleScript = { script, _, _ in
            if script.contains("SMS") { smsAttempted = true }
            return ("", nil)
        }
        IMessageSender.lookupOutgoingStatus = { _, _ in
            // Code 999: not in our retry-eligible list.
            IMessageIntegration.OutgoingStatus(state: .rejected, rowID: 100, error: 999, isSent: false, isDelivered: false)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.transport, "iMessage")
        XCTAssertFalse(smsAttempted, "must not retry via SMS for non-retriable error codes")
        XCTAssertTrue(result.message.contains("error 999"),
            "expected original iMessage error in message, got: \(result.message)")
    }

    /// The poll must use the cursor captured *before* AppleScript ran, so
    /// only this send's row is considered.
    func testDeliveryPollUsesCursorFromBeforeSend() {
        IMessageSender.currentMaxROWID = { 12345 }
        var observedCursor: Int64 = -1
        IMessageSender.lookupOutgoingStatus = { _, since in
            observedCursor = since
            return IMessageIntegration.OutgoingStatus(state: .sent, rowID: 12346, error: 0, isSent: true, isDelivered: true)
        }
        _ = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertEqual(observedCursor, 12345)
    }

    /// Phone number sends should use the buddy path, not the chat path.
    func testPhoneNumberSendUsesBuddyScript() {
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }

        let result = IMessageSender.send(to: "+15551234567", text: "hello")
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(capturedScript)
        XCTAssertTrue(capturedScript!.contains("buddy"), "expected buddy addressing for phone number")
        XCTAssertFalse(capturedScript!.contains("chat id"), "should not use chat id for phone number")
    }

    // MARK: - First-contact chat creation

    /// When chat.db reports no prior thread for the recipient, the sender
    /// must switch to the chat-creating AppleScript path. `send to buddy`
    /// silently no-ops in that case and the message never leaves the Mac.
    func testFirstContactCreatesChatBeforeSending() {
        IMessageSender.chatExistsForHandle = { _ in false }
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }

        let result = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(capturedScript)
        XCTAssertTrue(capturedScript!.contains("make new text chat with properties {participants:{targetBuddy}}"),
            "first-contact path must create a new text chat:\n\(capturedScript ?? "")")
        XCTAssertTrue(capturedScript!.contains("send theText to targetChat"),
            "first-contact path must send to the newly-created chat, not the buddy:\n\(capturedScript ?? "")")
        XCTAssertFalse(capturedScript!.contains("send theText to targetBuddy"),
            "first-contact path must not address the buddy directly (would silently no-op):\n\(capturedScript ?? "")")
    }

    /// Existing-chat case keeps the legacy buddy-send path — creating a
    /// duplicate chat would split the conversation in Messages.app.
    func testExistingChatUsesLegacyBuddySend() {
        IMessageSender.chatExistsForHandle = { _ in true }
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }

        _ = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertNotNil(capturedScript)
        XCTAssertFalse(capturedScript!.contains("make new text chat"),
            "existing-chat case must not create a new chat:\n\(capturedScript ?? "")")
        XCTAssertTrue(capturedScript!.contains("send theText to targetBuddy"),
            "existing-chat case must send to the buddy:\n\(capturedScript ?? "")")
    }

    /// Lookup failure (nil) — chat.db unreadable, schema drift, etc. —
    /// falls back to the legacy path rather than risk duplicating a thread
    /// that actually exists.
    func testNilChatExistsFallsBackToLegacy() {
        IMessageSender.chatExistsForHandle = { _ in nil }
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }

        _ = IMessageSender.send(to: "+15551234567", text: "hi")
        XCTAssertNotNil(capturedScript)
        XCTAssertFalse(capturedScript!.contains("make new text chat"),
            "nil chat-existence result must fall back to legacy path:\n\(capturedScript ?? "")")
    }

    /// First-contact path must also route attachments through the new
    /// chat object, not the buddy — otherwise files would land in (or
    /// silently no-op against) the missing 1:1 thread.
    func testFirstContactRoutesAttachmentsToChat() {
        IMessageSender.chatExistsForHandle = { _ in false }
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }

        _ = IMessageSender.send(to: "+15551234567", text: "look", attachments: ["/tmp/a.png"])
        XCTAssertNotNil(capturedScript)
        XCTAssertTrue(capturedScript!.contains(#"send POSIX file "/tmp/a.png" to targetChat"#),
            "attachments in first-contact path must address the new chat:\n\(capturedScript ?? "")")
        XCTAssertFalse(capturedScript!.contains(#"send POSIX file "/tmp/a.png" to targetBuddy"#),
            "attachments must not address the buddy in first-contact path:\n\(capturedScript ?? "")")
    }

    // MARK: - Payload parameterization

    /// Payload text must NOT appear in the AppleScript source. It flows through
    /// the env dict and is fetched in-script via `system attribute`, so embedded
    /// newlines, quotes, AppleScript reserved words, etc. survive unchanged.
    ///
    /// Pins the fix for, where paragraph breaks (`\n \n`) in assistant
    /// replies were being eaten because raw LFs interpolated into the
    /// `send "..."` literal got stripped by AppleScript/Messages.
    func testPayloadTextNotEmbeddedInScriptSource() {
        var capturedScript: String?
        var capturedEnv: [String: String]?
        IMessageSender.runAppleScript = { script, env, _ in
            capturedScript = script
            capturedEnv = env
            return ("", nil)
        }

        // Includes the exact pattern from the prod regression plus several
        // payload shapes that the old escape helper would have mangled.
        let payload = """
        Trump-Xi summit recap.

        It's the first visit by a sitting president in nearly a decade.
        She said "danger" — and meant it.
        Trailing backslash here \\
        end tell
        """

        _ = IMessageSender.send(to: "+15551234567", text: payload)

        XCTAssertNotNil(capturedScript)
        XCTAssertNotNil(capturedEnv)

        // The fix: payload chars do not appear in the AppleScript source at all.
        // Sampling distinctive substrings is enough — full payload check would
        // fail spuriously on substrings shared with the script template.
        for needle in ["Trump-Xi", "It's the first", "danger", "Trailing backslash", "end tell\n"] {
            XCTAssertFalse(capturedScript!.contains(needle),
                "AppleScript source must not contain payload substring '\(needle)' — payload should flow through env")
        }

        // The script *does* reference the env key.
        XCTAssertTrue(capturedScript!.contains("printenv APPLE_TOOLS_IMSG_TEXT"),
            "script must fetch payload via `do shell script \"printenv ...\"`")

        // The env dict carries the payload verbatim.
        XCTAssertEqual(capturedEnv?["APPLE_TOOLS_IMSG_TEXT"], payload)
    }

    // MARK: - Markdown stripping

    /// The assistant speaks Markdown but Messages renders it as raw syntax, so the
    /// send path flattens Markdown to plain text. This exercises the real
    /// `send` -> `sendLocked` -> script-build wiring (not the converter in
    /// isolation) and asserts the env payload — the bytes Messages actually
    /// transmits — is the stripped form.
    func testMarkdownStrippedBeforeSend() {
        var capturedEnv: [String: String]?
        IMessageSender.runAppleScript = { _, env, _ in
            capturedEnv = env
            return ("", nil)
        }
        let markdown = """
        Here's the **plan** for *today*:
        - step one
        - step two
        See [docs](https://x.com/a_b_c)
        """
        let result = IMessageSender.send(to: "+15551234567", text: markdown)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(capturedEnv?["APPLE_TOOLS_IMSG_TEXT"], """
        Here's the plan for today:
        • step one
        • step two
        See docs (https://x.com/a_b_c)
        """)
    }

    // MARK: - Attachments

    /// Attachments append `send POSIX file "..." to targetBuddy` lines after
    /// the text body and before `PHASE: committed`. A delay between sends
    /// keeps Messages.app's async file-import pipeline from dropping files.
    func testAttachmentsAppendPosixFileSends() {
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }
        let result = IMessageSender.send(to: "+15551234567", text: "look",
            attachments: ["/tmp/a.png", "/tmp/b.pdf"])
        XCTAssertFalse(result.isError)
        guard let s = capturedScript else { return XCTFail("no script captured") }
        XCTAssertTrue(s.contains(#"send POSIX file "/tmp/a.png" to targetBuddy"#),
            "script should include first attachment: \(s)")
        XCTAssertTrue(s.contains(#"send POSIX file "/tmp/b.pdf" to targetBuddy"#),
            "script should include second attachment: \(s)")
        XCTAssertEqual(s.components(separatedBy: "delay 0.2").count - 1, 2,
            "expected a delay after each of the two attachments: \(s)")
        // Text bubble must be ordered before any attachment so the recipient
        // sees the caption first.
        let textIdx = s.range(of: "send theText")?.lowerBound
        let firstAttachIdx = s.range(of: "/tmp/a.png")?.lowerBound
        XCTAssertNotNil(textIdx)
        XCTAssertNotNil(firstAttachIdx)
        XCTAssertTrue(textIdx! < firstAttachIdx!, "text should be sent before attachments")
        XCTAssertTrue(firstAttachIdx! < s.range(of: "PHASE: committed")!.lowerBound,
            "attachments must land inside the cancel-safe window before PHASE: committed")
    }

    /// Attachment paths must be AppleScript-escaped (backslash + double-quote)
    /// the same way the recipient and text payload are.
    func testAttachmentPathIsEscaped() {
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }
        _ = IMessageSender.send(to: "+15551234567", text: "hi",
            attachments: [#"/tmp/with "quote".png"#])
        guard let s = capturedScript else { return XCTFail("no script captured") }
        XCTAssertTrue(s.contains(#"send POSIX file "/tmp/with \"quote\".png" to targetBuddy"#),
            "attachment path should be escaped: \(s)")
    }

    /// Empty attachments list produces the same script shape as before
    /// (no `POSIX file` references, no extra delays).
    func testEmptyAttachmentsBehavesLikeTextOnly() {
        var capturedScript: String?
        IMessageSender.runAppleScript = { script, _, _ in
            capturedScript = script
            return ("", nil)
        }
        _ = IMessageSender.send(to: "+15551234567", text: "hi", attachments: [])
        guard let s = capturedScript else { return XCTFail("no script captured") }
        XCTAssertFalse(s.contains("POSIX file"), "no attachment lines expected: \(s)")
        XCTAssertFalse(s.contains("delay 0.2"), "no per-attachment delay expected: \(s)")
    }

    /// SMS does not support arbitrary file attachments. If iMessage rejects
    /// the recipient with error=22 and attachments are present, refuse to
    /// fall back to SMS — silent attachment drop would be worse than a
    /// clear error.
    func testRejectedWithAttachmentsRefusesSMSFallback() {
        var smsAttempted = false
        IMessageSender.runAppleScript = { script, _, _ in
            if script.contains("service type = SMS") { smsAttempted = true }
            return ("", nil)
        }
        IMessageSender.lookupOutgoingStatus = { _, _ in
            IMessageIntegration.OutgoingStatus(state: .rejected, rowID: 100, error: 22, isSent: false, isDelivered: false)
        }
        // Use an in-process file so the path validates if the validation
        // layer were ever (incorrectly) skipped — we want the test to
        // exercise the SMS-refusal branch specifically.
        let tmp = NSTemporaryDirectory() + "apple-tools-imsg-test-\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let result = IMessageSender.send(to: "+15551234567", text: "hi", attachments: [tmp])
        XCTAssertTrue(result.isError, "send with attachments + SMS-only recipient should fail cleanly")
        XCTAssertEqual(result.transport, "iMessage", "should report iMessage, not SMS")
        XCTAssertFalse(smsAttempted, "must not run SMS AppleScript when attachments are present")
        XCTAssertTrue(result.message.contains("SMS"),
            "error should mention SMS to explain why fallback didn't happen: \(result.message)")
    }

}

/// Minimal thread-safe counter for the serialization test.
private final class AtomicCounter {
    private let queue = DispatchQueue(label: "test.atomic-counter")
    private var _value: Int = 0

    var value: Int {
        queue.sync { _value }
    }

    @discardableResult
    func increment() -> Int {
        queue.sync {
            _value += 1
            return _value
        }
    }

    @discardableResult
    func decrement() -> Int {
        queue.sync {
            _value -= 1
            return _value
        }
    }

    func updateMax(_ candidate: Int) {
        queue.sync {
            if candidate > _value { _value = candidate }
        }
    }
}
