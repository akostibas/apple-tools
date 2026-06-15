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
    /// account). Caller is responsible for sorting/merging across accounts;
    /// we trim to `limit` after the merge.
    public static func recentInboxMessages(limit: Int) throws -> [InboxEntry] {
        let script = """
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
                        set mDate to date received of m
                        set mRead to read status of m
                        set mAttCount to count of mail attachments of m
                        set output to output & mID & "\\t" & mSubject & "\\t" & mFrom & "\\t" & mDate & "\\t" & mRead & "\\t" & mAttCount & linefeed
                    end repeat
                end try
            end repeat
            return output
        end tell
        """

        let (out, err) = runAppleScript(script, [:], nil)
        if let err = err { throw EmailError.scriptFailed(err) }

        var messages: [InboxEntry] = []
        for line in out.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            let attCount = (parts.count >= 6) ? (Int(parts[5]) ?? 0) : 0
            messages.append(InboxEntry(
                id: parts[0],
                subject: parts[1],
                from: parts[2],
                date: parts[3],
                read: parts[4] == "true",
                attachmentCount: attCount
            ))
        }

        if messages.count > limit {
            messages = Array(messages.prefix(limit))
        }
        return messages
    }

    // MARK: - Read

    public static func readMessageViaAppleScript(id: String) throws -> MessageRead {
        let env = ["APPLE_TOOLS_EMAIL_MSG_ID": id]
        let script = """
        set theMsgID to do shell script "printenv APPLE_TOOLS_EMAIL_MSG_ID"
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
                        set mDate to date received of m
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
                                set attachStr to attachStr & attName & "\\t" & attMIME & "\\t" & attSize
                            end try
                        end repeat
                        return mID & "\\t" & mSubject & "\\t" & mFrom & "\\t" & toStr & "\\t" & ccStr & "\\t" & mDate & "\\t" & (count of atts) & "\\n" & mContent & "\\n---ATTACHMENTS---\\n" & attachStr
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

        // Split body from attachment section.
        let sections = out.components(separatedBy: "\n---ATTACHMENTS---\n")
        let mainPart = sections[0]
        let attachmentPart = sections.count > 1 ? sections[1] : ""

        // Header line: id \t subject \t from \t to \t cc \t date \t attachCount
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

        let parts = headerLine.components(separatedBy: "\t")
        guard parts.count >= 7 else {
            throw EmailError.parseFailure("failed to parse message data")
        }

        let attachCount = Int(parts[6]) ?? 0
        var attachments: [AttachmentMeta] = []
        if attachCount > 0 && !attachmentPart.isEmpty {
            for line in attachmentPart.components(separatedBy: "\n") where !line.isEmpty {
                let attParts = line.components(separatedBy: "\t")
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
            date: parts[5],
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
        let env = ["APPLE_TOOLS_EMAIL_MSG_ID": id]
        let script = """
        set theMsgID to do shell script "printenv APPLE_TOOLS_EMAIL_MSG_ID"
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
                                set output to output & attName & "\\t" & attMIME & "\\t" & attSize
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
            let parts = line.components(separatedBy: "\t")
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
            "APPLE_TOOLS_EMAIL_MSG_ID": id,
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
        var env: [String: String] = [
            "APPLE_TOOLS_EMAIL_TO": to,
            "APPLE_TOOLS_EMAIL_SUBJECT": subject,
            "APPLE_TOOLS_EMAIL_BODY": body,
        ]

        var ccBinding = ""
        var ccClause = ""
        if let cc = cc, !cc.isEmpty {
            env["APPLE_TOOLS_EMAIL_CC"] = cc
            ccBinding = """
            set theCC to do shell script "printenv APPLE_TOOLS_EMAIL_CC"
            """
            ccClause = """
            make new cc recipient at end of cc recipients with properties {address:theCC}
            """
        }

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
        set theBody to do shell script "printenv APPLE_TOOLS_EMAIL_BODY"
        \(ccBinding)
        log "PHASE: prepare"
        tell application "Mail"
            log "PHASE: pre-commit"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            tell newMsg
                make new to recipient at end of to recipients with properties {address:theTo}
                \(ccClause)
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

    // MARK: - AppleScript runner

    /// Test seam: swappable runner that accepts an env dict for payload values.
    /// Default routes through `AppleScriptRunner.runLegacy` with tool="email".
    public static var runAppleScript: (_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) = defaultRunAppleScript

    public static func defaultRunAppleScript(_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) {
        return AppleScriptRunner.runLegacy(source: source, tool: "email", environment: environment, onOutcomeUnknown: verifyHook)
    }

}
