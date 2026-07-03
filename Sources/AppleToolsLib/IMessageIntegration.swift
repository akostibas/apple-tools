import AppKit
import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Shared iMessage I/O library. All iMessage database access, sending, and
/// attachment handling lives here.
///
/// Consumers: IMessageTool (LLM tool wrapper), IMessageReceivedHook (gateway
/// inbound polling), and any future iMessage integration point.
///
/// Design: stateless enum with static methods. Database path and config are
/// passed as parameters where needed.
public enum IMessageIntegration {

    // Apple epoch: 2001-01-01 00:00:00 UTC, stored as nanoseconds in chat.db.
    public static let appleEpochOffset: Int = 978307200
    public static let chatDBPath = NSHomeDirectory() + "/Library/Messages/chat.db"

    /// Image MIME types that should be resized for LLM vision input.
    public static let imageMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif",
        "image/tiff", "image/bmp", "image/gif", "image/webp",
    ]

    // MARK: - Types

    /// A raw message row from chat.db, used by the hook for new-message polling.
    public struct RawMessage {
        public let rowID: Int64
        public let guid: String
        public let text: String
        public let sender: String
        public let dateRaw: String
        public let chatIdentifier: String
        public let attachmentROWIDs: [Int64]
    }

    /// Metadata for a single attachment on a message.
    public struct AttachmentDetail {
        public let rowID: Int
        public let filePath: String       // ~/Library/Messages/Attachments/...
        public let mimeType: String
        public let transferName: String    // user-facing filename
        public let totalBytes: Int
    }

    /// Result of exporting an attachment to the local output dir.
    public struct UploadedAttachment {
        public let ref: FileReference
        public let filename: String
        public let mimeType: String
    }

    // MARK: - Sending

    /// Send a message via iMessage, falling back to SMS for phone numbers.
    /// Delegates to IMessageSender (AppleScript-based). Optional `attachments`
    /// is a list of absolute file paths sent after the text body; SMS
    /// fallback is refused when attachments are non-empty (see IMessageSender).
    public static func send(to recipient: String, text: String, attachments: [String] = []) -> IMessageSender.SendResult {
        return IMessageSender.send(to: recipient, text: text, attachments: attachments)
    }

    /// Whether a 1:1 chat thread already exists for the recipient handle.
    /// Used by IMessageSender to route the first outbound to a fresh
    /// contact through a chat-creating AppleScript path: `send to
    /// buddy` silently no-ops when Messages.app has no prior thread.
    ///
    /// Returns `nil` when the chat.db lookup itself fails (e.g. FDA
    /// denied) so the caller can fall back to the legacy buddy-send path
    /// rather than risk duplicate-chat creation. `style = 45` restricts
    /// to 1:1 — group threads use SendToChat by GUID.
    public static func hasOneToOneChatForHandle(_ handle: String) -> Bool? {
        let sql = """
            SELECT 1 FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE \(handleMatchClause(column: "h.id", handle: handle)) AND c.style = 45
            LIMIT 1
            """
        let (rows, err) = queryChatDB(sql)
        if err != nil { return nil }
        return !rows.isEmpty
    }

    /// Build a SQL boolean predicate matching a stored message handle in
    /// `column` against a caller-supplied recipient. chat.db stores phone
    /// handles canonically in E.164 (`+16502530000`), but callers routinely
    /// pass national or formatted numbers (`6502530000`, `(650) 253-0000`) —
    /// a verbatim `= handle` match then finds no row, breaking first-contact
    /// detection and delivery confirmation (issue #21). So when the handle
    /// parses as a phone number we match its E.164 form as well. Emails and
    /// short codes (PhoneFormatting returns nil) match verbatim only. All
    /// candidate values are single-quote-escaped for SQL.
    static func handleMatchClause(column: String, handle: String) -> String {
        var candidates = [handle]
        if let e164 = PhoneFormatting.e164(handle), !candidates.contains(e164) {
            candidates.append(e164)
        }
        let list = candidates
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
        return "\(column) IN (\(list))"
    }

    /// Look up the Messages.app guid for a chat_identifier (e.g. "chat6711433889022879"
    /// → "any;+;chat6711433889022879"). Messages.app AppleScript requires the guid
    /// format for `chat id` addressing.
    public static func chatGUID(forIdentifier identifier: String) -> String? {
        let escaped = identifier.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT guid FROM chat WHERE chat_identifier = '\(escaped)' LIMIT 1"
        let (rows, err) = queryChatDB(sql)
        if err != nil || rows.isEmpty { return nil }
        let guid = rows[0][0]
        return guid.isEmpty ? nil : guid
    }

    // MARK: - Preflight

    /// Check Messages.app access and chat.db readability.
    public static func preflight() -> (ok: Bool, message: String) {
        // Trigger the automation permission dialog for Messages.
        let script = """
        tell application "Messages"
            count of services
        end tell
        """
        let (_, err) = IMessageSender.runAppleScript(script, [:], nil)
        if let err = err {
            return (false, "messages access denied: \(err)")
        }

        // Verify chat.db is actually readable.
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        if rc != SQLITE_OK {
            return (false, "cannot read chat.db — grant Full Disk Access to the probe in System Settings → Privacy & Security → Full Disk Access")
        }

        return (true, "messages access granted, chat.db readable")
    }

    /// Lightweight preflight: only checks chat.db readability (no AppleScript).
    public static func preflightDBOnly() -> (ok: Bool, message: String) {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        if rc != SQLITE_OK {
            return (false, "cannot read chat.db — grant Full Disk Access")
        }
        return (true, "chat.db readable")
    }

    // MARK: - New message polling (for hooks)

    /// Query chat.db for new incoming 1:1 messages since a cursor ROWID.
    /// Returns messages in ROWID-ascending order. Decodes attributedBody
    /// and strips attachment placeholders. Includes attachment ROWIDs.
    public static func newMessages(sinceROWID: Int64) -> (messages: [RawMessage], error: String?) {
        let sql = """
            SELECT m.ROWID,
                   COALESCE(m.guid, '') AS guid,
                   COALESCE(m.text, '') AS text,
                   COALESCE(h.id, '') AS sender,
                   m.date,
                   c.chat_identifier,
                   CASE WHEN m.text IS NULL OR m.text = '' THEN hex(m.attributedBody) ELSE '' END AS body_hex
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > \(sinceROWID)
              AND m.is_from_me = 0
              AND c.style = 45
              AND m.item_type = 0
            ORDER BY m.ROWID ASC
            """

        let (rows, err) = queryChatDB(sql)
        if let err = err { return ([], err) }

        var messages: [RawMessage] = []
        for row in rows {
            guard row.count >= 7 else { continue }

            let rowID = Int64(row[0]) ?? 0
            let guid = row[1]
            var text = row[2]
            let sender = row[3]
            let dateRaw = row[4]
            let chatIdentifier = row[5]
            let bodyHex = row[6]

            // Decode attributedBody if text column is empty. bodyText recovers
            // Markdown when the message carries formatting and falls back to the
            // plain byte-scan otherwise, so non-formatted messages are unchanged.
            if text.isEmpty && !bodyHex.isEmpty {
                text = IMessageFormatting.bodyText(hex: bodyHex) ?? ""
            }

            // Strip attachment placeholder characters.
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)

            // Query attachment ROWIDs for this message.
            let attachmentROWIDs = attachmentROWIDs(forMessageROWID: rowID)

            messages.append(RawMessage(
                rowID: rowID,
                guid: guid,
                text: text,
                sender: sender,
                dateRaw: dateRaw,
                chatIdentifier: chatIdentifier,
                attachmentROWIDs: attachmentROWIDs
            ))
        }

        return (messages, nil)
    }

    /// Get the current maximum message ROWID (for initial cursor).
    public static func currentMaxROWID() -> Int64 {
        let (rows, _) = queryChatDB("SELECT MAX(ROWID) FROM message")
        if let row = rows.first, let val = Int64(row[0]) {
            return val
        }
        return 0
    }

    /// Convert a wall-clock `Date` to chat.db's date format (nanoseconds since
    /// Apple epoch 2001-01-01 UTC).
    public static func dateToAppleNanos(_ date: Date) -> Int64 {
        let unix = date.timeIntervalSince1970
        return Int64((unix - Double(appleEpochOffset)) * 1_000_000_000)
    }

    ///: Replay-cap skip-ahead. Given a loaded cursor and a wall-clock
    /// cutoff (= now - replayCap), find the largest ROWID with date strictly
    /// before the cutoff. If that exceeds the loaded cursor, return it as the
    /// new starting cursor along with a count of inbound 1:1 messages skipped
    /// (for observability). Returns nil if nothing to skip — the loaded cursor
    /// is already inside the replay window or chat.db has no rows older than
    /// the cutoff.
    public static func skipAheadCursor(loadedROWID: Int64, cutoffAppleNanos: Int64) -> (newROWID: Int64, droppedCount: Int)? {
        let maxSQL = "SELECT MAX(ROWID) FROM message WHERE date < \(cutoffAppleNanos)"
        let (maxRows, _) = queryChatDB(maxSQL)
        guard let row = maxRows.first, !row[0].isEmpty,
              let newROWID = Int64(row[0]), newROWID > loadedROWID else {
            return nil
        }
        // Count inbound 1:1 messages between (loadedROWID, newROWID] using the
        // same filters as `newMessages` so the dropped count reflects what the
        // hook would have actually forwarded.
        let countSQL = """
            SELECT COUNT(*) FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.ROWID > \(loadedROWID) AND m.ROWID <= \(newROWID)
              AND m.is_from_me = 0 AND c.style = 45 AND m.item_type = 0
            """
        let (countRows, _) = queryChatDB(countSQL)
        let dropped = countRows.first.flatMap { Int($0[0]) } ?? 0
        return (newROWID, dropped)
    }

    // MARK: - Outgoing delivery status

    /// Snapshot of the most recent outgoing message to a given handle, used to
    /// confirm whether a send actually reached the recipient. AppleScript
    /// `send to buddy` returns success as soon as Messages.app accepts the
    /// message — it does NOT wait for transmission. The real outcome lands
    /// in chat.db a few moments later: `error != 0` for rejection (e.g.
    /// recipient not registered for iMessage), `is_sent = 1` for success.
    public struct OutgoingStatus {
        public enum State {
            case sent       // is_sent = 1, error = 0
            case rejected   // error != 0 — Messages.app refused/failed to deliver
            case pending    // row exists but is_sent = 0 and error = 0 (still queued)
            case noRow      // no matching outgoing row found
        }
        public let state: State
        public let rowID: Int64
        public let error: Int       // chat.db `error` column; 0 if none
        public let isSent: Bool
        public let isDelivered: Bool
    }

    /// Look up the most recent outgoing message to `handle` whose ROWID is
    /// strictly greater than `sinceROWID`. Use `currentMaxROWID()` as the
    /// cursor immediately before invoking the AppleScript send so this
    /// query only sees rows created by *this* send.
    public static func outgoingStatus(toHandle handle: String, sinceROWID: Int64) -> OutgoingStatus {
        let sql = """
            SELECT m.ROWID,
                   COALESCE(m.is_sent, 0),
                   COALESCE(m.is_delivered, 0),
                   COALESCE(m.error, 0)
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > \(sinceROWID)
              AND m.is_from_me = 1
              AND \(handleMatchClause(column: "h.id", handle: handle))
            ORDER BY m.ROWID DESC
            LIMIT 1
            """

        let (rows, _) = queryChatDB(sql)
        guard let row = rows.first, row.count >= 4 else {
            return OutgoingStatus(state: .noRow, rowID: 0, error: 0, isSent: false, isDelivered: false)
        }

        let rowID = Int64(row[0]) ?? 0
        let isSent = (Int(row[1]) ?? 0) != 0
        let isDelivered = (Int(row[2]) ?? 0) != 0
        let errorCode = Int(row[3]) ?? 0

        let state: OutgoingStatus.State
        if errorCode != 0 {
            state = .rejected
        } else if isSent {
            state = .sent
        } else {
            state = .pending
        }
        return OutgoingStatus(state: state, rowID: rowID, error: errorCode, isSent: isSent, isDelivered: isDelivered)
    }

    // MARK: - Attachments

    /// Query attachment ROWIDs for a message (lightweight — just IDs).
    public static func attachmentROWIDs(forMessageROWID messageROWID: Int64) -> [Int64] {
        let sql = """
            SELECT a.ROWID
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = \(messageROWID)
            """
        let (rows, _) = queryChatDB(sql)
        return rows.compactMap { Int64($0[0]) }
    }

    /// Query full attachment details for a message.
    public static func attachments(forMessageID messageID: Int) -> (attachments: [AttachmentDetail], error: String?) {
        let sql = """
            SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = \(messageID)
            """

        let (rows, err) = queryChatDB(sql)
        if let err = err { return ([], err) }

        let details = rows.map { row in
            AttachmentDetail(
                rowID: Int(row[0]) ?? 0,
                filePath: row[1],
                mimeType: row[2],
                transferName: row[3],
                totalBytes: Int(row[4]) ?? 0
            )
        }
        return (details, nil)
    }

    /// Fetch an attachment from disk, resize if image, and hand it to the sink.
    /// Returns the delivered file metadata or an error description.
    public static func fetchAndUpload(
        attachment: AttachmentDetail,
        fileSink: FileSink
    ) -> Result<UploadedAttachment, FileSinkError> {
        let expandedPath = (attachment.filePath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            if attachment.filePath.isEmpty {
                return .failure(.message("attachment has no local file path — it may not have been downloaded"))
            }
            return .failure(.message("attachment file not found at \(expandedPath) — it may be stored in iCloud and not downloaded locally"))
        }

        guard let fileData = FileManager.default.contents(atPath: expandedPath) else {
            return .failure(.message("failed to read attachment file at \(expandedPath)"))
        }

        // Resolve MIME type: prefer UTType detection from the file extension,
        // fall back to the chat.db value, then to octet-stream.
        let transferName = attachment.transferName.isEmpty ? "attachment" : attachment.transferName
        let ext = (transferName as NSString).pathExtension
        let resolvedMIME: String
        if !ext.isEmpty, let utMIME = UTType(filenameExtension: ext)?.preferredMIMEType {
            resolvedMIME = utMIME
        } else if !attachment.mimeType.isEmpty && attachment.mimeType != "application/octet-stream" {
            resolvedMIME = attachment.mimeType
        } else {
            resolvedMIME = "application/octet-stream"
        }

        // For images, resize for LLM consumption. Upload others as-is.
        let uploadData: Data
        let uploadFilename: String
        let isImage = imageMIMETypes.contains(resolvedMIME.lowercased())

        if isImage, let resized = ImageResizer.resizeForLLM(imageData: fileData) {
            uploadData = resized
            let baseName = (transferName as NSString).deletingPathExtension
            uploadFilename = "\(baseName).jpg"
        } else {
            uploadData = fileData
            uploadFilename = transferName
        }

        let result = fileSink.deliver(filename: uploadFilename, data: uploadData)
        switch result {
        case .success(let ref):
            return .success(UploadedAttachment(
                ref: ref,
                filename: uploadFilename,
                mimeType: resolvedMIME
            ))
        case .failure(let error):
            return .failure(.message("file delivery failed: \(error)"))
        }
    }

    // MARK: - Chat resolution

    public enum ChatResolution {
        case resolved(Int)                  // chat ROWID
        case ambiguous([[String: Any]])     // multiple matches with metadata
        case error(String)
    }

    /// Resolve a chat identifier (phone, email, group name, or chat_id) to a chat ROWID.
    public static func resolveChat(_ input: String) -> ChatResolution {
        // 1. Exact match on chat_identifier.
        let byChatID = """
            SELECT ROWID, chat_identifier, display_name, style FROM chat
            WHERE chat_identifier = '\(input.replacingOccurrences(of: "'", with: "''"))'
            """
        let (cidRows, cidErr) = queryChatDB(byChatID)
        if let err = cidErr { return .error(err) }
        if cidRows.count == 1 {
            return .resolved(Int(cidRows[0][0]) ?? 0)
        }

        // 2. Match on display_name (group chats).
        let escaped = input.replacingOccurrences(of: "'", with: "''")
        let byName = """
            SELECT ROWID, chat_identifier, display_name, style FROM chat
            WHERE display_name = '\(escaped)' AND style = 43
            """
        let (nameRows, nameErr) = queryChatDB(byName)
        if let err = nameErr { return .error(err) }
        if nameRows.count == 1 {
            return .resolved(Int(nameRows[0][0]) ?? 0)
        }
        if nameRows.count > 1 {
            return .ambiguous(nameRows.map { chatSummary($0) })
        }

        // 3. Match on handle.id → find chats that include this handle.
        let byHandle = """
            SELECT DISTINCT c.ROWID, c.chat_identifier, c.display_name, c.style
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id = '\(escaped)' AND c.style = 45
            """
        let (handleRows, handleErr) = queryChatDB(byHandle)
        if let err = handleErr { return .error(err) }
        if handleRows.count == 1 {
            return .resolved(Int(handleRows[0][0]) ?? 0)
        }
        if handleRows.count > 1 {
            return .ambiguous(handleRows.map { chatSummary($0) })
        }

        if cidRows.count > 1 {
            return .ambiguous(cidRows.map { chatSummary($0) })
        }

        return .error("no conversation found matching: \(input)")
    }

    /// Build a summary dict for a chat row (for disambiguation).
    /// Row: 0=ROWID, 1=chat_identifier, 2=display_name, 3=style
    public static func chatSummary(_ row: [String]) -> [String: Any] {
        let chatRowID = row[0]
        let chatIdentifier = row[1]
        let displayName = row[2]
        let style = row[3]
        let isGroup = style == "43"

        var summary: [String: Any] = ["chat_id": chatIdentifier]

        if isGroup {
            summary["name"] = displayName.isEmpty ? "(unnamed group)" : displayName
            let participantSQL = """
                SELECT h.id FROM handle h
                JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = \(chatRowID)
                """
            let (pRows, _) = queryChatDB(participantSQL)
            summary["participants"] = pRows.map { $0[0] }
        } else {
            summary["name"] = chatIdentifier
        }

        let lastMsgSQL = """
            SELECT m.date FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = \(chatRowID)
            ORDER BY m.date DESC LIMIT 1
            """
        let (dateRows, _) = queryChatDB(lastMsgSQL)
        if let dateRow = dateRows.first, !dateRow[0].isEmpty {
            summary["last_message"] = appleNanosToISO(dateRow[0])
        }

        return summary
    }

    // MARK: - Timestamp conversion

    public static func appleNanosToISO(_ raw: String) -> String {
        guard let nanos = Int64(raw) else { return raw }
        let unixSeconds = Double(nanos) / 1_000_000_000.0 + Double(appleEpochOffset)
        let date = Date(timeIntervalSince1970: unixSeconds)
        return DateFormatting.iso(date)
    }

    public static func isoToAppleNanos(_ iso: String) -> Int64? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = fmt.date(from: iso)
        if date == nil {
            fmt.formatOptions = [.withInternetDateTime]
            date = fmt.date(from: iso)
        }
        guard let d = date else { return nil }
        let unixSeconds = d.timeIntervalSince1970
        let appleSeconds = unixSeconds - Double(appleEpochOffset)
        return Int64(appleSeconds * 1_000_000_000)
    }

    /// UTC date-only / space-separated fallback formats accepted for `since`
    /// and `before` filters, in addition to full ISO-8601. Agents routinely
    /// pass `2026-07-03` or `2026-07-03 12:00:00`, which `isoToAppleNanos`
    /// rejects (issue #23).
    private static let dateFilterFallbackFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = format
            return f
        }
    }()

    /// Parse a `since`/`before` filter (or a `next_before` pagination cursor)
    /// into chat.db apple-nanos. Accepts, in order:
    ///   - a raw apple-nanos integer — the exact, lossless cursor we emit as
    ///     `next_before`, so pagination round-trips without flooring
    ///     same-second messages (issue #20);
    ///   - full ISO-8601, with or without fractional seconds;
    ///   - date-only `YYYY-MM-DD` and `YYYY-MM-DD HH:MM[:SS]` in UTC (issue #23).
    /// Returns nil ONLY when the value matches none of these, so callers can
    /// surface a tool error instead of silently dropping the filter and
    /// looping on page 1 forever (issue #23).
    public static func parseDateFilterToAppleNanos(_ input: String) -> Int64? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Raw apple-nanos cursor. 15+ digits is far outside the range of any
        // date string a caller would type (a bare year is 4), so this is
        // unambiguous.
        if trimmed.count >= 15, trimmed.allSatisfy({ $0.isNumber }), let nanos = Int64(trimmed) {
            return nanos
        }

        if let nanos = isoToAppleNanos(trimmed) { return nanos }

        for fmt in dateFilterFallbackFormatters {
            if let date = fmt.date(from: trimmed) {
                let appleSeconds = date.timeIntervalSince1970 - Double(appleEpochOffset)
                return Int64(appleSeconds * 1_000_000_000)
            }
        }
        return nil
    }

    // MARK: - AttributedBody decoding

    /// Decode text from an NSKeyedArchiver attributedBody blob (hex-encoded).
    ///
    /// Layout: ... "NSString" <5-byte preamble> <length> <UTF-8 text> ...
    /// Length encoding (typedstream varint): a first byte < 0x81 is the length
    /// itself; 0x81 means the next 2 bytes are a little-endian uint16; 0x82
    /// means the next 4 bytes are a little-endian uint32 (needed once the text
    /// exceeds 65535 bytes — without it a long message decodes to garbage,
    /// issue #35).
    public static func decodeAttributedBody(hex: String) -> String? {
        guard let data = dataFromHex(hex) else { return nil }

        let marker: [UInt8] = Array("NSString".utf8)
        guard let markerIndex = findSubsequence(in: data, subsequence: marker) else { return nil }

        let preambleEnd = markerIndex + marker.count + 5
        guard preambleEnd < data.count else { return nil }

        let lengthByte = data[preambleEnd]
        let textStart: Int
        let textLength: Int

        if lengthByte == 0x81 {
            guard preambleEnd + 2 < data.count else { return nil }
            textLength = Int(data[preambleEnd + 1]) + Int(data[preambleEnd + 2]) * 256
            textStart = preambleEnd + 3
        } else if lengthByte == 0x82 {
            guard preambleEnd + 4 < data.count else { return nil }
            textLength = Int(data[preambleEnd + 1])
                | Int(data[preambleEnd + 2]) << 8
                | Int(data[preambleEnd + 3]) << 16
                | Int(data[preambleEnd + 4]) << 24
            textStart = preambleEnd + 5
        } else {
            textLength = Int(lengthByte)
            textStart = preambleEnd + 1
        }

        guard textStart + textLength <= data.count else { return nil }
        return String(bytes: data[textStart..<(textStart + textLength)], encoding: .utf8)
    }

    // MARK: - chat.db query

    public static func queryChatDB(_ sql: String) -> ([[String]], String?) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(chatDBPath, &db, flags, nil)
        guard rc == SQLITE_OK, let db = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            if msg.contains("unable to open") || msg.contains("authorization denied") || rc == SQLITE_AUTH {
                return ([], "cannot read chat.db — grant Full Disk Access to the probe in System Settings → Privacy & Security → Full Disk Access")
            }
            return ([], "failed to open chat.db: \(msg)")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            return ([], "chat.db query failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let colCount = sqlite3_column_count(stmt)
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for i in 0..<colCount {
                if let cStr = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: cStr))
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }

        return (rows, nil)
    }

    // MARK: - Helpers

    public static func jsonEncode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed to serialize response\"}"
        }
        return str
    }

    static func dataFromHex(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }

    static func findSubsequence(in data: [UInt8], subsequence: [UInt8]) -> Int? {
        guard subsequence.count <= data.count else { return nil }
        let limit = data.count - subsequence.count
        for i in 0...limit {
            if data[i..<(i + subsequence.count)].elementsEqual(subsequence) {
                return i
            }
        }
        return nil
    }
}
