import AppKit
import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Callback type for sending async notifications to the proxy inbox.
public typealias NotifyCallback = (_ message: String, _ agent: String?) -> Void

public struct IMessageTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "imessage",
        description: "iMessage and SMS. Actions: 'recent' (list conversations with recent activity), 'stats' (rank conversations by message volume with sent/received split over an optional --since window), 'send' (send a message; supports file attachments by absolute path), 'read' (messages from a conversation), 'search' (find messages by text content), 'fetch_attachment' (retrieve an attachment file from a message). Phone numbers and emails are auto-resolved to Contacts names on output (added as 'contact_name' alongside the raw handle when a match exists; 'last_message_from_name' resolves the last-message sender). When a handle is a phone number, a canonical E.164 form is added as 'phone_e164' alongside the raw handle (the raw chat_id is never rewritten); emails and short codes get no such field. Likely-spam detection: 'recent', 'read', and 'stats' entries carry 'is_likely_spam' and 'is_shortcode' booleans so callers don't have to know the magic suffix. A sender is flagged when its chat id carries the (undocumented) SMS-filtering suffix '(smsfp)' (filtered promotional) or '(smsft)' (filtered transactional), OR it is a 5-6 digit marketing short code — UNLESS it resolves to a Contacts name (a real person is never flagged). The raw chat_id (suffix included) is preserved. Use --exclude-spam (alias --humans-only) on 'recent'/'stats' to drop flagged senders; off by default (never silently dropped).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "recent, stats, send, read, search, or fetch_attachment"),
                "to": PropertySchema(type_: "string", description: "Recipient phone number, email, or chat_id for group chats (for send)",
                    summary: "Recipient phone, email, or group chat_id", actions: ["send"]),
                "text": PropertySchema(type_: "string", description: "Message text to send (for send)",
                    summary: "Message text", actions: ["send"]),
                "attachments": PropertySchema(
                    type_: "array",
                    description: "Absolute file paths to attach to a send. '~' is expanded. Each ≤100MB; max 10. iMessage transport only — sending to an SMS-only recipient with attachments will fail.",
                    items: ItemsSchema(type_: "string"),
                    summary: "Absolute file paths to attach (≤100MB, max 10)", actions: ["send"]
                ),
                "chat": PropertySchema(type_: "string", description: "Phone number, email, group name, or chat_id (for read; optional filter for search)",
                    summary: "Phone, email, group name, or chat_id (filters results on search)", actions: ["read", "search"]),
                "query": PropertySchema(type_: "string", description: "Text to search for (for search)",
                    summary: "Text to search for", actions: ["search"]),
                "limit": PropertySchema(type_: "integer", description: "Max results (default 5 for recent, 10 for read and stats, 20 for search)",
                    summary: "Max results (defaults vary by action)", actions: ["recent", "stats", "read", "search"]),
                "before": PropertySchema(type_: "string", description: "Return messages/conversations before this time (for read, search). Accepts an ISO 8601 timestamp, a date (2026-07-03), or the opaque next_before cursor from a prior read page. An unparseable value is rejected, not ignored.",
                    summary: "Page older than this time or a next_before cursor", actions: ["read", "search"]),
                "since": PropertySchema(type_: "string", description: "Only include activity/messages after this time (for recent, stats, search). Accepts an ISO 8601 timestamp or a date (2026-07-03). An unparseable value is rejected, not ignored.",
                    summary: "Only activity after this time (ISO 8601 or date)", actions: ["recent", "stats", "search"]),
                "message_id": PropertySchema(type_: "integer", description: "Message ROWID from read/search results (for fetch_attachment)",
                    summary: "Message ROWID from read/search results", actions: ["fetch_attachment"]),
                "filename": PropertySchema(type_: "string", description: "Attachment filename to select when a message has multiple attachments (for fetch_attachment, optional)",
                    summary: "Which attachment, when a message has several", actions: ["fetch_attachment"]),
                "exclude_spam": PropertySchema(type_: "boolean", description: "Drop likely-spam senders — SMS-filtered (smsfp)/(smsft) chats and 5-6 digit marketing short codes — keeping real contacts. Default false; never drops by default (for recent, stats)",
                    summary: "Drop likely-spam senders (alias --humans_only)", actions: ["recent", "stats"]),
                "humans_only": PropertySchema(type_: "boolean", description: "Alias for exclude_spam — keep only conversations with real people (for recent, stats)",
                    summary: "Alias for --exclude_spam", actions: ["recent", "stats"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Send and search iMessage/SMS conversations.",
        actions: [
            ActionHelp(name: "recent", summary: "List conversations with recent activity",
                example: "apple-tools imessage recent [--limit <n>] [--since <date>] [--exclude_spam]"),
            ActionHelp(name: "stats", summary: "Rank conversations by message volume, with a sent/received split",
                example: "apple-tools imessage stats [--limit <n>] [--since <date>] [--exclude_spam]"),
            ActionHelp(name: "read", summary: "Read messages from a conversation",
                example: "apple-tools imessage read --chat <id> [--limit <n>] [--before <cursor>]", required: ["chat"]),
            ActionHelp(name: "search", summary: "Find messages by text content",
                example: "apple-tools imessage search --query <text> [--chat <id>] [--since <date>] [--before <cursor>] [--limit <n>]", required: ["query"]),
            ActionHelp(name: "send", summary: "Send a message — supports file attachments",
                example: "apple-tools imessage send --to <recipient> --text <msg> [--attachments <path>]", required: ["to", "text"]),
            ActionHelp(name: "fetch_attachment", summary: "Retrieve an attachment file from a message",
                example: "apple-tools imessage fetch_attachment --message_id <id> [--filename <name>]", required: ["message_id"]),
        ]
    )

    public let host: ToolHost

    /// Optional callback for sending async notifications (e.g. delivery failure).
    /// Set after init once the ProbeClient is ready.
    public var notify: NotifyCallback?

    /// Resolver from message handles (phone/email) to Contacts display names.
    /// Defaults to a batched Contacts lookup; injectable so output-annotation
    /// logic can be unit-tested against fixture data without the live address
    /// book. Best-effort: an empty map leaves raw handles untouched.
    public var nameResolver: ([String]) -> [String: String] = ContactsIntegration.resolveNames(forIdentifiers:)

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "recent":           .read,
        "stats":            .read,
        "read":             .read,
        "search":           .read,
        "fetch_attachment": .read,
        "send":             .readWrite,
    ])

    public init(host: ToolHost) {
        self.host = host
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "recent":
            let limit = params?["limit"]?.value as? Int ?? 5
            let since = params?["since"]?.value as? String
            return recent(limit: limit, since: since, excludeSpam: excludeSpamFlag(params))
        case "stats":
            let limit = params?["limit"]?.value as? Int ?? 10
            let since = params?["since"]?.value as? String
            return stats(limit: limit, since: since, excludeSpam: excludeSpamFlag(params))
        case "send":
            guard let to = params?["to"]?.value as? String, !to.isEmpty else {
                return ("missing required parameter: to", true)
            }
            guard let text = params?["text"]?.value as? String, !text.isEmpty else {
                return ("missing required parameter: text", true)
            }
            let attachments = (params?["attachments"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
            return send(to: to, text: text, attachments: attachments)
        case "read":
            guard let chat = params?["chat"]?.value as? String, !chat.isEmpty else {
                return ("missing required parameter: chat", true)
            }
            let limit = params?["limit"]?.value as? Int ?? 10
            let before = params?["before"]?.value as? String
            return read(chat: chat, limit: limit, before: before)
        case "search":
            guard let query = params?["query"]?.value as? String, !query.isEmpty else {
                return ("missing required parameter: query", true)
            }
            let chat = params?["chat"]?.value as? String
            let limit = params?["limit"]?.value as? Int ?? 20
            let since = params?["since"]?.value as? String
            let before = params?["before"]?.value as? String
            return search(query: query, chat: chat, limit: limit, since: since, before: before)
        case "fetch_attachment":
            guard let messageID = params?["message_id"]?.value as? Int else {
                return ("missing required parameter: message_id (use a message_id from read or search results)", true)
            }
            let filename = params?["filename"]?.value as? String
            return fetchAttachment(messageID: messageID, filename: filename)
        default:
            return ("unknown action: \(action) (use recent, stats, send, read, search, or fetch_attachment)", true)
        }
    }

    /// True if either `--exclude-spam` or its `--humans-only` alias is set.
    /// Mirrors EmailTool's two-flag opt-in so "show me real people" works the
    /// same in both tools.
    private func excludeSpamFlag(_ params: [String: AnyCodable]?) -> Bool {
        return (params?["exclude_spam"]?.value as? Bool) == true
            || (params?["humans_only"]?.value as? Bool) == true
    }

    /// Uniform tool error for an unparseable `since`/`before` value. Returning
    /// an error (rather than silently dropping the filter) stops an agent from
    /// paginating page 1 forever when it passes a malformed cursor (issue #23).
    static func dateFilterError(field: String, value: String) -> String {
        return "invalid '\(field)' value: '\(value)' — use ISO 8601 (e.g. 2026-07-03T12:00:00Z), a date (2026-07-03), or a next_before cursor from a prior page"
    }

    // MARK: - Preflight

    public func preflight() -> (ok: Bool, message: String) {
        return IMessageIntegration.preflight()
    }

    // MARK: - Send

    private func send(to recipient: String, text: String, attachments: [String]) -> (String, Bool) {
        let (resolved, attachErr) = resolveAttachments(attachments)
        if let attachErr = attachErr { return (attachErr, true) }

        // Snapshot the max ROWID before the send so the async delivery check
        // only ever inspects the row THIS send creates — not a concurrent
        // send's row to the same recipient (issue #35).
        let sinceROWID = IMessageIntegration.currentMaxROWID()
        let result = IMessageIntegration.send(to: recipient, text: text, attachments: resolved)
        if result.isError {
            return (result.message, true)
        }

        // Send was accepted. Schedule async delivery check.
        scheduleDeliveryCheck(recipient: recipient, sinceROWID: sinceROWID)

        var response: [String: Any] = [
            "status": "sending",
            "transport": result.transport,
            "to": recipient,
            "length": text.count,
            "note": result.message,
        ]
        if !resolved.isEmpty {
            response["attachments"] = resolved
        }
        return (IMessageIntegration.jsonEncode(response), false)
    }

    /// Validate attachment paths: expand `~`, confirm each exists and is a
    /// regular file under the size cap. Returns the absolute paths to hand
    /// to AppleScript, or a user-facing error string. Mirrors EmailTool's
    /// resolveAttachments but with iMessage's 100MB ceiling.
    private func resolveAttachments(_ raw: [String]) -> ([String], String?) {
        if raw.isEmpty { return ([], nil) }
        if raw.count > Self.maxAttachmentCount {
            return ([], "too many attachments: \(raw.count) (max \(Self.maxAttachmentCount))")
        }

        var resolved: [String] = []
        resolved.reserveCapacity(raw.count)
        let fm = FileManager.default

        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return ([], "attachment path is empty")
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: expanded, isDirectory: &isDir)
            if !exists {
                return ([], "attachment not found or unreadable: \(expanded) (if the file is in a protected folder, grant this tool Full Disk Access in System Settings)")
            }
            if isDir.boolValue {
                return ([], "attachment is a directory, not a file: \(expanded)")
            }
            let attrs = try? fm.attributesOfItem(atPath: expanded)
            if let size = (attrs?[.size] as? NSNumber)?.int64Value, size > Self.maxAttachmentBytes {
                let mb = Double(size) / 1_048_576.0
                return ([], String(format: "attachment exceeds %dMB limit: %@ (%.1fMB)", Self.maxAttachmentBytes / 1_048_576, expanded, mb))
            }
            resolved.append(expanded)
        }
        return (resolved, nil)
    }

    private static let maxAttachmentCount = 10
    private static let maxAttachmentBytes: Int64 = 100 * 1_048_576

    /// Check chat.db after a delay to surface a genuine send failure via the
    /// async notify channel. Scoped to the row created after `sinceROWID` so a
    /// concurrent send to the same recipient can't be misattributed to this one
    /// (issue #35). Only a non-zero `error` column is reported: `is_delivered = 0`
    /// a few seconds after send merely means no delivery receipt yet (recipient's
    /// device asleep, read-receipts off, network lag) — NOT a failure — so we no
    /// longer prompt a duplicate SMS on it.
    private func scheduleDeliveryCheck(recipient: String, sinceROWID: Int64) {
        guard notify != nil else { return }
        Log.info("Delivery check: scheduling for \(recipient) in 4s")

        DispatchQueue.global().asyncAfter(deadline: .now() + 4.0) { [self] in
            let recipientMatch = "(\(IMessageIntegration.handleMatchClause(column: "c.chat_identifier", handle: recipient)) OR \(IMessageIntegration.handleMatchClause(column: "h.id", handle: recipient)))"

            let sql = """
                SELECT m.is_delivered, m.is_sent, m.error, m.service
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                JOIN chat c ON cmj.chat_id = c.ROWID
                WHERE m.is_from_me = 1
                  AND m.ROWID > \(sinceROWID)
                  AND \(recipientMatch)
                ORDER BY m.ROWID DESC
                LIMIT 1
                """

            let (rows, err) = IMessageIntegration.queryChatDB(sql)
            if err != nil || rows.isEmpty { return }

            let row = rows[0]
            guard row.count >= 4 else { return }

            let errorCode = Int(row[2]) ?? 0
            let service = row[3]

            if errorCode != 0 {
                Log.info("Delivery check: message to \(recipient) failed with error \(errorCode)")
                notify?("Failed to send message to \(recipient): error code \(errorCode). The message was not delivered.", nil)
                return
            }

            Log.info("Delivery check: message to \(recipient) recorded (service: \(service), error: 0) — no delivery receipt yet is not treated as a failure")
        }
    }

    // MARK: - Recent

    private func recent(limit: Int, since: String?, excludeSpam: Bool) -> (String, Bool) {
        var sinceFilter = ""
        if let since = since {
            guard let nanos = IMessageIntegration.parseDateFilterToAppleNanos(since) else {
                return (Self.dateFilterError(field: "since", value: since), true)
            }
            sinceFilter = "HAVING MAX(m.date) > \(nanos)"
        }

        // Over-fetch when we'll post-filter spam so the caller still gets up to
        // `limit` human conversations (mirrors EmailSearch's oversample).
        let fetchLimit = excludeSpam ? max(limit * 10, limit) : limit
        let sql = """
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.style,
                   MAX(m.date) AS last_date,
                   SUM(CASE WHEN m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 THEN 1 ELSE 0 END) AS unread
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            GROUP BY c.ROWID
            \(sinceFilter)
            ORDER BY last_date DESC
            LIMIT \(fetchLimit)
            """

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let rawConversations = rows.map { row -> [String: Any] in
            recentConversationFromRow(row)
        }

        // Auto-resolve phone numbers / emails to Contacts names on output.
        let names = nameResolver(identifiers(inConversations: rawConversations))
        var conversations = annotateConversations(rawConversations, names: names)
        conversations = applySpamFilter(conversations, excludeSpam: excludeSpam, limit: limit)

        let response: [String: Any] = [
            "count": conversations.count,
            "conversations": conversations,
        ]
        return (IMessageIntegration.jsonEncode(response), false)
    }

    /// Opt-in spam drop shared by `recent`/`stats`: when `excludeSpam` is set,
    /// remove entries flagged `is_likely_spam`, then trim to `limit`. When off,
    /// just trims to `limit` (the over-fetch only applies when filtering).
    /// Never drops anything unless the caller opts in.
    private func applySpamFilter(_ entries: [[String: Any]], excludeSpam: Bool, limit: Int) -> [[String: Any]] {
        guard excludeSpam else { return entries }
        let kept = entries.filter { ($0["is_likely_spam"] as? Bool) != true }
        return Array(kept.prefix(limit))
    }

    /// Collect the message handles (phone/email) appearing in recent-conversation
    /// dicts so they can be resolved to contact names in one batch.
    func identifiers(inConversations convs: [[String: Any]]) -> [String] {
        var ids = Set<String>()
        for c in convs {
            // 1:1 chats carry the raw handle as chat_id and have no participants.
            if c["participants"] == nil, let chatID = c["chat_id"] as? String {
                ids.insert(chatID)
            }
            if let parts = c["participants"] as? [String] {
                parts.forEach { ids.insert($0) }
            }
            if let from = c["last_message_from"] as? String, from != "me", from != "unknown" {
                ids.insert(from)
            }
        }
        return Array(ids)
    }

    /// Annotate recent-conversation dicts with `contact_name` (1:1 chats),
    /// participant objects carrying `contact_name` (groups), and
    /// `last_message_from_name`. Pure: the caller supplies the resolved map, and
    /// the raw handles are always preserved alongside the names.
    func annotateConversations(_ convs: [[String: Any]], names: [String: String]) -> [[String: Any]] {
        return convs.map { conv in
            var c = conv
            let isGroup = c["participants"] != nil
            // 1:1 chats: resolve a contact name and flag likely-spam senders.
            // Groups are never bulk short-code senders, so skip the flags there.
            if !isGroup, let chatID = c["chat_id"] as? String {
                let name = names[chatID]
                if let name = name { c["contact_name"] = name }
                // Additive: canonical E.164 beside the raw chat_id when the
                // handle is a phone number. The raw chat_id is left exactly
                // as-is (incl. any (smsfp)/(smsft) suffix); the parser strips
                // such trailing junk for phone_e164. Emails/shortcodes get no
                // field. See #12.
                if let e164 = PhoneFormatting.e164(chatID) { c["phone_e164"] = e164 }
                c["is_likely_spam"] = BulkSenderClassifier.isLikelyBulkMessage(
                    chatID: chatID, hasContactName: name != nil)
                c["is_shortcode"] = BulkSenderClassifier.isShortcode(chatID)
            }
            if let parts = c["participants"] as? [String] {
                c["participants"] = parts.map { id -> [String: Any] in
                    var p: [String: Any] = ["identifier": id]
                    if let n = names[id] { p["contact_name"] = n }
                    if let e164 = PhoneFormatting.e164(id) { p["phone_e164"] = e164 }
                    return p
                }
            }
            if let from = c["last_message_from"] as? String, from != "me", let n = names[from] {
                c["last_message_from_name"] = n
            }
            return c
        }
    }

    /// Annotate message dicts with `contact_name` for resolved inbound senders.
    /// Pure; raw `from` handle is preserved.
    func annotateMessages(_ msgs: [[String: Any]], names: [String: String]) -> [[String: Any]] {
        return msgs.map { m in
            var msg = m
            if let from = m["from"] as? String, from != "me", from != "unknown" {
                let name = names[from]
                if let n = name { msg["contact_name"] = n }
                // Additive E.164 beside the raw `from` handle (see #12).
                if let e164 = PhoneFormatting.e164(from) { msg["phone_e164"] = e164 }
                // Flag inbound shortcode/SMS-filtered senders. The `from` handle
                // carries the same (smsfp)/(smsft) suffix as the chat id, so the
                // classifier sees it directly. Contact match short-circuits.
                msg["is_likely_spam"] = BulkSenderClassifier.isLikelyBulkMessage(
                    chatID: from, hasContactName: name != nil)
                msg["is_shortcode"] = BulkSenderClassifier.isShortcode(from)
            }
            // Group participants (search results) get the same object treatment.
            if let parts = m["participants"] as? [String] {
                msg["participants"] = parts.map { id -> [String: Any] in
                    var p: [String: Any] = ["identifier": id]
                    if let n = names[id] { p["contact_name"] = n }
                    if let e164 = PhoneFormatting.e164(id) { p["phone_e164"] = e164 }
                    return p
                }
            }
            return msg
        }
    }

    /// Collect inbound sender handles and group participants from message dicts.
    func identifiers(inMessages msgs: [[String: Any]]) -> [String] {
        var ids = Set<String>()
        for m in msgs {
            if let from = m["from"] as? String, from != "me", from != "unknown" {
                ids.insert(from)
            }
            if let parts = m["participants"] as? [String] {
                parts.forEach { ids.insert($0) }
            }
        }
        return Array(ids)
    }

    /// Build a conversation summary from a recent-query row.
    /// Columns: 0=ROWID, 1=chat_identifier, 2=display_name, 3=style, 4=last_date, 5=unread
    private func recentConversationFromRow(_ row: [String]) -> [String: Any] {
        let chatRowID = row[0]
        let chatIdentifier = row[1]
        let displayName = row[2]
        let style = row[3]
        let isGroup = style == "43"
        let unread = Int(row[5]) ?? 0

        var conv: [String: Any] = [
            "chat_id": chatIdentifier,
            "unread_count": unread,
        ]

        if !row[4].isEmpty {
            conv["last_message_date"] = IMessageIntegration.appleNanosToISO(row[4])
        }

        if isGroup {
            if !displayName.isEmpty {
                conv["chat_name"] = displayName
            }
            let participantSQL = """
                SELECT h.id FROM handle h
                JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = \(chatRowID)
                """
            let (pRows, _) = IMessageIntegration.queryChatDB(participantSQL)
            if !pRows.isEmpty {
                conv["participants"] = pRows.map { $0[0] }
            }
            if displayName.isEmpty {
                conv["chat_name"] = pRows.isEmpty ? "(unnamed group)" : pRows.map { $0[0] }.joined(separator: ", ")
            }
        } else {
            conv["chat_name"] = chatIdentifier
        }

        // Last message preview + sender.
        let previewSQL = """
            SELECT COALESCE(m.text, '') AS text, m.is_from_me,
                   COALESCE(h.id, '') AS handle,
                   CASE WHEN m.text IS NULL OR m.text = '' THEN hex(m.attributedBody) ELSE '' END AS body_hex
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = \(chatRowID)
            ORDER BY m.date DESC
            LIMIT 1
            """
        let (previewRows, _) = IMessageIntegration.queryChatDB(previewSQL)
        if let preview = previewRows.first {
            var text = preview[0]
            if text.isEmpty, preview.count > 3, !preview[3].isEmpty {
                text = IMessageFormatting.bodyText(hex: preview[3]) ?? ""
            }
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                conv["last_message_preview"] = text.count > 100 ? String(text.prefix(100)) + "…" : text
            }
            conv["last_message_from"] = preview[1] == "1" ? "me" : (preview[2].isEmpty ? "unknown" : preview[2])
        }

        return conv
    }

    // MARK: - Read

    private func read(chat: String, limit: Int, before: String?) -> (String, Bool) {
        let resolution = IMessageIntegration.resolveChat(chat)
        switch resolution {
        case .error(let msg):
            return (msg, true)
        case .ambiguous(let matches):
            return (IMessageIntegration.jsonEncode(["multiple_matches": matches, "hint": "Multiple chats match. Use chat_id to select one."]), false)
        case .resolved(let chatID):
            return readMessages(chatID: chatID, limit: limit, before: before)
        }
    }

    private func readMessages(chatID: Int, limit: Int, before: String?) -> (String, Bool) {
        var sql = """
            SELECT m.ROWID,
                   COALESCE(m.text, '') AS text,
                   m.is_from_me, m.service, m.is_delivered, m.is_sent,
                   COALESCE(h.id, '') AS handle,
                   m.date,
                   CASE WHEN m.text IS NULL OR m.text = '' THEN hex(m.attributedBody) ELSE '' END AS body_hex,
                   COALESCE(GROUP_CONCAT(COALESCE(a.mime_type, '') || ':' || COALESCE(a.transfer_name, ''), char(31)), '') AS attachments
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE cmj.chat_id = \(chatID)
              AND (m.text IS NOT NULL AND m.text != '' OR m.attributedBody IS NOT NULL OR a.ROWID IS NOT NULL)
            """

        if let before = before {
            guard let nanos = IMessageIntegration.parseDateFilterToAppleNanos(before) else {
                return (Self.dateFilterError(field: "before", value: before), true)
            }
            sql += "\n  AND m.date < \(nanos)"
        }

        sql += "\nGROUP BY m.ROWID\nORDER BY m.date DESC\nLIMIT \(limit + 1)"

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let hasMore = rows.count > limit
        let pageRows = hasMore ? Array(rows.prefix(limit)) : rows

        let rawMessages = pageRows.reversed().map { row -> [String: Any] in
            messageFromRow(row)
        }

        // Auto-resolve sender handles to Contacts names on output.
        let names = nameResolver(identifiers(inMessages: rawMessages))
        let messages = annotateMessages(rawMessages, names: names)

        var response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]
        if hasMore, let oldest = pageRows.last, oldest.count > 7, !oldest[7].isEmpty {
            // Emit the RAW apple-nanos of the boundary row as an opaque cursor.
            // A whole-second ISO string floors the timestamp, so the next page
            // (filtering `m.date < cursor`) would skip any same-second message
            // older than the boundary — a lossy cursor drops rapid-fire bursts
            // (issue #20). The raw nanos round-trip exactly through
            // parseDateFilterToAppleNanos.
            response["next_before"] = oldest[7]
        }
        return (IMessageIntegration.jsonEncode(response), false)
    }

    // MARK: - Search

    private func search(query: String, chat: String?, limit: Int, since: String?, before: String?) -> (String, Bool) {
        var extraFilters = ""
        if let chat = chat {
            let resolution = IMessageIntegration.resolveChat(chat)
            switch resolution {
            case .error(let msg):
                return (msg, true)
            case .ambiguous(let matches):
                return (IMessageIntegration.jsonEncode(["multiple_matches": matches, "hint": "Multiple chats match. Use chat_id to select one."]), false)
            case .resolved(let chatID):
                extraFilters += " AND cmj.chat_id = \(chatID)"
            }
        }
        if let since = since {
            guard let nanos = IMessageIntegration.parseDateFilterToAppleNanos(since) else {
                return (Self.dateFilterError(field: "since", value: since), true)
            }
            extraFilters += " AND m.date > \(nanos)"
        }
        if let before = before {
            guard let nanos = IMessageIntegration.parseDateFilterToAppleNanos(before) else {
                return (Self.dateFilterError(field: "before", value: before), true)
            }
            extraFilters += " AND m.date < \(nanos)"
        }

        // Match against DECODED message text, not the raw `m.text` column: on
        // modern macOS the body lives in the `attributedBody` blob and `m.text`
        // is empty for essentially every message, so a SQL `text LIKE` has
        // near-zero recall (apple-tools #52). Phase 1 scans a bounded window of
        // recent candidates (any row carrying text or a body blob), decodes each
        // empty-text row, and collects the ROWIDs whose decoded text contains
        // the query (case-insensitive literal substring — matching `read`/
        // `recent`, which also decode the blob). Phase 2 hydrates only the
        // matched rows with full attachment/chat/participant detail, so the
        // expensive per-row work is bounded by `limit`, not by the scan window.
        let scanCap = 20000
        // Only the chat filter references cmj; join it in just for that case.
        let candidateJoin = chat != nil ? "JOIN chat_message_join cmj ON m.ROWID = cmj.message_id" : ""
        let candidateSQL = """
            SELECT m.ROWID,
                   COALESCE(m.text, '') AS text,
                   CASE WHEN m.text IS NULL OR m.text = '' THEN hex(m.attributedBody) ELSE '' END AS body_hex
            FROM message m
            \(candidateJoin)
            WHERE (m.text IS NOT NULL AND m.text != '' OR m.attributedBody IS NOT NULL)\(extraFilters)
            GROUP BY m.ROWID
            ORDER BY m.date DESC
            LIMIT \(scanCap)
            """

        let (candidates, cErr) = IMessageIntegration.queryChatDB(candidateSQL)
        if let cErr = cErr { return (cErr, true) }

        var matchedIDs: [String] = []
        for row in candidates {
            let body = row[1].isEmpty ? (IMessageFormatting.bodyText(hex: row[2]) ?? "") : row[1]
            if body.range(of: query, options: [.caseInsensitive]) != nil {
                matchedIDs.append(row[0])
                if matchedIDs.count >= limit { break }
            }
        }
        // The scan window bounds worst-case decode cost; flag when it was hit so
        // consumers know older messages may not have been examined (issue #52).
        let scanTruncated = candidates.count >= scanCap

        if matchedIDs.isEmpty {
            var empty: [String: Any] = ["count": 0, "messages": [[String: Any]]()]
            if scanTruncated { empty["scan_truncated"] = true }
            return (IMessageIntegration.jsonEncode(empty), false)
        }

        let sql = """
            SELECT m.ROWID,
                   COALESCE(m.text, '') AS text,
                   m.is_from_me, m.service, m.is_delivered, m.is_sent,
                   COALESCE(h.id, '') AS handle,
                   m.date,
                   c.chat_identifier, c.display_name, c.style, c.ROWID AS chat_rowid,
                   CASE WHEN m.text IS NULL OR m.text = '' THEN hex(m.attributedBody) ELSE '' END AS body_hex,
                   COALESCE(GROUP_CONCAT(COALESCE(a.mime_type, '') || ':' || COALESCE(a.transfer_name, ''), char(31)), '') AS attachments
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE m.ROWID IN (\(matchedIDs.joined(separator: ", ")))
            GROUP BY m.ROWID
            ORDER BY m.date DESC
            """

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let rawMessages = rows.map { row -> [String: Any] in
            var msg = messageFromRow(row, bodyHexIndex: 12, attachmentsIndex: 13)
            if row.count > 8 {
                let chatRowID = row[11]
                let style = row[10]
                let isGroup = style == "43"
                if isGroup {
                    if !row[9].isEmpty {
                        msg["chat_name"] = row[9]
                    }
                    let participantSQL = """
                        SELECT h.id FROM handle h
                        JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                        WHERE chj.chat_id = \(chatRowID)
                        """
                    let (pRows, _) = IMessageIntegration.queryChatDB(participantSQL)
                    if !pRows.isEmpty {
                        msg["participants"] = pRows.map { $0[0] }
                    }
                } else {
                    msg["chat_name"] = row[8]
                }
                msg["chat_id"] = row[8]
            }
            return msg
        }

        // Auto-resolve sender handles and group participants to Contacts names.
        let names = nameResolver(identifiers(inMessages: rawMessages))
        let messages = annotateMessages(rawMessages, names: names)

        var response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]
        if scanTruncated { response["scan_truncated"] = true }
        return (IMessageIntegration.jsonEncode(response), false)
    }

    // MARK: - Stats

    /// Rank conversations by message volume, with a sent/received split, honoring
    /// an optional `--since` window. Sorted by message_count descending. 1:1
    /// chats are annotated with `contact_name` on output (see #8).
    private func stats(limit: Int, since: String?, excludeSpam: Bool) -> (String, Bool) {
        var sinceFilter = ""
        var sinceISO: String?
        if let since = since {
            guard let nanos = IMessageIntegration.parseDateFilterToAppleNanos(since) else {
                return (Self.dateFilterError(field: "since", value: since), true)
            }
            sinceFilter = "AND m.date > \(nanos)"
            sinceISO = IMessageIntegration.appleNanosToISO(String(nanos))
        }

        let fetchLimit = excludeSpam ? max(limit * 10, limit) : limit
        let sql = """
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.style,
                   COUNT(m.ROWID) AS message_count,
                   SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
                   SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS received,
                   MAX(m.date) AS last_date
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            WHERE m.item_type = 0 \(sinceFilter)
            GROUP BY c.ROWID
            ORDER BY message_count DESC
            LIMIT \(fetchLimit)
            """

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let rawChats = rows.map { statsChatFromRow($0) }
        let names = nameResolver(identifiers(inStats: rawChats))
        var chats = annotateStats(rawChats, names: names)
        chats = applySpamFilter(chats, excludeSpam: excludeSpam, limit: limit)

        var response: [String: Any] = [
            "count": chats.count,
            "chats": chats,
        ]
        if let sinceISO = sinceISO { response["since"] = sinceISO }
        return (IMessageIntegration.jsonEncode(response), false)
    }

    /// Shape a stats row into an output dict. Pure (no DB), so the count/split
    /// shaping is unit-testable with fixture rows.
    /// Columns: 0=ROWID, 1=chat_identifier, 2=display_name, 3=style,
    /// 4=message_count, 5=sent, 6=received, 7=last_date.
    func statsChatFromRow(_ row: [String]) -> [String: Any] {
        let chatRowID = row[0]
        let chatIdentifier = row[1]
        let displayName = row[2]
        let isGroup = row[3] == "43"

        var entry: [String: Any] = [
            "chat_id": chatIdentifier,
            "message_count": Int(row[4]) ?? 0,
            "sent": Int(row[5]) ?? 0,
            "received": Int(row[6]) ?? 0,
        ]
        if row.count > 7, !row[7].isEmpty {
            entry["last_message_date"] = IMessageIntegration.appleNanosToISO(row[7])
        }

        if isGroup {
            entry["chat_name"] = displayName.isEmpty ? "(unnamed group)" : displayName
            let participantSQL = """
                SELECT h.id FROM handle h
                JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = \(chatRowID)
                """
            let (pRows, _) = IMessageIntegration.queryChatDB(participantSQL)
            if !pRows.isEmpty {
                entry["participants"] = pRows.map { $0[0] }
            }
        } else {
            entry["chat_name"] = chatIdentifier
        }
        return entry
    }

    /// Collect handles from stats dicts for batched name resolution.
    func identifiers(inStats chats: [[String: Any]]) -> [String] {
        var ids = Set<String>()
        for c in chats {
            if c["participants"] == nil, let chatID = c["chat_id"] as? String {
                ids.insert(chatID)
            }
            if let parts = c["participants"] as? [String] {
                parts.forEach { ids.insert($0) }
            }
        }
        return Array(ids)
    }

    /// Annotate stats dicts with `contact_name` (1:1) and participant objects
    /// (groups). Pure; raw handles preserved.
    func annotateStats(_ chats: [[String: Any]], names: [String: String]) -> [[String: Any]] {
        return chats.map { chat in
            var c = chat
            let isGroup = c["participants"] != nil
            if !isGroup, let chatID = c["chat_id"] as? String {
                let name = names[chatID]
                if let name = name { c["contact_name"] = name }
                // Additive: canonical E.164 beside the raw chat_id when the
                // handle is a phone number. The raw chat_id is left exactly
                // as-is (incl. any (smsfp)/(smsft) suffix); the parser strips
                // such trailing junk for phone_e164. Emails/shortcodes get no
                // field. See #12.
                if let e164 = PhoneFormatting.e164(chatID) { c["phone_e164"] = e164 }
                c["is_likely_spam"] = BulkSenderClassifier.isLikelyBulkMessage(
                    chatID: chatID, hasContactName: name != nil)
                c["is_shortcode"] = BulkSenderClassifier.isShortcode(chatID)
            }
            if let parts = c["participants"] as? [String] {
                c["participants"] = parts.map { id -> [String: Any] in
                    var p: [String: Any] = ["identifier": id]
                    if let n = names[id] { p["contact_name"] = n }
                    if let e164 = PhoneFormatting.e164(id) { p["phone_e164"] = e164 }
                    return p
                }
            }
            return c
        }
    }

    // MARK: - Fetch Attachment

    private func fetchAttachment(messageID: Int, filename: String?) -> (String, Bool) {
        let (details, err) = IMessageIntegration.attachments(forMessageID: messageID)
        if let err = err { return (err, true) }

        if details.isEmpty {
            return ("no attachments found for message_id \(messageID)", true)
        }

        // Select the attachment: by filename if specified, otherwise the first one.
        let selected: IMessageIntegration.AttachmentDetail
        if let filename = filename {
            guard let match = details.first(where: { $0.transferName == filename }) else {
                let available = details.map { $0.transferName }.joined(separator: ", ")
                return ("no attachment named '\(filename)' on message \(messageID). Available: \(available)", true)
            }
            selected = match
        } else if details.count == 1 {
            selected = details[0]
        } else {
            // Multiple attachments — list them for the caller to pick.
            let list = details.map { detail -> [String: Any] in
                var entry: [String: Any] = ["filename": detail.transferName]
                if !detail.mimeType.isEmpty { entry["type"] = detail.mimeType }
                if detail.totalBytes > 0 { entry["size_bytes"] = detail.totalBytes }
                return entry
            }
            let response: [String: Any] = [
                "message_id": messageID,
                "count": list.count,
                "attachments": list,
                "hint": "Multiple attachments on this message. Use the filename parameter to select one.",
            ]
            return (IMessageIntegration.jsonEncode(response), false)
        }

        switch IMessageIntegration.fetchAndUpload(attachment: selected, fileSink: host.fileSink) {
        case .success(let uploaded):
            var response: [String: Any] = [
                uploaded.ref.key: uploaded.ref.value,
                "filename": uploaded.filename,
                "message_id": messageID,
            ]
            if !uploaded.mimeType.isEmpty { response["type"] = uploaded.mimeType }
            if IMessageIntegration.imageMIMETypes.contains(uploaded.mimeType.lowercased()) {
                response["note"] = "Image resized for LLM vision input."
            }
            return (IMessageIntegration.jsonEncode(response), false)
        case .failure(let err):
            return ("\(err)", true)
        }
    }

    // MARK: - Row formatting (tool-specific)

    /// Column layout: 0=ROWID, 1=text, 2=is_from_me, 3=service, 4=is_delivered, 5=is_sent,
    /// 6=handle, 7=date, 8=body_hex, 9=attachments (for read);
    /// or 8-11=chat fields, 12=body_hex, 13=attachments (for search).
    func messageFromRow(_ row: [String], bodyHexIndex: Int = 8, attachmentsIndex: Int = 9) -> [String: Any] {
        var msg: [String: Any] = [:]

        msg["message_id"] = Int(row[0]) ?? 0

        var text = row[1]
        if text.isEmpty, row.count > bodyHexIndex, !row[bodyHexIndex].isEmpty {
            text = IMessageFormatting.bodyText(hex: row[bodyHexIndex]) ?? ""
        }
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { msg["text"] = text }

        msg["from"] = row[2] == "1" ? "me" : (row[6].isEmpty ? "unknown" : row[6])
        if !row[3].isEmpty { msg["service"] = row[3] }
        msg["delivered"] = row[4] == "1"
        msg["sent"] = row[5] == "1"
        if !row[7].isEmpty { msg["date"] = IMessageIntegration.appleNanosToISO(row[7]) }

        if row.count > attachmentsIndex, !row[attachmentsIndex].isEmpty {
            // Entries are joined by the unit-separator (char 31) rather than
            // ", " so a transfer_name containing a comma isn't split into bogus
            // entries; each entry is "mime:transfer_name" with the mime/name
            // fields split on the FIRST colon only, since a transfer_name may
            // itself contain ':' (issue #22). An empty mime (NULL in chat.db)
            // yields no `type` key rather than leaking a bare colon.
            let attachments = row[attachmentsIndex]
                .split(separator: Self.attachmentEntrySeparator, omittingEmptySubsequences: true)
                .map { entry -> [String: String] in
                    let e = String(entry)
                    if let colon = e.firstIndex(of: ":") {
                        let mime = String(e[e.startIndex..<colon])
                        let name = String(e[e.index(after: colon)...])
                        var dict = ["filename": name]
                        if !mime.isEmpty { dict["type"] = mime }
                        return dict
                    }
                    return ["filename": e]
                }
            msg["attachments"] = attachments
        }

        return msg
    }

    /// Delimiter joining attachment entries in the read/search `GROUP_CONCAT`
    /// (SQL `char(31)`). The ASCII unit separator can't appear in a mime type
    /// or a macOS filename, so it's a safe entry boundary — unlike the previous
    /// ", " which collided with commas in transfer names (issue #22).
    static let attachmentEntrySeparator: Character = "\u{1F}"
}
