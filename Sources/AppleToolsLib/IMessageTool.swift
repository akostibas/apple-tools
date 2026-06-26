import AppKit
import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Callback type for sending async notifications to the proxy inbox.
public typealias NotifyCallback = (_ message: String, _ agent: String?) -> Void

public struct IMessageTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "imessage",
        description: "iMessage and SMS. Actions: 'recent' (list conversations with recent activity), 'send' (send a message; supports file attachments by absolute path), 'read' (messages from a conversation), 'search' (find messages by text content), 'fetch_attachment' (retrieve an attachment file from a message).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "recent, send, read, search, or fetch_attachment"),
                "to": PropertySchema(type_: "string", description: "Recipient phone number, email, or chat_id for group chats (for send)"),
                "text": PropertySchema(type_: "string", description: "Message text to send (for send)"),
                "attachments": PropertySchema(
                    type_: "array",
                    description: "Absolute file paths to attach to a send. '~' is expanded. Each ≤100MB; max 10. iMessage transport only — sending to an SMS-only recipient with attachments will fail.",
                    items: ItemsSchema(type_: "string")
                ),
                "chat": PropertySchema(type_: "string", description: "Phone number, email, group name, or chat_id (for read; optional filter for search)"),
                "query": PropertySchema(type_: "string", description: "Text to search for (for search)"),
                "limit": PropertySchema(type_: "integer", description: "Max results (default 5 for recent, 10 for read, 20 for search)"),
                "before": PropertySchema(type_: "string", description: "ISO 8601 timestamp — return messages/conversations before this time (for read, search)"),
                "since": PropertySchema(type_: "string", description: "ISO 8601 timestamp — only include activity after this time (for recent, search)"),
                "message_id": PropertySchema(type_: "integer", description: "Message ROWID from read/search results (for fetch_attachment)"),
                "filename": PropertySchema(type_: "string", description: "Attachment filename to select when a message has multiple attachments (for fetch_attachment, optional)"),
            ],
            required: ["action"]
        )
    )

    public let host: ToolHost

    /// Optional callback for sending async notifications (e.g. delivery failure).
    /// Set after init once the ProbeClient is ready.
    public var notify: NotifyCallback?

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "recent":           .read,
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
            return recent(limit: limit, since: since)
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
            return ("unknown action: \(action) (use recent, send, read, search, or fetch_attachment)", true)
        }
    }

    // MARK: - Preflight

    public func preflight() -> (ok: Bool, message: String) {
        return IMessageIntegration.preflight()
    }

    // MARK: - Send

    private func send(to recipient: String, text: String, attachments: [String]) -> (String, Bool) {
        let (resolved, attachErr) = resolveAttachments(attachments)
        if let attachErr = attachErr { return (attachErr, true) }

        let result = IMessageIntegration.send(to: recipient, text: text, attachments: resolved)
        if result.isError {
            return (result.message, true)
        }

        // Send was accepted. Schedule async delivery check.
        scheduleDeliveryCheck(recipient: recipient, text: text)

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

    /// Check chat.db after a delay to verify the message was delivered.
    private func scheduleDeliveryCheck(recipient: String, text: String) {
        guard notify != nil else { return }
        Log.info("Delivery check: scheduling for \(recipient) in 4s")

        DispatchQueue.global().asyncAfter(deadline: .now() + 4.0) { [self] in
            let escapedRecipient = recipient.replacingOccurrences(of: "'", with: "''")

            let sql = """
                SELECT m.is_delivered, m.is_sent, m.error, m.service
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                JOIN chat c ON cmj.chat_id = c.ROWID
                WHERE m.is_from_me = 1
                  AND (c.chat_identifier = '\(escapedRecipient)' OR h.id = '\(escapedRecipient)')
                ORDER BY m.date DESC
                LIMIT 1
                """

            let (rows, err) = IMessageIntegration.queryChatDB(sql)
            if err != nil || rows.isEmpty { return }

            let row = rows[0]
            guard row.count >= 4 else { return }

            let isDelivered = row[0] == "1"
            let isSent = row[1] == "1"
            let errorCode = Int(row[2]) ?? 0
            let service = row[3]

            if isDelivered {
                Log.info("Delivery check: message to \(recipient) confirmed delivered via \(service)")
                return
            }

            if errorCode != 0 {
                Log.info("Delivery check: message to \(recipient) failed with error \(errorCode)")
                notify?("Failed to send message to \(recipient): error code \(errorCode). The message was not delivered.", nil)
                return
            }

            if isSent && !isDelivered && service == "iMessage" {
                Log.info("Delivery check: message to \(recipient) sent but not delivered (service: \(service))")
                notify?("Message to \(recipient) was sent via iMessage but delivery has not been confirmed. The recipient may not use iMessage. You may want to retry via SMS or check with the user.", nil)
            }
        }
    }

    // MARK: - Recent

    private func recent(limit: Int, since: String?) -> (String, Bool) {
        var sinceFilter = ""
        if let since = since, let nanos = IMessageIntegration.isoToAppleNanos(since) {
            sinceFilter = "HAVING MAX(m.date) > \(nanos)"
        }

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
            LIMIT \(limit)
            """

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let conversations = rows.map { row -> [String: Any] in
            recentConversationFromRow(row)
        }

        let response: [String: Any] = [
            "count": conversations.count,
            "conversations": conversations,
        ]
        return (IMessageIntegration.jsonEncode(response), false)
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
                   COALESCE(GROUP_CONCAT(a.mime_type || ':' || a.transfer_name, ', '), '') AS attachments
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE cmj.chat_id = \(chatID)
              AND (m.text IS NOT NULL AND m.text != '' OR m.attributedBody IS NOT NULL OR a.ROWID IS NOT NULL)
            """

        if let before = before, let nanos = IMessageIntegration.isoToAppleNanos(before) {
            sql += "\n  AND m.date < \(nanos)"
        }

        sql += "\nGROUP BY m.ROWID\nORDER BY m.date DESC\nLIMIT \(limit + 1)"

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let hasMore = rows.count > limit
        let pageRows = hasMore ? Array(rows.prefix(limit)) : rows

        let messages = pageRows.reversed().map { row -> [String: Any] in
            messageFromRow(row)
        }

        var response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]
        if hasMore, let oldest = pageRows.last, oldest.count > 7 {
            response["next_before"] = IMessageIntegration.appleNanosToISO(oldest[7])
        }
        return (IMessageIntegration.jsonEncode(response), false)
    }

    // MARK: - Search

    private func search(query: String, chat: String?, limit: Int, since: String?, before: String?) -> (String, Bool) {
        let escaped = query.replacingOccurrences(of: "'", with: "''")

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
        if let since = since, let nanos = IMessageIntegration.isoToAppleNanos(since) {
            extraFilters += " AND m.date > \(nanos)"
        }
        if let before = before, let nanos = IMessageIntegration.isoToAppleNanos(before) {
            extraFilters += " AND m.date < \(nanos)"
        }

        let sql = """
            SELECT m.ROWID,
                   COALESCE(m.text, '') AS text,
                   m.is_from_me, m.service, m.is_delivered, m.is_sent,
                   COALESCE(h.id, '') AS handle,
                   m.date,
                   c.chat_identifier, c.display_name, c.style, c.ROWID AS chat_rowid,
                   CASE WHEN m.text IS NULL OR m.text = '' THEN hex(m.attributedBody) ELSE '' END AS body_hex,
                   COALESCE(GROUP_CONCAT(a.mime_type || ':' || a.transfer_name, ', '), '') AS attachments
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE m.text LIKE '%\(escaped)%'
              AND m.text IS NOT NULL AND m.text != ''\(extraFilters)
            GROUP BY m.ROWID
            ORDER BY m.date DESC
            LIMIT \(limit)
            """

        let (rows, err) = IMessageIntegration.queryChatDB(sql)
        if let err = err { return (err, true) }

        let messages = rows.map { row -> [String: Any] in
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

        let response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]
        return (IMessageIntegration.jsonEncode(response), false)
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
            let attachments = row[attachmentsIndex].split(separator: ",").map { entry -> [String: String] in
                let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return ["type": String(parts[0]), "filename": String(parts[1])]
                }
                return ["filename": String(entry.trimmingCharacters(in: .whitespaces))]
            }
            msg["attachments"] = attachments
        }

        return msg
    }
}
