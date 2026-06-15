import AppKit
import Foundation

/// Shared iMessage/SMS send logic used by both IMessageTool (server→probe tool
/// invocations) and InboundHookManager (gateway round-trip replies).
///
/// ## Send serialization
///
/// All sends are funneled through a probe-wide serial queue (`sendQueue`) so
/// concurrent senders (inbound gateway replies, outbound tool sends, future
/// streaming blocks) don't issue overlapping `send` Apple Events to
/// Messages.app — overlapping sends can leave Messages in a bad state
/// regardless of how AppleScript is hosted.. (The queue
/// originally also guarded against `NSAppleScript` thread-unsafety; that
/// concern is moot now that AppleScript runs via subprocess `osascript` per
/// ADR-031, but the Messages.app concurrency concern remains.)
///
/// ## Delivery confirmation and probe-level blocking
///
/// AppleScript "send to buddy" returns as soon as Messages.app accepts the
/// message — it does NOT signal whether iMessage transmission succeeded. For
/// numbers not registered with iMessage, Messages silently writes the failure
/// (`error != 0`) to chat.db a few moments later. To surface that to the caller,
/// `send` polls chat.db after AppleScript returns and waits for a terminal
/// state (sent or rejected) up to `deliveryDeadline` seconds (issue).
///
/// The poll runs on the calling thread. The probe's tool dispatcher
/// (`ProbeClient.toolQueue`) is itself a serial queue, so a stuck-pending
/// iMessage send can stall *all* probe tool invocations — calendar, photos,
/// other sends — for up to `deliveryDeadline` seconds. This is an explicit
/// tradeoff: the alternative (return immediately, push delivery results
/// asynchronously via the inbox) loses same-turn confirmation in `wait()`.
/// Successful and rejected sends typically resolve in 1–3s, so the worst-case
/// blocking only kicks in when iMessage itself is stuck.
public enum IMessageSender {

    /// Result of a send attempt.
    public struct SendResult {
        public let transport: String   // "iMessage" or "SMS"
        public let isError: Bool
        public let message: String     // status description or error message
    }

    /// Serial queue that every AppleScript invocation flows through. Ensures
    /// two concurrent senders (e.g. Phone A + Phone B messaging the assistant at
    /// the same time) don't race on NSAppleScript.
    private static let sendQueue = DispatchQueue(label: "com.apple-tools.imessage-send")

    /// How long to wait for chat.db to reflect a terminal iMessage delivery
    /// state (`sent` or `rejected`) before giving up and reporting unverified.
    /// Tuned for typical observed latency of 1–3s; 8s keeps tail cases
    /// covered without blocking the probe's serial toolQueue too long.
    static var deliveryDeadline: TimeInterval = 8.0

    /// SMS via iPhone relay can take longer than iMessage — the Mac hands
    /// the message to the iPhone, which then transmits over cellular and
    /// reports back. 15s gives the relay enough breathing room while still
    /// bounding worst-case toolQueue blocking.
    static var smsDeliveryDeadline: TimeInterval = 15.0

    /// How often to re-query chat.db while waiting. Cheap read.
    static var deliveryPollInterval: TimeInterval = 0.25

    /// Injectable for tests so we don't have to hit chat.db. Returns the
    /// most recent outgoing-message status to `handle` newer than
    /// `sinceROWID`. Default delegates to `IMessageIntegration`.
    static var lookupOutgoingStatus: (_ handle: String, _ sinceROWID: Int64) -> IMessageIntegration.OutgoingStatus
        = IMessageIntegration.outgoingStatus(toHandle:sinceROWID:)

    /// Injectable for tests. Returns the current max ROWID before a send.
    static var currentMaxROWID: () -> Int64 = IMessageIntegration.currentMaxROWID

    /// Injectable for tests. Reports whether a 1:1 chat thread already
    /// exists for the recipient handle. `nil` means the lookup itself
    /// failed (FDA denied, schema drift, …) — sendLocked treats nil as
    /// "use legacy path" to avoid creating duplicate chats on an
    /// unreliable signal. See IMessageIntegration.hasOneToOneChatForHandle
    /// and issue.
    static var chatExistsForHandle: (_ handle: String) -> Bool?
        = IMessageIntegration.hasOneToOneChatForHandle

