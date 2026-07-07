import Foundation

/// Shared Apple Mail integration. AppleScript-driven Mail.app access lives
/// here; SQLite-driven Envelope Index search and .emlx parsing live in
/// `EmailSearch` and `EmailMessage`.
///
/// Consumers: EmailTool (LLM tool wrapper).
///
/// Design: stateless enum with static methods. AppleScript snippets and
/// parsing are encapsulated; callers receive typed values.
public enum EmailIntegration {

    // MARK: - Types

    public enum EmailError: Error, CustomStringConvertible {
        case scriptFailed(String)
        case notFound
        case noAttachments
        case attachmentNotFound(name: String)
        case attachmentSaveFailed(String)
        case parseFailure(String)

        public var description: String {
            switch self {
            case .scriptFailed(let msg): return msg
            case .notFound: return "message not found"
            case .noAttachments: return "message has no attachments"
            case .attachmentNotFound(let name): return "attachment '\(name)' not found on message"
            case .attachmentSaveFailed(let msg): return "failed to save attachment: \(msg)"
            case .parseFailure(let msg): return msg
            }
        }
    }

    public struct InboxEntry {
        public let id: String
        public let subject: String
        public let from: String
        public let date: String
        public let read: Bool
        public let attachmentCount: Int
    }

    public struct AttachmentMeta {
        public let filename: String
        public let mimeType: String
        public let size: Int
    }

    public struct MessageRead {
        public let id: String
        public let subject: String
        public let from: String
        public let to: String
        public let cc: String
        public let date: String
        public let body: String
        public let attachmentCount: Int
        public let attachments: [AttachmentMeta]
    }

    /// Outcome of `createReply`: the threaded reply Mail built for us, echoed
    /// back so the tool can tell the agent who it's addressed to and under
    /// what subject (both derived by Mail from the original, not the caller).
    public struct ReplyResult {
        public let subject: String
        public let to: String
    }

    // MARK: - AppleScript text protocol

    /// Field / section delimiters for the tab-free AppleScript text protocol.
    /// ASCII control characters (Unit Separator 0x1F, Record Separator 0x1E)
    /// that never occur in mail subjects, sender/display names, or message
    /// bodies. The old `\t` field delimiter and `---ATTACHMENTS---` section
    /// marker COULD appear in that text — a tab in a subject shifted every
    /// later field, and a body line equal to the marker truncated the body
    /// (issue #36). The AppleScript emits these via `character id 31/30`.
    static let fieldSep = "\u{1F}"
    static let sectionSep = "\u{1E}"

    // MARK: - Preflight

    public static func preflight() -> (ok: Bool, message: String) {
        let script = """
        tell application "Mail"
            count of accounts
        end tell
        """
        let (_, err) = runAppleScript(script, [:], nil)
        if let err = err {
            return (false, "mail access denied: \(err)")
        }
        return (true, "mail access granted")
    }

    // MARK: - Inbox

    /// Fetch recent messages from each account's INBOX (newest-first per
    /// account), then merge-sort across accounts by date (newest first) and
    /// trim to `limit`. Fetching up to `limit` per account guarantees the
    /// global newest `limit` are contained in the union before trimming.
    public static func recentInboxMessages(limit: Int) throws -> [InboxEntry] {
        let script = """
        \(DateFormatting.appleScriptComponentsHandler)
        set fieldSep to (character id 31)
        tell application "Mail"
            set output to ""
            set allAccounts to every account
            repeat with acct in allAccounts
                try
                    set inboxBox to mailbox "INBOX" of acct
                    set msgs to messages of inboxBox
                    set msgCount to count of msgs
                    set fetchCount to \(limit)
                    if fetchCount > msgCount then set fetchCount to msgCount
                    -- Messages are newest-first in Mail.app
                    repeat with i from 1 to fetchCount
                        set m to item i of msgs
                        set mID to message id of m
                        set mSubject to subject of m
                        set mFrom to sender of m
                        set mDate to my atDateComponents(date received of m)
                        set mRead to read status of m
                        set mAttCount to count of mail attachments of m
                        set output to output & mID & fieldSep & mSubject & fieldSep & mFrom & fieldSep & mDate & fieldSep & mRead & fieldSep & mAttCount & linefeed
                    end repeat
                end try
            end repeat
            return output
        end tell
        """

        let (out, err) = runAppleScript(script, [:], nil)
        if let err = err { throw EmailError.scriptFailed(err) }

        return mergeInboxRows(out, limit: limit)
    }

