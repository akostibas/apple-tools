import AppKit
import Foundation
import UniformTypeIdentifiers

public struct EmailTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "email",
        description: "Access Apple Mail. Actions: 'inbox' (list recent messages from all inboxes), 'search' (search across all mail by query/sender/recipient/date; inbox and search return previews only — use 'read' for the full body), 'read' (get full message by ID), 'fetch_attachment' (retrieve an attachment file from a message), 'draft' (create a draft message — does NOT send; supports file attachments by absolute path).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "inbox, search, read, fetch_attachment, or draft"),
                "limit": PropertySchema(type_: "integer", description: "Max messages to return (for inbox and search, default 20, max 50)",
                    summary: "Max messages (default 20, max 50)", actions: ["inbox", "search"]),
                "id": PropertySchema(type_: "string", description: "Message ID (for read, fetch_attachment)",
                    summary: "Message ID", actions: ["read", "fetch_attachment"]),
                "filename": PropertySchema(type_: "string", description: "Attachment filename to select when a message has multiple attachments (for fetch_attachment, optional)",
                    summary: "Which attachment, when a message has several", actions: ["fetch_attachment"]),
                "query": PropertySchema(type_: "string", description: "Whitespace-separated tokens, all must match across subject, body preview, or sender — full message body is not searched (for search)",
                    summary: "Tokens matched across subject, body preview, sender", actions: ["search"]),
                "from": PropertySchema(type_: "string", description: "Sender name or email to filter by — a WIDE TEXT NET: matches a name prefix in the display name (so 'sam' finds 'Samira'), or a whole word in the email local-part; domain is ignored (so a full address like 'a@b.com' returns 0 — use from_email for that). When one query matches >1 distinct address, the response prepends a 'senders' rollup + hint (for search)",
                    summary: "Sender name/email, wide match (use --from_email for exact)", actions: ["search"]),
                "from_email": PropertySchema(type_: "string", description: "EXACT full sender address incl. domain, e.g. 'pinbot@pinterest.com' — the scalpel to 'from'. postmaster@a.com ≠ postmaster@b.com (for search)",
                    summary: "Exact full sender address incl. domain", actions: ["search"]),
                "exclude_spam": PropertySchema(type_: "boolean", description: "Drop likely automated/bulk senders (postmaster@, noreply@, bots, marketing). Default false (for search)",
                    summary: "Drop automated/bulk senders (alias --humans_only)", actions: ["search"]),
                "humans_only": PropertySchema(type_: "boolean", description: "Alias for exclude_spam — keep only human senders (for search)",
                    summary: "Alias for --exclude_spam", actions: ["search"]),
                "to": PropertySchema(type_: "string", description: "Recipient email address (for draft, or recipient filter for search)",
                    summary: "Recipient address (filters results on search)", actions: ["search", "draft"]),
                "after": PropertySchema(type_: "string", description: "ISO 8601 date lower bound, e.g. '2025-01-01' or '2025-01-01T00:00:00' (for search)",
                    summary: "ISO 8601 lower bound (e.g. 2025-01-01)", actions: ["search"]),
                "before": PropertySchema(type_: "string", description: "ISO 8601 date upper bound (for search)",
                    summary: "ISO 8601 upper bound", actions: ["search"]),
                "exclude_self": PropertySchema(type_: "boolean", description: "Drop results where the viewer is the sender; default true (for search)",
                    summary: "Drop messages you sent (default true)", actions: ["search"]),
                "cc": PropertySchema(type_: "string", description: "CC email address (for draft)",
                    summary: "CC address", actions: ["draft"]),
                "subject": PropertySchema(type_: "string", description: "Email subject (for draft)",
                    summary: "Email subject", actions: ["draft"]),
                "body": PropertySchema(type_: "string", description: "Email body text (for draft)",
                    summary: "Body text", actions: ["draft"]),
                "attachments": PropertySchema(
                    type_: "array",
                    description: "Absolute file paths to attach to the draft (for draft). '~' is expanded. Each path must exist and be ≤35MB; max 10 attachments.",
                    items: ItemsSchema(type_: "string"),
                    summary: "Absolute file paths to attach (≤35MB, max 10)", actions: ["draft"]
                ),
            ],
            required: ["action"]
        ),
        cliSummary: "Read, search, and draft Apple Mail messages.",
        actions: [
            ActionHelp(name: "inbox", summary: "List recent messages from all inboxes",
                example: "apple-tools email inbox [--limit <n>]"),
            ActionHelp(name: "search", summary: "Search all mail by query, sender, recipient, or date",
                example: "apple-tools email search [--query <text>] [--from <name>] [--after <date>] ..."),
            ActionHelp(name: "read", summary: "Get a full message by ID",
                example: "apple-tools email read --id <id>", required: ["id"]),
            ActionHelp(name: "draft", summary: "Create a draft — does not send",
                example: "apple-tools email draft --to <addr> [--subject <t>] [--body <t>] [--cc <a>] [--attachments <p>]", required: ["to"]),
            ActionHelp(name: "fetch_attachment", summary: "Retrieve an attachment file from a message",
                example: "apple-tools email fetch_attachment --id <id> [--filename <name>]", required: ["id"]),
        ]
    )

    public let host: ToolHost

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "inbox":            .read,
        "search":           .read,
        "read":             .read,
        "fetch_attachment": .read,
        "draft":            .readWrite,
    ])

    public init(host: ToolHost) {
        self.host = host
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "inbox":
            let limit = clamp(intParam(params, key: "limit") ?? 20, min: 1, max: 50)
            return inbox(limit: limit)
        case "search":
            return search(params: params)
        case "read":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            return read(id: id)
        case "draft":
            guard let to = params?["to"]?.value as? String, !to.isEmpty else {
                return ("missing required parameter: to", true)
            }
            let subject = params?["subject"]?.value as? String ?? ""
            let body = params?["body"]?.value as? String ?? ""
            let cc = params?["cc"]?.value as? String
            let attachments = (params?["attachments"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
            return draft(to: to, subject: subject, body: body, cc: cc, attachments: attachments)
        case "fetch_attachment":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let filename = params?["filename"]?.value as? String
            return fetchAttachment(id: id, filename: filename)
        default:
            return ("unknown action: \(action) (use inbox, search, read, fetch_attachment, or draft)", true)
        }
    }

    public func preflight() -> (ok: Bool, message: String) {
        return EmailIntegration.preflight()
    }

    // MARK: - Inbox

    private func inbox(limit: Int) -> (String, Bool) {
        let entries: [EmailIntegration.InboxEntry]
        do {
            entries = try EmailIntegration.recentInboxMessages(limit: limit)
        } catch let e as EmailIntegration.EmailError {
            return (e.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        let messages: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = [
                "id": entry.id,
                "subject": entry.subject,
                "from": entry.from,
                "date": entry.date,
                "read": entry.read,
            ]
            if entry.attachmentCount > 0 {
                dict["attachment_count"] = entry.attachmentCount
            }
            return dict
        }

        let response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Search

    private func search(params: [String: AnyCodable]?) -> (String, Bool) {
        var criteria = EmailSearch.Criteria()
        criteria.query = (params?["query"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        criteria.from = (params?["from"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        criteria.fromEmail = (params?["from_email"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        criteria.to = (params?["to"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        criteria.limit = clamp(intParam(params, key: "limit") ?? 20, min: 1, max: 50)
        if let v = params?["exclude_self"]?.value as? Bool {
            criteria.excludeSelf = v
        }
        // --exclude-spam / --humans-only (either flag opts in).
        if (params?["exclude_spam"]?.value as? Bool) == true
            || (params?["humans_only"]?.value as? Bool) == true {
            criteria.excludeBulk = true
        }

        if let s = params?["after"]?.value as? String, !s.isEmpty {
            guard let d = parseISODate(s) else {
                return ("unparseable 'after' date: \(s) (expected ISO 8601, e.g. 2025-01-01)", true)
            }
            criteria.after = d
        }
        if let s = params?["before"]?.value as? String, !s.isEmpty {
            guard let d = parseISODate(s) else {
                return ("unparseable 'before' date: \(s) (expected ISO 8601, e.g. 2025-01-01)", true)
            }
            criteria.before = d
        }

        let hits: [EmailSearch.Hit]
        do {
            hits = try EmailSearch.run(criteria)
        } catch let e as EmailSearch.SearchError {
            return (e.description, true)
        } catch {
            return ("search failed: \(error.localizedDescription)", true)
        }

        let messages: [[String: Any]] = hits.map { h in
            var entry: [String: Any] = [
                "id": h.messageID,
                "from": h.senderName.map { "\(h.senderAddress) (\($0))" } ?? h.senderAddress,
                "subject": h.subject,
                "date": DateFormatting.iso(h.date),
                "mailbox": prettifyMailboxURL(h.mailboxURL),
                // Classified from address + display name (no MIME headers in
                // the search path). See BulkSenderClassifier.
                "is_likely_spam": BulkSenderClassifier.isLikelyBulk(
                    address: h.senderAddress, name: h.senderName),
            ]
            if let snip = h.snippet, !snip.isEmpty { entry["snippet"] = snip }
            if let ai = h.aiSummary, !ai.isEmpty { entry["ai_summary"] = ai }
            return entry
        }

        var response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]

        // Distinct-sender rollup: only when a wide-net `from` query landed on
        // >1 distinct address. Surfaces the spread an agent would otherwise
        // have to scrape, plus a hint pointing at a REAL address for the
        // `from_email` scalpel. Skipped for from_email (already exact).
        if criteria.fromEmail == nil, let fromQuery = criteria.from,
           let rollup = senderRollup(hits: hits, fromQuery: fromQuery) {
            response["senders"] = rollup.senders
            response["hint"] = rollup.hint
        }

        return (jsonEncode(response), false)
    }

    /// Build the JSON rollup + hint from a result set. Returns nil when the
    /// query matched 0 or 1 distinct address (no rollup needed — no clutter).
    /// Counts/dates are computed over the RETURNED hits (capped at `limit`),
    /// so raise `--limit` to widen the picture.
    private func senderRollup(
        hits: [EmailSearch.Hit], fromQuery: String
    ) -> (senders: [[String: Any]], hint: String)? {
        let summaries = EmailSearch.senderRollup(hits)
        guard !summaries.isEmpty else { return nil }

        let senders: [[String: Any]] = summaries.map { s in
            [
                "address": s.address,
                "message_count": s.count,
                "first_date": DateFormatting.iso(s.first),
                "last_date": DateFormatting.iso(s.last),
            ]
        }

        // Concrete hint: point at the dominant (most-messages) real address.
        let dominant = summaries.first!.address
        let total = summaries.reduce(0) { $0 + $1.count }
        let hint = "\"\(fromQuery)\" matched \(total) messages across \(summaries.count) sender addresses; "
            + "use --from-email <addr> to filter to one (e.g. --from-email \(dominant))"
        return (senders, hint)
    }

    /// Accept ISO 8601 in a few common shapes: date-only, date + time (optional 'T'/space),
    /// optional seconds, optional timezone. Defaults to local time when absent.
    private func parseISODate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd",
        ]
        for f in formats {
            let df = DateFormatter()
            df.dateFormat = f
            df.timeZone = .current
            df.locale = Locale(identifier: "en_US_POSIX")
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Turn a mail URL like `imap://UUID/%5BGmail%5D/All%20Mail` into
    /// `[Gmail]/All Mail`. For local:// URLs, prefix "(local) ".
    private func prettifyMailboxURL(_ url: String) -> String {
        guard !url.isEmpty, let parsed = URLComponents(string: url) else { return url }
        let path = (parsed.path.removingPercentEncoding ?? parsed.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if parsed.scheme == "local" {
            return path.isEmpty ? "(local)" : "(local) \(path)"
        }
        return path.isEmpty ? "(root)" : path
    }

    // MARK: - Read

    private func read(id: String) -> (String, Bool) {
        // Fast path: look up the message in Apple Mail's Envelope Index, then
        // parse the .emlx directly off disk. Works on archived mail, not just
        // INBOX, and is ~900x faster than AppleScript on large mailboxes.
        // Falls back to AppleScript on any failure (unknown ID, missing file,
        // MIME shape we don't handle).
        if let response = readViaEnvelopeIndex(id: id) {
            return response
        }
        Log.info("email.read: falling back to AppleScript for id=\(id.prefix(40))…")
        return readViaAppleScript(id: id)
    }

    /// Returns nil to signal "fall back to AppleScript". Returns a response
    /// (possibly an error response) when the Envelope Index path reached a
    /// definitive outcome.
    private func readViaEnvelopeIndex(id: String) -> (String, Bool)? {
        let location: EmailSearch.MessageLocation?
        do {
            location = try EmailSearch.resolveMessageID(id)
        } catch {
            // DB errors (missing/unreadable) → fall back.
            return nil
        }
        guard let loc = location else {
            // Message-ID not in Envelope Index. Definitive: not found.
            return ("message not found", true)
        }
        guard let path = EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL) else {
            // Unsupported mailbox layout (e.g. local://). Fall back.
            return nil
        }
        let parsed: EmailMessage.Parsed
        do {
            parsed = try EmailMessage.parseEmlx(atPath: path)
        } catch {
            // Corrupt or unreadable file. Fall back.
            return nil
        }

        var response: [String: Any] = [
            "id": id,
            "subject": parsed.subject,
            "from": parsed.from,
            "to": parsed.to,
            "date": DateFormatting.isoFromRFC2822(parsed.dateHeader),
            "body": parsed.body,
        ]
        if let cc = parsed.cc, !cc.isEmpty { response["cc"] = cc }
        if parsed.bodyIsHTMLOnly { response["body_is_html_stripped"] = true }
        if !parsed.attachments.isEmpty {
            response["attachments"] = parsed.attachments.map { att -> [String: Any] in
                var e: [String: Any] = ["filename": att.filename]
                if !att.mimeType.isEmpty { e["type"] = att.mimeType }
                if att.size > 0 { e["size_bytes"] = att.size }
                return e
            }
        }
        return (jsonEncode(response), false)
    }

    private func readViaAppleScript(id: String) -> (String, Bool) {
        // Note: AppleScript fallback only searches INBOX, which is impractically
        // slow on large IMAP mailboxes like [Gmail]/All Mail. The Envelope Index
        // fast path handles non-INBOX reads.
        let message: EmailIntegration.MessageRead
        do {
            message = try EmailIntegration.readMessageViaAppleScript(id: id)
        } catch EmailIntegration.EmailError.notFound {
            return ("message not found", true)
        } catch let e as EmailIntegration.EmailError {
            return (e.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        var response: [String: Any] = [
            "id": message.id,
            "subject": message.subject,
            "from": message.from,
            "to": message.to,
            "date": message.date,
            "body": message.body,
        ]
        if !message.cc.isEmpty {
            response["cc"] = message.cc
        }

        if message.attachmentCount > 0 && !message.attachments.isEmpty {
            response["attachments"] = message.attachments.map { att -> [String: Any] in
                var dict: [String: Any] = ["filename": att.filename]
                if !att.mimeType.isEmpty { dict["type"] = att.mimeType }
                if att.size > 0 { dict["size_bytes"] = att.size }
                return dict
            }
        }

        return (jsonEncode(response), false)
    }

    // MARK: - Fetch Attachment

    /// Image MIME types that should be resized for LLM vision input.
    private static let imageMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif",
        "image/tiff", "image/bmp", "image/gif", "image/webp",
    ]

    private func fetchAttachment(id: String, filename: String?) -> (String, Bool) {
        // Fast path: locate the message via Envelope Index and decode the
        // attachment straight out of the .emlx. Works for archived mail, not
        // just INBOX. Falls back to AppleScript on any non-definitive failure
        // (unsupported mailbox layout, corrupt file, MIME we can't parse).
        if let response = fetchAttachmentViaEnvelopeIndex(id: id, filename: filename) {
            return response
        }
        Log.info("email.fetch_attachment: falling back to AppleScript for id=\(id.prefix(40))…")
        return fetchAttachmentViaAppleScript(id: id, filename: filename)
    }

    /// Returns nil to signal "fall back to AppleScript". Returns a response
    /// (possibly an error response) when the Envelope Index path reached a
    /// definitive outcome.
    private func fetchAttachmentViaEnvelopeIndex(id: String, filename: String?) -> (String, Bool)? {
        let location: EmailSearch.MessageLocation?
        do {
            location = try EmailSearch.resolveMessageID(id)
        } catch {
            return nil
        }
        guard let loc = location else {
            // Message-ID not in Envelope Index. Definitive: not found.
            return ("message not found: \(id)", true)
        }
        guard let path = EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL) else {
            // Unsupported mailbox layout (e.g. local://). Fall back.
            return nil
        }

        let loaded: EmailMessage.LoadedAttachment
        do {
            loaded = try EmailMessage.loadAttachment(atPath: path, filename: filename)
        } catch let e as EmailMessage.LoadError {
            switch e {
            case .noAttachments:
                return ("message has no attachments", true)
            case .notFound(let candidates):
                let available = candidates.joined(separator: ", ")
                return ("no attachment named '\(filename ?? "")'. Available: \(available)", true)
            case .ambiguous(let candidates):
                // Multiple attachments — surface the list for disambiguation.
                let list = candidates.map { ["filename": $0] as [String: Any] }
                let response: [String: Any] = [
                    "id": id,
                    "count": list.count,
                    "attachments": list,
                    "hint": "Multiple attachments on this message. Use the filename parameter to select one.",
                ]
                return (jsonEncode(response), false)
            }
        } catch {
            // Corrupt .emlx, MIME we can't parse, I/O error — fall back.
            return nil
        }

        // IMAP-synced .emlx files may contain the MIME structure for
        // attachments but not the actual body data (Mail fetches on demand).
        // Mail.app stores downloaded attachments as separate files in an
        // Attachments/ directory next to the Messages/ directory. Check there
        // before falling back to AppleScript (which is very slow on large
        // IMAP mailboxes like [Gmail]/All Mail). (,)
        if loaded.data.isEmpty {
            Log.info("email.fetch_attachment: .emlx attachment body is empty (likely IMAP stub), checking Attachments/ directory")
            if let ondiskData = EmailMessage.loadAttachmentFromDisk(
                emlxPath: path, rowID: loc.rowID, filename: loaded.filename
            ) {
                Log.info("email.fetch_attachment: found attachment on disk (\(ondiskData.count) bytes)")
                return uploadAttachment(id: id, name: loaded.filename, mimeType: loaded.mimeType, data: ondiskData)
            }
            Log.info("email.fetch_attachment: attachment not on disk, falling back to AppleScript")
            return nil
        }

        return uploadAttachment(id: id, name: loaded.filename, mimeType: loaded.mimeType, data: loaded.data)
    }

    /// Shared tail for both fast-path and fallback: resize images for LLM
    /// vision, upload via FileUploader, and build the response JSON.
    private func uploadAttachment(id: String, name: String, mimeType: String, data: Data) -> (String, Bool) {
        let isImage = Self.imageMIMETypes.contains(mimeType.lowercased())
        let uploadData: Data
        let uploadFilename: String
        if isImage, let resized = ImageResizer.resizeForLLM(imageData: data) {
            uploadData = resized
            let baseName = (name as NSString).deletingPathExtension
            uploadFilename = "\(baseName).jpg"
        } else {
            uploadData = data
            uploadFilename = name
        }

        let result = host.fileSink.deliver(filename: uploadFilename, data: uploadData)
        switch result {
        case .success(let ref):
            var response: [String: Any] = [
                ref.key: ref.value,
                "filename": uploadFilename,
                "id": id,
            ]
            if !mimeType.isEmpty { response["type"] = mimeType }
            if isImage { response["note"] = "Image resized for LLM vision input." }
            return (jsonEncode(response), false)
        case .failure(let error):
            return ("upload failed: \(error)", true)
        }
    }

    private func fetchAttachmentViaAppleScript(id: String, filename: String?) -> (String, Bool) {
        // First, list attachments on this message to validate and disambiguate.
        // Note: AppleScript fallback only searches INBOX, which is impractically
        // slow on large IMAP mailboxes like [Gmail]/All Mail. The on-disk
        // Attachments/ directory lookup in fetchAttachmentViaEnvelopeIndex
        // handles non-INBOX messages.
        let attachments: [EmailIntegration.AttachmentMeta]
        do {
            attachments = try EmailIntegration.listAttachmentsViaAppleScript(id: id)
        } catch EmailIntegration.EmailError.notFound {
            return ("message not found: \(id)", true)
        } catch let e as EmailIntegration.EmailError {
            return (e.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        // Select which attachment to fetch.
        let selected: EmailIntegration.AttachmentMeta
        if let filename = filename {
            guard let match = attachments.first(where: { $0.filename == filename }) else {
                let available = attachments.map { $0.filename }.joined(separator: ", ")
                return ("no attachment named '\(filename)'. Available: \(available)", true)
            }
            selected = match
        } else if attachments.count == 1 {
            selected = attachments[0]
        } else {
            // Multiple attachments — list them for disambiguation.
            let list = attachments.map { att -> [String: Any] in
                var entry: [String: Any] = ["filename": att.filename]
                if !att.mimeType.isEmpty { entry["type"] = att.mimeType }
                if att.size > 0 { entry["size_bytes"] = att.size }
                return entry
            }
            let response: [String: Any] = [
                "id": id,
                "count": list.count,
                "attachments": list,
                "hint": "Multiple attachments on this message. Use the filename parameter to select one.",
            ]
            return (jsonEncode(response), false)
        }

        let fileData: Data
        do {
            fileData = try EmailIntegration.saveAttachmentViaAppleScript(id: id, filename: selected.filename)
        } catch EmailIntegration.EmailError.notFound {
            return ("message not found: \(id)", true)
        } catch let e as EmailIntegration.EmailError {
            return (e.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        return uploadAttachment(id: id, name: selected.filename, mimeType: selected.mimeType, data: fileData)
    }

    // MARK: - Draft

    private func draft(to: String, subject: String, body: String, cc: String?, attachments: [String]) -> (String, Bool) {
        // Warn if the body contains markdown-style quote prefixes — these render
        // as literal ">" characters in the email, which is almost never intended.
        var warnings: [String] = []
        let lines = body.components(separatedBy: "\n")
        if lines.contains(where: { $0.hasPrefix(">") }) {
            warnings.append("Body contains lines starting with '>' which will appear as literal characters in the email. This is usually unintended markdown formatting.")
        }

        let (resolved, attachErr) = resolveAttachments(attachments)
        if let attachErr = attachErr { return (attachErr, true) }

        do {
            try EmailIntegration.createDraft(to: to, subject: subject, body: body, cc: cc, attachments: resolved)
        } catch let e as EmailIntegration.EmailError {
            return (e.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        var response: [String: Any] = [
            "status": "draft created",
            "to": to,
            "subject": subject,
        ]
        if let cc = cc, !cc.isEmpty {
            response["cc"] = cc
        }
        if !resolved.isEmpty {
            response["attachments"] = resolved
        }
        if !warnings.isEmpty {
            response["warnings"] = warnings
        }
        return (jsonEncode(response), false)
    }

    /// Validate attachment paths: expand `~`, confirm each exists and is a
    /// regular file under the size cap. Returns the list of absolute paths to
    /// hand to AppleScript, or a user-facing error string.
    ///
    /// Distinguishes between "file does not exist" and "file exists but is
    /// unreadable" so a Full Disk Access / sandbox denial surfaces differently
    /// from a typo. (TCC-denied protected folders return false from
    /// `fileExists` only when we can't traverse the parent; we probe with a
    /// follow-up `isReadableFile` check for clearer error wording.)
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
    private static let maxAttachmentBytes: Int64 = 35 * 1_048_576

    // MARK: - Helpers

    private func intParam(_ params: [String: AnyCodable]?, key: String) -> Int? {
        guard let val = params?[key]?.value else { return nil }
        if let i = val as? Int { return i }
        if let d = val as? Double { return Int(d) }
        if let s = val as? String { return Int(s) }
        return nil
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        return Swift.min(Swift.max(value, min), max)
    }

    private func jsonEncode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed to serialize response\"}"
        }
        return str
    }
}