    /// Block for up to `deadline` polling chat.db for a terminal state.
    /// Returns as soon as `.sent` or `.rejected` is observed; on timeout
    /// returns the last observation (typically `.pending` or `.noRow`).
    /// Caller decides how to surface each state.
    static func awaitDelivery(toHandle handle: String, sinceROWID: Int64, deadline: TimeInterval) -> IMessageIntegration.OutgoingStatus {
        let start = Date()
        var last = IMessageIntegration.OutgoingStatus(state: .noRow, rowID: 0, error: 0, isSent: false, isDelivered: false)
        while Date().timeIntervalSince(start) < deadline {
            last = lookupOutgoingStatus(handle, sinceROWID)
            if last.state == .sent || last.state == .rejected {
                return last
            }
            Thread.sleep(forTimeInterval: deliveryPollInterval)
        }
        return last
    }

    /// Send a message via iMessage, falling back to SMS for phone numbers.
    /// `attachments` is an optional list of absolute file paths sent after the
    /// text body. SMS fallback is refused when attachments are non-empty —
    /// MMS via iPhone-relay is unreliable for arbitrary files and silently
    /// dropping attachments would be worse than a clean error.
    public static func send(to recipient: String, text: String, attachments: [String] = []) -> SendResult {
        // Messages.app renders Markdown as raw syntax and exposes no API to send
        // attributed text, so flatten the caller's Markdown to plain text before it
        // reaches any send path (1:1, group, SMS fallback all funnel through here).
        let plainText = IMessageMarkdown.toPlainText(text)
        let enqueue = CFAbsoluteTimeGetCurrent()
        return sendQueue.sync {
            let waited = CFAbsoluteTimeGetCurrent() - enqueue
            if waited > 0.5 {
                Log.info("imessage send: waited \(String(format: "%.1f", waited))s for serial queue")
            }
            return sendLocked(to: recipient, text: plainText, attachments: attachments)
        }
    }

    // MARK: - Private

    /// Returns true when `recipient` looks like a Messages.app chat identifier
    /// rather than a phone number or email. Group chats use identifiers like
    /// `iMessage;+;chat123@icloud.com` or `chat12345678`.
    static func isGroupChatID(_ recipient: String) -> Bool {
        return recipient.hasPrefix("iMessage;") || recipient.hasPrefix("chat")
    }