    /// Parse the tab-delimited inbox rows the AppleScript emits (grouped by
    /// account, newest-first within each account), merge-sort the union
    /// newest-first by date, and trim to `limit`.
    ///
    /// Extracted for testability: the AppleScript can't run under XCTest, but
    /// the merge/sort/trim — where the "only the first account's mail is
    /// visible" bug lived — is pure and does have coverage.
    static func mergeInboxRows(_ out: String, limit: Int) -> [InboxEntry] {
        var messages: [InboxEntry] = []
        for line in out.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: fieldSep)
            guard parts.count >= 5 else { continue }
            let attCount = (parts.count >= 6) ? (Int(parts[5]) ?? 0) : 0
            messages.append(InboxEntry(
                id: parts[0],
                subject: parts[1],
                from: parts[2],
                date: DateFormatting.isoFromAppleScriptComponents(parts[3]),
                read: parts[4] == "true",
                attachmentCount: attCount
            ))
        }

        // Merge across accounts: the AppleScript emits messages grouped by
        // account, so sort the union newest-first by parsed date before
        // trimming — otherwise account 2's mail is invisible whenever account
        // 1 already fills `limit`. Entries whose date failed to parse sort
        // last rather than jumping to the top.
        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        messages.sort { a, b in
            let da = isoParser.date(from: a.date) ?? .distantPast
            let db = isoParser.date(from: b.date) ?? .distantPast
            return da > db
        }

        if messages.count > limit {
            messages = Array(messages.prefix(limit))
        }
        return messages
    }

    // MARK: - Read

    /// Strip the surrounding angle brackets from an RFC Message-ID before it
    /// goes into `whose message id is …` comparisons. Mail's AppleScript
    /// `message id` property is *bare* (`abc@host`), but IDs reach these
    /// fallbacks in both forms — `search` surfaces the bracketed header value
    /// (`<abc@host>`), and LLMs echo IDs back either way. Without stripping,
    /// a bracketed ID never matches the bare property → spurious "not found".
    /// Mirrors `EmailSearch.resolveMessageID`'s bracket-insensitive lookup.
    static func bareMessageID(_ id: String) -> String {
        return id.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    public static func readMessageViaAppleScript(id: String) throws -> MessageRead {
        let env = ["APPLE_TOOLS_EMAIL_MSG_ID": bareMessageID(id)]
        let script = """
        set theMsgID to do shell script "printenv APPLE_TOOLS_EMAIL_MSG_ID"
        \(DateFormatting.appleScriptComponentsHandler)
        set fieldSep to (character id 31)
        set sectionSep to (character id 30)
        tell application "Mail"
            set allAccounts to every account
            repeat with acct in allAccounts
                try
                    set inboxBox to mailbox "INBOX" of acct
                    set msgs to (every message of inboxBox whose message id is theMsgID)
                    if (count of msgs) > 0 then
                        set m to item 1 of msgs
                        set mID to message id of m
                        set mSubject to subject of m
                        set mFrom to sender of m
                        set mTo to address of every to recipient of m
                        set mCC to address of every cc recipient of m
                        set mDate to my atDateComponents(date received of m)
                        set mContent to content of m
                        -- Join to/cc lists with comma
                        set toStr to ""
                        repeat with addr in mTo
                            if toStr is not "" then set toStr to toStr & ", "
                            set toStr to toStr & addr
                        end repeat
                        set ccStr to ""
                        repeat with addr in mCC
                            if ccStr is not "" then set ccStr to ccStr & ", "
                            set ccStr to ccStr & addr
                        end repeat
                        -- Collect attachment metadata
                        set attachStr to ""
                        set atts to every mail attachment of m
                        repeat with att in atts
                            try
                                set attName to name of att
                                set attMIME to MIME type of att
                                set attSize to file size of att
                                if attachStr is not "" then set attachStr to attachStr & linefeed
                                set attachStr to attachStr & attName & fieldSep & attMIME & fieldSep & attSize
                            end try
                        end repeat
                        return mID & fieldSep & mSubject & fieldSep & mFrom & fieldSep & toStr & fieldSep & ccStr & fieldSep & mDate & fieldSep & (count of atts) & "\\n" & mContent & sectionSep & attachStr
                    end if
                end try
            end repeat
            return "NOT_FOUND"
        end tell
        """

        let (out, err) = runAppleScript(script, env, nil)
        if let err = err { throw EmailError.scriptFailed(err) }

        if out == "NOT_FOUND" {
            throw EmailError.notFound
        }

        // Split body from attachment section (a control char that can't occur
        // in the body — see fieldSep/sectionSep).
        let sections = out.components(separatedBy: sectionSep)
        let mainPart = sections[0]
        let attachmentPart = sections.count > 1 ? sections[1] : ""

        // Header line: id <FS> subject <FS> from <FS> to <FS> cc <FS> date <FS> attachCount
        // Body follows after the first newline.
        let firstNewline = mainPart.range(of: "\n")
        let headerLine: String
        let bodyText: String
        if let nl = firstNewline {
            headerLine = String(mainPart[mainPart.startIndex..<nl.lowerBound])
            bodyText = String(mainPart[nl.upperBound...])
        } else {
            headerLine = mainPart
            bodyText = ""
        }

        let parts = headerLine.components(separatedBy: fieldSep)
        guard parts.count >= 7 else {
            throw EmailError.parseFailure("failed to parse message data")
        }

        let attachCount = Int(parts[6]) ?? 0
        var attachments: [AttachmentMeta] = []
        if attachCount > 0 && !attachmentPart.isEmpty {
            for line in attachmentPart.components(separatedBy: "\n") where !line.isEmpty {
                let attParts = line.components(separatedBy: fieldSep)
                guard !attParts.isEmpty else { continue }
                let mime = attParts.count >= 2 ? attParts[1] : ""
                let size = attParts.count >= 3 ? (Int(attParts[2]) ?? 0) : 0
                attachments.append(AttachmentMeta(filename: attParts[0], mimeType: mime, size: size))
            }
        }

        return MessageRead(
            id: parts[0],
            subject: parts[1],
            from: parts[2],
            to: parts[3],
            cc: parts[4],
            date: DateFormatting.isoFromAppleScriptComponents(parts[5]),
            body: bodyText,
            attachmentCount: attachCount,
            attachments: attachments
        )
    }

    // MARK: - Attachments

    /// List attachments on a message via AppleScript (INBOX only).
    /// Throws `.notFound` if the message isn't in any inbox, `.noAttachments`
    /// if it has none.
    public static func listAttachmentsViaAppleScript(id: String) throws -> [AttachmentMeta] {
        let env = ["APPLE_TOOLS_EMAIL_MSG_ID": bareMessageID(id)]
        let script = """
        set theMsgID to do shell script "printenv APPLE_TOOLS_EMAIL_MSG_ID"
        set fieldSep to (character id 31)
        tell application "Mail"
            set allAccounts to every account
            repeat with acct in allAccounts
                try
                    set inboxBox to mailbox "INBOX" of acct
                    set msgs to (every message of inboxBox whose message id is theMsgID)
                    if (count of msgs) > 0 then
                        set m to item 1 of msgs
                        set atts to every mail attachment of m
                        set attCount to count of atts
                        if attCount = 0 then return "NO_ATTACHMENTS"
                        set output to ""
                        repeat with att in atts
                            try
                                set attName to name of att
                                set attMIME to MIME type of att
                                set attSize to file size of att
                                if output is not "" then set output to output & linefeed
                                set output to output & attName & fieldSep & attMIME & fieldSep & attSize
                            end try
                        end repeat
                        return output
                    end if
                end try
            end repeat
            return "NOT_FOUND"
        end tell
        """

        let (out, err) = runAppleScript(script, env, nil)
        if let err = err { throw EmailError.scriptFailed(err) }

        if out == "NOT_FOUND" { throw EmailError.notFound }
        if out == "NO_ATTACHMENTS" { throw EmailError.noAttachments }

        var attachments: [AttachmentMeta] = []
        for line in out.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: fieldSep)
            guard !parts.isEmpty, !parts[0].isEmpty else { continue }
            let mime = parts.count >= 2 ? parts[1] : ""
            let size = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
            attachments.append(AttachmentMeta(filename: parts[0], mimeType: mime, size: size))
        }

        if attachments.isEmpty {
            throw EmailError.parseFailure("failed to parse attachment metadata")
        }
        return attachments
    }

    /// Save the named attachment to a temp file via AppleScript, then read
    /// and return its contents. The temp directory is cleaned up before
    /// returning.
    ///
    /// applescript-runner: read-only — the AppleScript `save in` writes to a
    /// transient temp dir owned by this function and unlinked on return; no
    /// user-visible Mail state is mutated.
    public static func saveAttachmentViaAppleScript(id: String, filename: String) throws -> Data {
        let tmpDir = NSTemporaryDirectory() + "apple-tools-email-att-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let env = [
            "APPLE_TOOLS_EMAIL_MSG_ID": bareMessageID(id),
            "APPLE_TOOLS_EMAIL_ATT_NAME": filename,
            "APPLE_TOOLS_EMAIL_TMP_DIR": tmpDir,
        ]

        let saveScript = """
        set theMsgID to do shell script "printenv APPLE_TOOLS_EMAIL_MSG_ID"
        set theAttName to do shell script "printenv APPLE_TOOLS_EMAIL_ATT_NAME"
        set theTmpDir to do shell script "printenv APPLE_TOOLS_EMAIL_TMP_DIR"
        tell application "Mail"
            set allAccounts to every account
            repeat with acct in allAccounts
                try
                    set inboxBox to mailbox "INBOX" of acct
                    set msgs to (every message of inboxBox whose message id is theMsgID)
                    if (count of msgs) > 0 then
                        set m to item 1 of msgs
                        set atts to every mail attachment of m
                        repeat with att in atts
                            if name of att is theAttName then
                                set savePath to POSIX file (theTmpDir & "/" & name of att)
                                save att in savePath
                                return "OK"
                            end if
                        end repeat
                        return "ATT_NOT_FOUND"
                    end if
                end try
            end repeat
            return "NOT_FOUND"
        end tell
        """

        let (out, err) = runAppleScript(saveScript, env, nil)
        if let err = err { throw EmailError.attachmentSaveFailed(err) }
        if out == "NOT_FOUND" { throw EmailError.notFound }
        if out == "ATT_NOT_FOUND" { throw EmailError.attachmentNotFound(name: filename) }

        let savedPath = tmpDir + "/" + filename
        guard let data = FileManager.default.contents(atPath: savedPath) else {
            throw EmailError.parseFailure("attachment saved but file not found at expected path")
        }
        return data
    }

    // MARK: - Draft

    public static func createDraft(to: String, subject: String, body: String, cc: String?, attachments: [String] = []) throws {
        let ccList = (cc?.isEmpty == false) ? [cc!] : []
        try createOutgoingMessage(to: to, subject: subject, body: body, cc: ccList, attachments: attachments)
    }

    /// Create a visible outgoing message (draft) via `make new outgoing message`
    /// — the reliable path that sets the body at creation time. Shared by
    /// `createDraft` and `createReply`. `cc` is a list so reply-all can pass
    /// many. When `htmlBody` is non-nil the message is created with `html
    /// content` (rich — used by replies for a real `<blockquote>` quote);
    /// otherwise `content` is set to the plain `body`.
    static func createOutgoingMessage(
        to: String, subject: String, body: String, cc: [String], attachments: [String],
        htmlBody: String? = nil
    ) throws {
        var env: [String: String] = [
            "APPLE_TOOLS_EMAIL_TO": to,
            "APPLE_TOOLS_EMAIL_SUBJECT": subject,
        ]

        // Body: HTML (rich) or plain, routed through env either way. `html
        // content` at creation time renders as rich text in the compose window
        // (verified on macOS 26); the plain `content` path is unchanged.
        let createClause: String
        if let htmlBody = htmlBody {
            env["APPLE_TOOLS_EMAIL_HTML"] = htmlBody
            createClause = """
            set theHTML to do shell script "printenv APPLE_TOOLS_EMAIL_HTML"
            set newMsg to make new outgoing message with properties {subject:theSubject, visible:true}
            set html content of newMsg to theHTML
            """
        } else {
            env["APPLE_TOOLS_EMAIL_BODY"] = body
            createClause = """
            set theBody to do shell script "printenv APPLE_TOOLS_EMAIL_BODY"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            """
        }

        // One numbered env key per cc so addresses stay out of the script
        // source (same pattern as attachments below).
        let ccClauses = cc.enumerated().map { idx, addr -> String in
            let key = "APPLE_TOOLS_EMAIL_CC_\(idx)"
            env[key] = addr
            return """
            set theCC\(idx) to do shell script "printenv \(key)"
            make new cc recipient at end of cc recipients with properties {address:theCC\(idx)}
            """
        }.joined(separator: "\n")

        // Mail processes `make new attachment` asynchronously and can drop
        // files when invocations are looped tightly — a small delay between
        // each gives the file-import pipeline time to settle. One env key
        // per attachment (numbered) so each path stays out of the script
        // source; the script binds each to a local before use.
        let attachmentClauses = attachments.enumerated().map { idx, path -> String in
            let key = "APPLE_TOOLS_EMAIL_ATTACH_\(idx)"
            env[key] = path
            return """
            set theAttPath\(idx) to do shell script "printenv \(key)"
            tell content of newMsg to make new attachment with properties {file name:POSIX file theAttPath\(idx)} at after last paragraph
            delay 0.1
            """
        }.joined(separator: "\n")

        // PHASE markers (see AppleScriptRunner) bound the cancel-safe window.
        // The `committed id=` marker is emitted only after attachments have
        // been added — a kill mid-attachment leaves an incomplete draft and
        // should classify as `outcome_unknown`, not `success`.
        let script = """
        set theTo to do shell script "printenv APPLE_TOOLS_EMAIL_TO"
        set theSubject to do shell script "printenv APPLE_TOOLS_EMAIL_SUBJECT"
        log "PHASE: prepare"
        tell application "Mail"
            log "PHASE: pre-commit"
            \(createClause)
            tell newMsg
                make new to recipient at end of to recipients with properties {address:theTo}
                \(ccClauses)
            end tell
            \(attachmentClauses)
            set draftID to id of newMsg as string
            log "PHASE: committed id=" & draftID
            return draftID
        end tell
        """

        // Post-verify hook (ADR-032 /): snapshot Envelope Index max ROWID
        // before the AppleScript so a SIGKILL-during-pre-commit kill can be
        // disambiguated by polling for the matching Drafts row. Only ever
        // upgrades outcome_unknown → success (see MailDraftVerifier docs on
        // why .absent is not returned).
        let snapshot = MailDraftVerifier.snapshotMaxRowID()
        let verifyHook = MailDraftVerifier.makeVerifyHook(
            recipient: to,
            subject: subject,
            sinceROWID: snapshot
        )
        let (_, err) = runAppleScript(script, env, verifyHook)
        if let err = err { throw EmailError.scriptFailed(err) }
    }

    // MARK: - Reply

    /// Draft a reply to the INBOX message with `id`, as a fresh outgoing message
    /// (the same reliable `make new outgoing message` path `createDraft` uses).
    ///
    /// We deliberately do NOT use Mail's native `reply` command: on Exchange /
    /// Outlook accounts the reply is composed as HTML, and AppleScript's plain
    /// `content` property is a black hole for it — it reads empty and writes are
    /// silently discarded, so the caller's text never lands (apple-tools live
    /// finding, Shannon-Assistant #884). Setting `content` at *creation* time,
    /// by contrast, works on every account type.
    ///
    /// So we read the original ourselves and construct the reply as HTML: a
    /// "Re:" subject, the sender as recipient, and the caller's text above an
    /// attribution (`On <date>, <sender> wrote:`) and the original inside a
    /// `<blockquote>` — which Mail renders as a real indented quote bar via the
    /// `html content` property (works at creation time where plain `content` on
    /// a native reply does not).
    ///
    /// TRADE-OFF: because this is a new message, it carries no In-Reply-To /
    /// References headers — the recipient's client threads it by the "Re:"
    /// subject, not by conversation id. Faithful threading isn't reachable
    /// through AppleScript once we can't use `reply`. `replyAll` adds the
    /// original To+Cc recipients as Cc; `cc` adds further Cc on top.
    ///
    /// Reads the original via INBOX AppleScript, so (like `reply` before it)
    /// this only works for messages currently in an inbox. Throws `.notFound`
    /// if no INBOX message matches.
    public static func createReply(
        id: String, body: String, replyAll: Bool, cc: String?, attachments: [String] = []
    ) throws -> ReplyResult {
        let orig = try readMessageViaAppleScript(id: id)

        let toAddress = extractEmailAddress(orig.from)

        // "Re:" subject, but don't stack "Re: Re:".
        let trimmedSubject = orig.subject.trimmingCharacters(in: .whitespaces)
        let replySubject = trimmedSubject.lowercased().hasPrefix("re:")
            ? trimmedSubject : "Re: \(trimmedSubject)"

        // Cc: for reply-all, every original To+Cc address except the sender (who
        // is already the To) and empties; then any explicit --cc on top. Deduped
        // case-insensitively, order preserved.
        var ccAddresses: [String] = []
        if replyAll {
            for field in [orig.to, orig.cc] {
                for addr in splitAddresses(field) {
                    let clean = extractEmailAddress(addr)
                    if !clean.isEmpty { ccAddresses.append(clean) }
                }
            }
        }
        if let cc = cc, !cc.isEmpty {
            for addr in splitAddresses(cc) { ccAddresses.append(extractEmailAddress(addr)) }
        }
        ccAddresses = dedupeAddresses(ccAddresses, excluding: toAddress)

        // Build the reply as HTML: the caller's text, an attribution line, then
        // the original inside a <blockquote> — which Mail renders as a real
        // indented quote bar (verified on macOS 26), the block-indent #884
        // wanted, without the literal ">" look. Everything is HTML-escaped;
        // newlines become <br>.
        let attribution = "On \(orig.date), \(orig.from) wrote:"
        let htmlBody = """
        <div>\(htmlInline(body))</div>
        <br>
        <div>\(htmlEscape(attribution))</div>
        <blockquote type="cite">\(htmlInline(orig.body))</blockquote>
        """

        try createOutgoingMessage(
            to: toAddress, subject: replySubject, body: body,
            cc: ccAddresses, attachments: attachments, htmlBody: htmlBody)

        return ReplyResult(subject: replySubject, to: toAddress)
    }

    /// Escape the five characters that are unsafe in HTML text/attribute
    /// context. Order matters: `&` first so we don't double-escape.
    static func htmlEscape(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&#39;")
        return r
    }

    /// HTML-escape and turn newlines into `<br>` so plain multi-line text keeps
    /// its line breaks when placed in an HTML body.
    static func htmlInline(_ s: String) -> String {
        return htmlEscape(s).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Extract a bare email address from a `Name <addr>` / `addr` string. Falls
    /// back to the trimmed input when there's no angle-bracket form.
    static func extractEmailAddress(_ s: String) -> String {
        if let open = s.range(of: "<"), let close = s.range(of: ">"),
           open.upperBound <= close.lowerBound {
            return String(s[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Split a comma-separated recipient list, dropping empties.
    static func splitAddresses(_ s: String) -> [String] {
        return s.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Case-insensitively dedupe addresses, dropping any equal to `excluding`.
    static func dedupeAddresses(_ addresses: [String], excluding: String) -> [String] {
        var seen = Set([excluding.lowercased()])
        var out: [String] = []
        for a in addresses where !a.isEmpty {
            let key = a.lowercased()
            if seen.insert(key).inserted { out.append(a) }
        }
        return out
    }

    // MARK: - AppleScript runner

    /// Test seam: swappable runner that accepts an env dict for payload values.
    /// Default routes through `AppleScriptRunner.runLegacy` with tool="email".
    public static var runAppleScript: (_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) = defaultRunAppleScript

    public static func defaultRunAppleScript(_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) {
        return AppleScriptRunner.runLegacy(source: source, tool: "email", environment: environment, onOutcomeUnknown: verifyHook)
    }

}