    /// Body of `send` that runs inside the serial queue. All AppleScript
    /// execution, including the SMS fallback path, happens here.
    private static func sendLocked(to recipient: String, text: String, attachments: [String]) -> SendResult {
        if isGroupChatID(recipient) {
            return sendToChat(recipient: recipient, text: text, attachments: attachments)
        }

        let escapedRecipient = escapeForAppleScript(recipient)

        // Payload text flows through the environment, not the AppleScript
        // source. `do shell script "printenv X"` returns the value as UTF-8
        // — unlike `system attribute` which decodes env bytes as MacRoman
        // and mangles em-dash / emoji / non-Latin chars. The var name is a
        // compile-time literal, so there's no shell-injection surface.
        // Eliminates the class of bug behind.
        let env = ["APPLE_TOOLS_IMSG_TEXT": text]

        // First-contact routing: `send to buddy` silently no-ops
        // when Messages.app has no prior 1:1 thread for the recipient. If
        // chat.db confirms no thread exists, switch to a chat-creating
        // script that addresses sends to the new chat object. A nil
        // lookup result (chat.db unreadable) falls back to the legacy
        // buddy-send path rather than risk duplicating a thread that
        // already exists.
        let useFirstContact: Bool
        switch chatExistsForHandle(recipient) {
        case .some(false):
            Log.info("imessage send: no prior chat for recipient; using first-contact AppleScript (recipient: \(recipient.prefix(8))...)")
            useFirstContact = true
        case .some(true):
            useFirstContact = false
        case .none:
            Log.info("imessage send: chat.db existence check failed; using legacy buddy-send path (recipient: \(recipient.prefix(8))...)")
            useFirstContact = false
        }

        let attachmentTarget = useFirstContact ? "targetChat" : "targetBuddy"
        let attachmentClauses = attachmentScriptClauses(attachments, target: attachmentTarget)
        let chatCreationLine = useFirstContact
            ? "set targetChat to make new text chat with properties {participants:{targetBuddy}}\n            "
            : ""
        let sendTarget = useFirstContact ? "targetChat" : "targetBuddy"
        let imessageScript = """
        set theText to do shell script "printenv APPLE_TOOLS_IMSG_TEXT"
        log "PHASE: prepare"
        tell application "Messages"
            set iMessageService to first service whose service type = iMessage
            set targetBuddy to buddy "\(escapedRecipient)" of iMessageService
            \(chatCreationLine)log "PHASE: pre-commit"
            send theText to \(sendTarget)
            \(attachmentClauses)
            log "PHASE: committed"
        end tell
        """

        // Snapshot ROWID before AppleScript so the post-send poll only
        // sees the row this send creates.
        let cursor = currentMaxROWID()

        // Post-verify hook (ADR-032): if AppleScript is SIGKILLed during the
        // in-flight `send` Apple Event, this lets the runner upgrade
        // outcome_unknown → success when chat.db shows the message landed.
        let verifyHook = makeVerifyHook(handle: recipient, sinceROWID: cursor)

        Log.info("imessage send: starting AppleScript (recipient: \(recipient.prefix(8))...)")
        let asStart = CFAbsoluteTimeGetCurrent()
        let (_, imErr) = runAppleScript(imessageScript, env, verifyHook)
        let asElapsed = CFAbsoluteTimeGetCurrent() - asStart
        Log.info("imessage send: AppleScript completed in \(String(format: "%.1f", asElapsed))s (error: \(imErr != nil))")
        if let imErr = imErr {
            // -1728: buddy not found on iMessage. Try SMS fallback for phone numbers.
            // (Modern macOS rarely returns this — Messages typically accepts the
            // send and reports failure asynchronously via chat.db. The chat.db
            // poll path in `confirmDelivery` is the primary fallback trigger.)
            if imErr.contains("-1728") && looksLikePhoneNumber(recipient) {
                if !attachments.isEmpty {
                    return SendResult(transport: "iMessage", isError: true,
                        message: "recipient \(recipient) is not on iMessage and SMS does not support arbitrary file attachments. Resend text-only, or attach the file to an iMessage-eligible recipient.")
                }
                return sendViaSMS(recipient: recipient, escapedRecipient: escapedRecipient, text: text, iMessageError: -1728)
            }
            if imErr.contains("-1728") {
                return SendResult(transport: "iMessage", isError: true,
                    message: "recipient not found on iMessage: \(recipient) — email addresses require iMessage")
            }
            if imErr.contains("-1703") || imErr.contains("-1708") {
                return SendResult(transport: "iMessage", isError: true,
                    message: "no iMessage service available — ensure Messages.app is signed in to iMessage")
            }
            return SendResult(transport: "iMessage", isError: true,
                message: "failed to send iMessage: \(imErr)")
        }

        return confirmDelivery(recipient: recipient, escapedRecipient: escapedRecipient, text: text, attachments: attachments, sinceROWID: cursor)
    }

    /// Build the AppleScript fragment that sends each attachment after the
    /// text. Messages.app processes `send` asynchronously and can drop
    /// files when invocations loop tightly — a small `delay` between each
    /// gives the file-import pipeline time to settle.
    private static func attachmentScriptClauses(_ attachments: [String], target: String = "targetBuddy") -> String {
        return attachments.map { path -> String in
            let escaped = escapeForAppleScript(path)
            return "send POSIX file \"\(escaped)\" to \(target)\n        delay 0.2"
        }.joined(separator: "\n        ")
    }

    /// After AppleScript reports success, poll chat.db to confirm the
    /// message actually transmitted. On `.rejected` with a "recipient not
    /// registered" code (e.g. error=22), automatically retry via SMS for
    /// phone-number recipients. Translates each terminal/deadline state
    /// into a SendResult with a specific user-facing message and a
    /// structured log line. Issue.
    private static func confirmDelivery(recipient: String, escapedRecipient: String, text: String, attachments: [String], sinceROWID: Int64) -> SendResult {
        let pollStart = CFAbsoluteTimeGetCurrent()
        let status = awaitDelivery(toHandle: recipient, sinceROWID: sinceROWID, deadline: deliveryDeadline)
        let pollElapsed = CFAbsoluteTimeGetCurrent() - pollStart

        switch status.state {
        case .sent:
            Log.info("imessage send: chat.db confirmed sent rowid=\(status.rowID) recipient=\(recipient.prefix(8))... is_delivered=\(status.isDelivered) poll=\(String(format: "%.1f", pollElapsed))s")
            return SendResult(transport: "iMessage", isError: false,
                message: "Message queued via iMessage.")

        case .rejected:
            // error=22 is the common code for "recipient not registered with iMessage"
            // on modern macOS. Other codes exist; surface the number so we can map them
            // empirically over time.
            let mapping = errorCodeDescription(status.error)
            Log.error("imessage send: chat.db reported delivery failure rowid=\(status.rowID) recipient=\(recipient) error=\(status.error) (\(mapping)) is_sent=\(status.isSent) is_delivered=\(status.isDelivered) poll=\(String(format: "%.1f", pollElapsed))s")

            // Try SMS fallback when iMessage rejected the recipient and the
            // rejection is the recipient-not-registered kind. Other error
            // codes (network, service unavailable) won't be helped by SMS.
            if shouldAttemptSMSFallback(errorCode: status.error, recipient: recipient) {
                if !attachments.isEmpty {
                    Log.info("imessage send: refusing SMS fallback because \(attachments.count) attachment(s) present (recipient: \(recipient.prefix(8))...)")
                    return SendResult(transport: "iMessage", isError: true,
                        message: "iMessage delivery failed (error \(status.error) — recipient not registered) and SMS does not support arbitrary file attachments. Resend text-only, or pick an iMessage-eligible recipient.")
                }
                Log.info("imessage send: attempting SMS fallback after iMessage error \(status.error) (recipient: \(recipient.prefix(8))...)")
                return sendViaSMS(recipient: recipient, escapedRecipient: escapedRecipient, text: text, iMessageError: status.error)
            }

            return SendResult(transport: "iMessage", isError: true,
                message: "iMessage delivery failed: Messages.app reported error \(status.error) (\(mapping)) for \(recipient). SMS fallback not attempted (recipient not eligible or error not retriable).")

        case .pending:
            Log.error("imessage send: chat.db row still pending after \(String(format: "%.1f", pollElapsed))s rowid=\(status.rowID) recipient=\(recipient) is_sent=0 error=0 — Messages.app accepted the send but did not transmit")
            return SendResult(transport: "iMessage", isError: true,
                message: "iMessage send not confirmed: Messages.app accepted the message but did not transmit it within \(Int(deliveryDeadline))s. This usually means Messages.app is offline, signed out of iMessage, or has a network problem on the probe host. Check Messages.app.")

        case .noRow:
            Log.error("imessage send: no chat.db row appeared within \(String(format: "%.1f", pollElapsed))s recipient=\(recipient) sinceROWID=\(sinceROWID) — AppleScript reported success but Messages.app did not record a message")
            return SendResult(transport: "iMessage", isError: true,
                message: "iMessage send unverified: AppleScript reported success but no message row appeared in chat.db within \(Int(deliveryDeadline))s. Messages.app may not have processed the send — check for a stuck draft.")
        }
    }

    /// Best-effort human-readable description for chat.db `error` codes
    /// observed in practice. Returns "unknown" for codes we haven't mapped
    /// yet — log them and add as we learn.
    private static func errorCodeDescription(_ code: Int) -> String {
        switch code {
        case 22:
            return "recipient not registered with iMessage"
        default:
            return "unknown"
        }
    }

    /// Whether to retry via SMS after an iMessage rejection. Currently only
    /// triggers for error=22 (recipient not on iMessage). Other failure
    /// codes (network, service unavailable, etc.) are not addressable by
    /// switching transports and would just waste an SMS attempt.
    /// Recipient must look like a phone number (SMS doesn't support email).
    private static func shouldAttemptSMSFallback(errorCode: Int, recipient: String) -> Bool {
        guard errorCode == 22 else { return false }
        return looksLikePhoneNumber(recipient)
    }

    private static func looksLikePhoneNumber(_ s: String) -> Bool {
        return s.hasPrefix("+") || s.allSatisfy { $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " }
    }

    /// Send to a group chat using `chat id` addressing. Looks up the guid
    /// from chat.db because Messages.app requires the full guid format
    /// (e.g. "any;+;chat123..."), not the raw chat_identifier.
    private static func sendToChat(recipient: String, text: String, attachments: [String]) -> SendResult {
        guard let guid = IMessageIntegration.chatGUID(forIdentifier: recipient) else {
            return SendResult(transport: "iMessage", isError: true,
                message: "group chat not found: \(recipient) — verify the chat_id from a recent conversation list")
        }

        let escapedGUID = escapeForAppleScript(guid)
        let env = ["APPLE_TOOLS_IMSG_TEXT": text]
        let attachmentClauses = attachments.map { path -> String in
            let escaped = escapeForAppleScript(path)
            return "send POSIX file \"\(escaped)\" to targetChat\n        delay 0.2"
        }.joined(separator: "\n        ")

        // applescript-runner: no-verifier — chat.db's group-message join goes
        // through chat_message_join, not the handle table that makeVerifyHook
        // keys on. No viable post-verify for groups until a chat-keyed lookup
        // exists. Same scope decision as the post-send poll skip below.
        let script = """
        set theText to do shell script "printenv APPLE_TOOLS_IMSG_TEXT"
        log "PHASE: prepare"
        tell application "Messages"
            set targetChat to chat id "\(escapedGUID)"
            log "PHASE: pre-commit"
            send theText to targetChat
            \(attachmentClauses)
            log "PHASE: committed"
        end tell
        """
        Log.info("imessage send: starting group chat AppleScript (chat: \(recipient.prefix(12))...)")
        let asStart = CFAbsoluteTimeGetCurrent()
        let (_, err) = runAppleScript(script, env, nil)
        let asElapsed = CFAbsoluteTimeGetCurrent() - asStart
        Log.info("imessage send: group chat AppleScript completed in \(String(format: "%.1f", asElapsed))s (error: \(err != nil))")
        if let err = err {
            if err.contains("-1728") {
                return SendResult(transport: "iMessage", isError: true,
                    message: "group chat not found in Messages.app: \(recipient)")
            }
            return SendResult(transport: "iMessage", isError: true,
                message: "failed to send to group chat: \(err)")
        }

        // Group chats: chat.db rows are joined via chat_message_join, not the
        // handle table. The current `outgoingStatus` lookup keys on a single
        // recipient handle, which doesn't apply here. Skip post-send polling
        // for groups for now — partial confirmation in groups is harder and
        // out of scope for issue.
        return SendResult(transport: "iMessage", isError: false,
            message: "Message queued to group chat via iMessage.")
    }

    /// Run the SMS fallback AppleScript and confirm transmission via
    /// chat.db. `iMessageError` is the upstream iMessage chat.db error
    /// code (typically 22), passed through so combined-failure messages
    /// can name both transports' errors.
    ///
    /// SMS via iPhone relay can take longer to confirm than iMessage,
    /// so the poll uses `smsDeliveryDeadline` (longer) instead of the
    /// iMessage deadline.
    private static func sendViaSMS(recipient: String, escapedRecipient: String, text: String, iMessageError: Int) -> SendResult {
        let env = ["APPLE_TOOLS_IMSG_TEXT": text]
        let smsScript = """
        set theText to do shell script "printenv APPLE_TOOLS_IMSG_TEXT"
        log "PHASE: prepare"
        tell application "Messages"
            set smsService to first service whose service type = SMS
            set targetBuddy to buddy "\(escapedRecipient)" of smsService
            log "PHASE: pre-commit"
            send theText to targetBuddy
            log "PHASE: committed"
        end tell
        """

        let cursor = currentMaxROWID()

        // SMS path: same handle keyed lookup as iMessage 1:1, with longer
        // verify window since iPhone-relay transmission is slower.
        let verifyHook = makeVerifyHook(handle: recipient, sinceROWID: cursor, deadline: 8.0)

        let smsStart = CFAbsoluteTimeGetCurrent()
        let (_, smsErr) = runAppleScript(smsScript, env, verifyHook)
        let smsElapsed = CFAbsoluteTimeGetCurrent() - smsStart
        Log.info("imessage send: SMS AppleScript completed in \(String(format: "%.1f", smsElapsed))s (error: \(smsErr != nil))")
        if let smsErr = smsErr {
            if smsErr.contains("-1703") || smsErr.contains("-1708") {
                return SendResult(transport: "SMS", isError: true,
                    message: "iMessage failed (error \(iMessageError)), and SMS service is not available — ensure iPhone SMS relay is set up in Messages preferences.")
            }
            return SendResult(transport: "SMS", isError: true,
                message: "iMessage failed (error \(iMessageError)), SMS AppleScript also failed: \(smsErr)")
        }

        // Poll chat.db for the SMS row. Same logic as iMessage but with
        // a longer deadline since iPhone-relay transmission is slower.
        let pollStart = CFAbsoluteTimeGetCurrent()
        let status = awaitDelivery(toHandle: recipient, sinceROWID: cursor, deadline: smsDeliveryDeadline)
        let pollElapsed = CFAbsoluteTimeGetCurrent() - pollStart

        switch status.state {
        case .sent:
            Log.info("imessage send: SMS chat.db confirmed sent rowid=\(status.rowID) recipient=\(recipient.prefix(8))... poll=\(String(format: "%.1f", pollElapsed))s")
            return SendResult(transport: "SMS", isError: false,
                message: "Recipient not on iMessage. Message sent via SMS.")

        case .rejected:
            let mapping = errorCodeDescription(status.error)
            Log.error("imessage send: SMS fallback rejected rowid=\(status.rowID) recipient=\(recipient) sms_error=\(status.error) (\(mapping)) imessage_error=\(iMessageError) poll=\(String(format: "%.1f", pollElapsed))s")
            return SendResult(transport: "SMS", isError: true,
                message: "iMessage failed (error \(iMessageError)) and SMS fallback also failed: error \(status.error) (\(mapping)) for \(recipient).")

        case .pending:
            Log.error("imessage send: SMS row still pending after \(String(format: "%.1f", pollElapsed))s rowid=\(status.rowID) recipient=\(recipient) — iPhone relay did not confirm transmission")
            return SendResult(transport: "SMS", isError: true,
                message: "iMessage failed (error \(iMessageError)). SMS handed off to iPhone relay but did not confirm transmission within \(Int(smsDeliveryDeadline))s — iPhone may be offline or SMS relay may be misconfigured.")

        case .noRow:
            Log.error("imessage send: no SMS chat.db row appeared within \(String(format: "%.1f", pollElapsed))s recipient=\(recipient) sinceROWID=\(cursor)")
            return SendResult(transport: "SMS", isError: true,
                message: "iMessage failed (error \(iMessageError)). SMS AppleScript reported success but no row appeared in chat.db within \(Int(smsDeliveryDeadline))s.")
        }
    }

    /// AppleScript runner. Overridable by tests to avoid hitting
    /// Messages.app and to assert serialization behavior.
    ///
    /// The optional `verifyHook` is the ADR-032 post-verify hook supplied
    /// for SIGKILL-during-pre-commit recovery: when the AppleScript host
    /// dies mid-dispatch, the runner consults the hook (chat.db poll for
    /// the row that *would* have been written) to disambiguate outcome_unknown.
    /// Test stubs that don't exercise the verifier ignore this arg.
    static var runAppleScript: (_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) = defaultRunAppleScript

    static func defaultRunAppleScript(_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) {
        return AppleScriptRunner.runLegacy(source: source, tool: "imessage", environment: environment, onOutcomeUnknown: verifyHook)
    }

    /// Build a post-verify hook for an in-flight iMessage/SMS send. The hook
    /// polls chat.db for a row newer than `sinceROWID` keyed on `handle`,
    /// up to its own deadline. ADR-032 reference implementation.
    ///
    /// Mapping (`OutgoingStatus.state` → `VerifyResult`):
    /// - `.sent`      → `.confirmed(id: <rowid>)` — message was transmitted; the
    ///                  caller's outcome_unknown upgrades to .success.
    /// - `.rejected`  → `.absent` — Messages.app saw it but iMessage said no
    ///                  (e.g., recipient not registered). The artifact wasn't
    ///                  actually delivered; safe to surface as failure.
    /// - `.pending`,
    ///   `.noRow`     → `.inconclusive` — leave the runner's outcome_unknown
    ///                  alone; the caller's existing confirmDelivery flow
    ///                  will provide a more specific error if it eventually
    ///                  resolves to one of the above.
    static func makeVerifyHook(handle: String, sinceROWID: Int64, deadline: TimeInterval = 5.0) -> () -> AppleScriptRunner.VerifyResult {
        return {
            let status = awaitDelivery(toHandle: handle, sinceROWID: sinceROWID, deadline: deadline)
            switch status.state {
            case .sent:     return .confirmed(id: String(status.rowID))
            case .rejected: return .absent
            case .pending, .noRow: return .inconclusive
            }
        }
    }

    static func escapeForAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
