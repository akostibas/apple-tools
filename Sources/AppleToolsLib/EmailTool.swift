import AppKit
import Foundation
import UniformTypeIdentifiers

public struct EmailTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "email",
        description: "Access Apple Mail. Actions: 'inbox' (list recent messages from all inboxes; works with Mail closed, but then carries a 'warning' that the list is only as fresh as Mail's last run), 'search' (search across all mail by query/sender/recipient/date, optionally only messages with attachments; inbox and search return previews only, with 'attachment_count' on messages that have attachments — use 'read' for the full body), 'read' (get full message by ID), 'headers' (a message's headers by ID — all, or only those in 'names'; never downloads the body), 'fetch_attachment' (retrieve an attachment file from a message), 'draft' (create a NEW draft message, saved in Drafts — does NOT send; supports file attachments by absolute path; returns the draft's 'id'), 'reply' (draft a threaded reply to an existing message by ID — the original is quoted and the recipient/subject are filled in automatically; put ONLY your new reply text in 'body', does NOT send; returns the draft's 'id'), 'discard' (move a draft to Trash by the 'id' that draft/reply returned; only drafts are accepted, received or sent mail is refused; needs Mail running), 'mailboxes' (list each account's mailboxes with counts), 'move' (move a message by ID to a mailbox, in the same or another account; refused for Gmail accounts and for the Drafts mailbox; needs Mail running).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "inbox, search, read, headers, fetch_attachment, draft, reply, discard, mailboxes, or move"),
                "mailbox": PropertySchema(type_: "string", description: "Mailbox name as listed by 'mailboxes', e.g. 'Archive' or 'Archive/2025'; case-insensitive. For search, only messages in it (Gmail: with that label). For move, the destination",
                    summary: "Mailbox name (search: filter; move: destination)", actions: ["search", "move"]),
                "account": PropertySchema(type_: "string", description: "Account name or address as shown in results' 'account'/'account_email'. Narrows 'mailbox' when the name exists in several accounts. For move, defaults to the message's own account when it has that mailbox",
                    summary: "Account name/address for --mailbox", actions: ["search", "move", "mailboxes"]),
                "include_disabled": PropertySchema(type_: "boolean", description: "Also list accounts whose Mail is switched off in System Settings, marked 'disabled': true. Default false (for mailboxes)",
                    summary: "Also list accounts with Mail switched off", actions: ["mailboxes"]),
                "exclude_accounts": PropertySchema(
                    type_: "array",
                    description: "Accounts to leave out, by name as shown in results' 'account'; case-insensitive. Applied before 'limit'. A name that matches no account is ignored (for inbox and search)",
                    items: ItemsSchema(type_: "string"),
                    summary: "Account names to leave out", actions: ["inbox", "search"]
                ),
                "limit": PropertySchema(type_: "integer", description: "Max messages to return (for inbox and search, default 20, max 50)",
                    summary: "Max messages (default 20, max 50)", actions: ["inbox", "search"]),
                "id": PropertySchema(type_: "string", description: "Message ID (for read, headers, fetch_attachment, reply, move). For discard, the draft id that draft or reply returned, which is not a Message ID",
                    summary: "Message ID (discard: the id draft/reply returned)", actions: ["read", "headers", "fetch_attachment", "reply", "discard", "move"]),
                "names": PropertySchema(
                    type_: "array",
                    description: "Header names to return, matched case-insensitively, e.g. ['Sender', 'X-Google-Calendar-Notification']. Omit for all headers. Absent headers are left out (for headers)",
                    items: ItemsSchema(type_: "string"),
                    summary: "Header names to return (default: all)", actions: ["headers"]
                ),
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
                "start": PropertySchema(type_: "string", description: "ISO 8601 date lower bound, e.g. '2025-01-01' or '2025-01-01T00:00:00' (for search)",
                    summary: "ISO 8601 lower bound (e.g. 2025-01-01)", actions: ["search"]),
                "end": PropertySchema(type_: "string", description: "ISO 8601 date upper bound (for search)",
                    summary: "ISO 8601 upper bound", actions: ["search"]),
                "exclude_self": PropertySchema(type_: "boolean", description: "Drop results where the viewer is the sender; default true (for search)",
                    summary: "Drop messages you sent (default true)", actions: ["search"]),
                "has_attachments": PropertySchema(type_: "boolean", description: "Only messages with at least one attachment; counts as a filter on its own. Results carry 'attachment_count' (for search)",
                    summary: "Only messages with attachments", actions: ["search"]),
                "cc": PropertySchema(type_: "string", description: "CC email address (for draft; for reply, an EXTRA cc added on top of the reply's existing recipients)",
                    summary: "CC address (reply: extra cc on top of existing)", actions: ["draft", "reply"]),
                "subject": PropertySchema(type_: "string", description: "Email subject (for draft; ignored for reply — the 'Re:' subject is taken from the original)",
                    summary: "Email subject (draft only; reply reuses the Re: subject)", actions: ["draft"]),
                "body": PropertySchema(type_: "string", description: "Email body text. For draft, the whole message. For reply, ONLY your new reply text — the original message is quoted automatically, so do NOT paste or '>'-quote it yourself.",
                    summary: "Body text (reply: only your new reply, original is quoted)", actions: ["draft", "reply"]),
                "reply_all": PropertySchema(type_: "boolean", description: "For reply: reply to all recipients (To + Cc) instead of just the sender. Default false.",
                    summary: "Reply to all recipients, not just the sender (default false)", actions: ["reply"]),
                "attachments": PropertySchema(
                    type_: "array",
                    description: "Absolute file paths to attach (for draft and reply). '~' is expanded. Each path must exist and be ≤35MB; max 10 attachments.",
                    items: ItemsSchema(type_: "string"),
                    summary: "Absolute file paths to attach (≤35MB, max 10)", actions: ["draft", "reply"]
                ),
            ],
            required: ["action"]
        ),
        cliSummary: "Read, search, draft, reply to, and discard drafts of Apple Mail messages.",
        actions: [
            ActionHelp(name: "inbox", summary: "List recent messages from all inboxes",
                example: "apple-tools email inbox [--limit <n>]"),
            ActionHelp(name: "search", summary: "Search all mail by query, sender, recipient, or date",
                example: "apple-tools email search [--query <text>] [--from <name>] [--start <date>] [--has_attachments] ..."),
            ActionHelp(name: "read", summary: "Get a full message by ID",
                example: "apple-tools email read --id <id>", required: ["id"]),
            ActionHelp(name: "headers", summary: "Get a message's headers by ID, without the body",
                example: "apple-tools email headers --id <id> [--names Sender,X-Google-Calendar-Notification]", required: ["id"]),
            ActionHelp(name: "draft", summary: "Create a new draft — does not send",
                example: "apple-tools email draft --to <addr> [--subject <t>] [--body <t>] [--cc <a>] [--attachments <p>]", required: ["to"]),
            ActionHelp(name: "reply", summary: "Draft a threaded reply to a message — does not send",
                example: "apple-tools email reply --id <id> --body <text> [--reply_all] [--cc <a>] [--attachments <p>]", required: ["id", "body"]),
            ActionHelp(name: "discard", summary: "Move a draft to Trash (drafts only; Mail must be running)",
                example: "apple-tools email discard --id <id>", required: ["id"]),
            ActionHelp(name: "fetch_attachment", summary: "Retrieve an attachment file from a message",
                example: "apple-tools email fetch_attachment --id <id> [--filename <name>]", required: ["id"]),
            ActionHelp(name: "mailboxes", summary: "List each account's mailboxes with message counts",
                example: "apple-tools email mailboxes [--account <name>] [--include_disabled]"),
            ActionHelp(name: "move", summary: "Move a message to a mailbox (not Gmail; Mail must be running)",
                example: "apple-tools email move --id <id> --mailbox <name> [--account <name>]", required: ["id", "mailbox"]),
        ]
    )

    public let host: ToolHost

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "inbox":            .read,
        "search":           .read,
        "read":             .read,
        "headers":          .read,
        "fetch_attachment": .read,
        "draft":            .readWrite,
        "reply":            .readWrite,
        "discard":          .readWrite,
        "mailboxes":        .read,
        "move":             .readWrite,
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
            return inbox(limit: limit, excludedAccounts: excludedAccounts(params))
        case "search":
            return search(params: params)
        case "read":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            return read(id: id)
        case "headers":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let names = (params?["names"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
            return headers(id: id, names: names)
        case "draft":
            guard let to = params?["to"]?.value as? String, !to.isEmpty else {
                return ("missing required parameter: to", true)
            }
            let subject = params?["subject"]?.value as? String ?? ""
            let body = params?["body"]?.value as? String ?? ""
            let cc = params?["cc"]?.value as? String
            let attachments = (params?["attachments"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
            return draft(to: to, subject: subject, body: body, cc: cc, attachments: attachments)
        case "reply":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            guard let body = params?["body"]?.value as? String, !body.isEmpty else {
                return ("missing required parameter: body", true)
            }
            let replyAll = (params?["reply_all"]?.value as? Bool) ?? false
            let cc = params?["cc"]?.value as? String
            let attachments = (params?["attachments"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
            return reply(id: id, body: body, replyAll: replyAll, cc: cc, attachments: attachments)
        case "discard":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            return discard(id: id)
        case "fetch_attachment":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let filename = params?["filename"]?.value as? String
            return fetchAttachment(id: id, filename: filename)
        case "mailboxes":
            return listMailboxes(account: params?["account"]?.value as? String,
                                 includeDisabled: params?["include_disabled"]?.value as? Bool ?? false)
        case "move":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            guard let box = params?["mailbox"]?.value as? String, !box.isEmpty else {
                return ("missing required parameter: mailbox", true)
            }
            return move(id: id, mailbox: box, account: params?["account"]?.value as? String)
        default:
            return ("unknown action: \(action) (use inbox, search, read, headers, fetch_attachment, draft, reply, discard, mailboxes, or move)", true)
        }
    }

    // MARK: - Mailboxes / move

    private func listMailboxes(account: String?, includeDisabled: Bool) -> (String, Bool) {
        let boxes: [EmailSearch.Mailbox]
        do { boxes = try EmailSearch.mailboxes() } catch { return ("\(error)", true) }
        var ids = Array(Set(boxes.map { $0.accountID })).sorted()
        if let a = account, !a.isEmpty {
            ids = ids.filter { accountMatches($0, a) }
            if ids.isEmpty { return ("no account matching '\(a)'. Accounts: \(accountNames(boxes))", true) }
        } else if !includeDisabled {
            // Naming an account shows it even when Mail is switched off for it.
            ids = ids.filter { EmailSearch.accounts[$0]?.mailEnabled ?? true }
        }
        let accounts: [[String: Any]] = ids.map { id in
            var entry = accountFields(id)
            if EmailSearch.accounts[id]?.mailEnabled == false { entry["disabled"] = true }
            entry["can_move"] = !EmailSearch.isGmail(accountID: id, in: boxes)
            entry["mailboxes"] = boxes.filter { $0.accountID == id }.map {
                ["name": $0.name, "total": $0.total, "unread": $0.unread] as [String: Any]
            }
            return entry
        }
        return (jsonEncode(["accounts": accounts]), false)
    }

    /// Copies sharing an id are one message only while they share a mailbox; nil means `move` may take them all.
    static func moveRefusal(copies: [EmailSearch.MessageLocation]) -> String? {
        let urls = Set(copies.map(\.mailboxURL))
        guard urls.count > 1 else { return nil }
        let places = urls.sorted().map { url in
            EmailSearch.mailboxName(url) + ((EmailSearch.accountFields(url)["account"] as? String).map { " (\($0))" } ?? "")
        }
        return "this id is ambiguous: copies of the message are in \(places.joined(separator: ", ")), and move can't tell which one you mean. Move it in Mail instead."
    }

    /// Mail saves whatever sits in Drafts again by itself, so a message moved out comes back a minute later.
    static func draftsMoveRefusal(from: String, to: String) -> String? {
        func isDrafts(_ url: String) -> Bool {
            ["drafts", "[gmail]/drafts"].contains(EmailSearch.mailboxName(url).lowercased())
        }
        if isDrafts(from) {
            return "can't move a message out of Drafts: Mail keeps saving drafts by itself, so it would come back. Use discard to trash a draft, or move it in Mail."
        }
        if isDrafts(to) {
            return "can't move a message into Drafts: Mail would treat it as a draft and keep bringing it back there. Use draft or reply to make a draft."
        }
        return nil
    }

    private func move(id: String, mailbox: String, account: String?) -> (String, Bool) {
        let copies: [EmailSearch.MessageLocation]
        let boxes: [EmailSearch.Mailbox]
        do {
            copies = try EmailSearch.copies(messageID: id)
            boxes = try EmailSearch.mailboxes()
        } catch {
            return ("\(error)", true)
        }
        guard let loc = copies.first else { return ("message not found: \(id)", true) }
        if let refusal = Self.moveRefusal(copies: copies) { return (refusal, true) }
        guard let source = boxes.first(where: { $0.url == loc.mailboxURL }) else {
            return ("can't tell which mailbox this message is in", true)
        }
        let target: EmailSearch.Mailbox
        switch resolveMailbox(mailbox, account: account, preferAccount: source.accountID, in: boxes) {
        case .failure(let msg): return (msg, true)
        case .success(let t): target = t
        }
        for acct in Set([source.accountID, target.accountID]) where EmailSearch.isGmail(accountID: acct, in: boxes) {
            let name = accountFields(acct)["account"] as? String ?? acct
            return ("can't move messages in Gmail accounts (\(name)): Gmail reverts label removals made through Mail. Move it in Mail or Gmail instead.", true)
        }
        if let refusal = Self.draftsMoveRefusal(from: source.url, to: target.url) { return (refusal, true) }
        if target.url == source.url { return ("message is already in \(target.name)", true) }

        for (done, copy) in copies.enumerated() {
            do {
                try EmailIntegration.moveMessage(rowID: copy.rowID, mailboxURL: copy.mailboxURL,
                                                 toAccount: target.accountID, toMailbox: target.name)
            } catch {
                let left = done == 0 ? "message" : "\(done) of \(copies.count) copies moved to \(target.name), the rest"
                return ("move failed, \(left) left in \(source.name): \(error)", true)
            }
        }
        var result: [String: Any] = [
            "id": id,
            "from": accountFields(source.accountID).merging(["mailbox": source.name]) { a, _ in a },
            "to": accountFields(target.accountID).merging(["mailbox": target.name]) { a, _ in a },
        ]
        if copies.count > 1 { result["copies"] = copies.count }
        // Mail applies the move asynchronously; confirm every copy reached the index.
        let deadline = Date().addingTimeInterval(5)
        var confirmed = false
        while Date() < deadline {
            if let now = try? EmailSearch.copies(messageID: id), !now.isEmpty,
               now.allSatisfy({ $0.mailboxURL == target.url }) { confirmed = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        result["moved"] = confirmed ? true : "pending"
        if !confirmed { result["note"] = "Mail accepted the move but hasn't shown it in \(target.name) yet" }
        return (jsonEncode(result), false)
    }

    private enum Resolved { case success(EmailSearch.Mailbox), failure(String) }

    /// Name → mailbox. Ambiguous names prefer `preferAccount` (the message's own), else need --account.
    private func resolveMailbox(_ name: String, account: String?, preferAccount: String?,
                                in boxes: [EmailSearch.Mailbox]) -> Resolved {
        var matches = boxes.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let a = account, !a.isEmpty {
            guard boxes.contains(where: { accountMatches($0.accountID, a) }) else {
                return .failure("no account matching '\(a)'. Accounts: \(accountNames(boxes))")
            }
            matches = matches.filter { accountMatches($0.accountID, a) }
        }
        if matches.count > 1, let p = preferAccount, let own = matches.first(where: { $0.accountID == p }) {
            return .success(own)
        }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure("no mailbox named '\(name)'\(account.map { " in \($0)" } ?? ""). Run 'email mailboxes' to list them")
        default:
            let where_ = matches.compactMap { accountFields($0.accountID)["account"] as? String }.joined(separator: ", ")
            return .failure("'\(name)' exists in several accounts (\(where_)); pass --account")
        }
    }

    private func accountFields(_ accountID: String) -> [String: Any] {
        accountID == "local" ? ["account": "On My Mac"] : EmailSearch.accountFields(accountID)
    }

    private func accountMatches(_ accountID: String, _ query: String) -> Bool {
        let f = accountFields(accountID)
        return [f["account"], f["account_email"]].compactMap { $0 as? String }
            .contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    private func accountNames(_ boxes: [EmailSearch.Mailbox]) -> String {
        Set(boxes.map { $0.accountID }).compactMap { accountFields($0)["account"] as? String }.sorted().joined(separator: ", ")
    }

    public func preflight() -> (ok: Bool, message: String) {
        return EmailIntegration.preflight()
    }

    // MARK: - Inbox

    private func excludedAccounts(_ params: [String: AnyCodable]?) -> [String] {
        EmailSearch.accountIDs(named: (params?["exclude_accounts"]?.value as? [Any])?.compactMap { $0 as? String } ?? [])
    }

    private func inbox(limit: Int, excludedAccounts: [String]) -> (String, Bool) {
        let hits: [EmailSearch.Hit]
        do { hits = try EmailSearch.inbox(limit: limit, excludedAccounts: excludedAccounts) } catch { return ("\(error)", true) }

        let messages: [[String: Any]] = hits.map { h in
            var dict: [String: Any] = [
                "id": EmailIntegration.bareMessageID(h.messageID),
                "subject": h.subject,
                "from": h.senderName.map { "\($0) <\(h.senderAddress)>" } ?? h.senderAddress,
                "date": DateFormatting.iso(h.date),
                "read": h.read,
            ]
            if h.attachmentCount > 0 { dict["attachment_count"] = h.attachmentCount }
            dict.merge(EmailSearch.accountFields(h.mailboxURL)) { a, _ in a }
            return dict
        }

        var response: [String: Any] = [
            "count": messages.count,
            "messages": messages,
        ]
        // The index only moves while Mail is running to sync it.
        if !EmailIntegration.isMailRunning() {
            response["warning"] = "Mail is not running, so this is the inbox as of when it last ran and newer mail is missing. Open Mail to bring it up to date."
        }
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
        criteria.hasAttachments = (params?["has_attachments"]?.value as? Bool) == true
        criteria.excludedAccounts = excludedAccounts(params)

        if let s = params?["start"]?.value as? String, !s.isEmpty {
            guard let d = parseISODate(s) else {
                return ("unparseable 'start' date: \(s) (expected ISO 8601, e.g. 2025-01-01)", true)
            }
            criteria.after = d
        }
        if let s = params?["end"]?.value as? String, !s.isEmpty {
            guard let d = parseISODate(s) else {
                return ("unparseable 'end' date: \(s) (expected ISO 8601, e.g. 2025-01-01)", true)
            }
            criteria.before = d
        }
        let account = (params?["account"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let box = (params?["mailbox"]?.value as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            let boxes: [EmailSearch.Mailbox]
            do { boxes = try EmailSearch.mailboxes() } catch { return ("\(error)", true) }
            var matches = boxes.filter { $0.name.caseInsensitiveCompare(box) == .orderedSame }
            if let a = account { matches = matches.filter { accountMatches($0.accountID, a) } }
            if matches.isEmpty {
                return ("no mailbox named '\(box)'\(account.map { " in \($0)" } ?? ""). Run 'email mailboxes' to list them", true)
            }
            criteria.mailboxIDs = matches.map { $0.rowID }
        } else if account != nil {
            return ("--account narrows --mailbox; pass a mailbox too", true)
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
            entry.merge(EmailSearch.accountFields(h.mailboxURL)) { a, _ in a }
            if h.attachmentCount > 0 { entry["attachment_count"] = h.attachmentCount }
            if !h.labelURLs.isEmpty { entry["labels"] = h.labelURLs.map(EmailSearch.mailboxName) }
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

    // MARK: - Headers

    /// Keys are lowercased header names; each maps to every value in order.
    private func headers(id: String, names: [String]) -> (String, Bool) {
        let loc: EmailSearch.MessageLocation
        do {
            guard let l = try EmailSearch.resolveMessageID(id) else { return ("message not found", true) }
            loc = l
        } catch {
            return ("\(error)", true)
        }
        var all: [String: [String]]
        if let path = EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL),
           let onDisk = try? EmailMessage.loadHeaders(atPath: path) {
            all = onDisk
        } else {
            // Not on disk yet: Mail writes the .emlx only once something reads the message.
            do {
                all = EmailMessage.groupHeaders(
                    try EmailIntegration.headersViaAppleScript(rowID: loc.rowID, mailboxURL: loc.mailboxURL))
            } catch EmailIntegration.EmailError.notFound {
                return ("message not found", true)
            } catch let e as EmailIntegration.EmailError {
                return (e.description, true)
            } catch {
                return (error.localizedDescription, true)
            }
        }
        if !names.isEmpty {
            let wanted = Set(names.map { $0.lowercased() })
            all = all.filter { wanted.contains($0.key) }
        }
        return (jsonEncode(["id": id, "headers": all] as [String: Any]), false)
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
        response["mailbox"] = prettifyMailboxURL(loc.mailboxURL)
        response.merge(EmailSearch.accountFields(loc.mailboxURL)) { a, _ in a }
        if !loc.labelURLs.isEmpty { response["labels"] = loc.labelURLs.map(EmailSearch.mailboxName) }
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
        // A message Mail has indexed but never written to disk reads as "no
        // path" here, which is indistinguishable from an unsupported layout.
        // Ask Mail for the body before giving up: mail that is filed without
        // ever being opened is the common case, and it stays unreadable
        // forever otherwise.
        var emlx = EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL)
        if emlx == nil, downloadBody(loc) {
            emlx = EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL)
        }
        guard let path = emlx else {
            // Unsupported mailbox layout (e.g. local://), or Mail could not
            // produce the message. Fall back.
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
            // The structure is on disk but the bytes never were. Same repair as
            // a missing file: ask Mail to fetch, then read what it wrote.
            if downloadBody(loc),
               let fresh = EmailMessage.emlxPath(rowID: loc.rowID, mailboxURL: loc.mailboxURL),
               let refetched = try? EmailMessage.loadAttachment(atPath: fresh, filename: filename),
               !refetched.data.isEmpty {
                Log.info("email.fetch_attachment: Mail fetched the body (\(refetched.data.count) bytes)")
                return uploadAttachment(id: id, name: refetched.filename,
                                        mimeType: refetched.mimeType, data: refetched.data)
            }
            Log.info("email.fetch_attachment: attachment not on disk, falling back to AppleScript")
            return nil
        }

        return uploadAttachment(id: id, name: loaded.filename, mimeType: loaded.mimeType, data: loaded.data)
    }

    /// Ask Mail to download a message body, reporting only whether it worked.
    /// Failure is routine — Mail quit, offline, no Automation permission — and
    /// every caller's next move is the same fallback either way.
    private func downloadBody(_ loc: EmailSearch.MessageLocation) -> Bool {
        do {
            try EmailIntegration.downloadMessageBody(rowID: loc.rowID, mailboxURL: loc.mailboxURL)
            Log.info("email.fetch_attachment: asked Mail to download row \(loc.rowID)")
            return true
        } catch {
            Log.info("email.fetch_attachment: Mail could not download row \(loc.rowID): \(error)")
            return false
        }
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

        let since = MailDraftVerifier.snapshotMaxRowID()
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
        addDraftID(to: to, subject: subject, since: since, into: &response)
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

    // MARK: - Reply

    private func reply(id: String, body: String, replyAll: Bool, cc: String?, attachments: [String]) -> (String, Bool) {
        // Same '>' guard as draft — but for replies it also catches the common
        // failure mode where the caller pastes a hand-quoted copy of the
        // original into the body. Mail quotes the original for us.
        var warnings: [String] = []
        let lines = body.components(separatedBy: "\n")
        if lines.contains(where: { $0.hasPrefix(">") }) {
            warnings.append("Body contains lines starting with '>'. The original message is quoted automatically — 'body' should hold only your new reply text, and '>' will appear as a literal character.")
        }

        let (resolved, attachErr) = resolveAttachments(attachments)
        if let attachErr = attachErr { return (attachErr, true) }

        let since = MailDraftVerifier.snapshotMaxRowID()
        let result: EmailIntegration.ReplyResult
        do {
            result = try EmailIntegration.createReply(
                id: id, body: body, replyAll: replyAll, cc: cc, attachments: resolved)
        } catch EmailIntegration.EmailError.notFound {
            return ("message not found: \(id)", true)
        } catch let e as EmailIntegration.EmailError {
            return (e.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        var response: [String: Any] = [
            "status": "reply drafted",
            "reply_all": replyAll,
        ]
        if !result.subject.isEmpty { response["subject"] = result.subject }
        if !result.to.isEmpty { response["to"] = result.to }
        addDraftID(to: result.to, subject: result.subject, since: since, into: &response)
        if let cc = cc, !cc.isEmpty { response["cc_added"] = cc }
        if !resolved.isEmpty { response["attachments"] = resolved }
        if !warnings.isEmpty { response["warnings"] = warnings }
        return (jsonEncode(response), false)
    }

    /// Adds the saved draft's `id` (what `discard` takes), or says why there isn't one.
    private func addDraftID(to: String, subject: String, since: Int64, into response: inout [String: Any]) {
        if let id = MailDraftVerifier.savedDraftID(recipient: to, subject: subject, sinceROWID: since) {
            response["id"] = id
        } else {
            response["note"] = "Mail hasn't shown the draft in Drafts yet, so there is no id to discard it by"
        }
    }

    // MARK: - Discard

    /// Decides from the index alone whether `discard` may touch a message; nil means yes.
    static func discardRefusal(mailboxURL: String) -> String? {
        let name = EmailSearch.mailboxName(mailboxURL)
        if EmailSearch.isDraftsMailbox(mailboxURL) { return nil }
        if !mailboxURL.hasPrefix("imap:"), name.caseInsensitiveCompare("Drafts") == .orderedSame {
            return "can't discard drafts in this kind of account (On My Mac, Exchange): it hasn't been shown to work there. Delete it in Mail instead."
        }
        return "not a draft: this message is in \(name.isEmpty ? "an unknown mailbox" : name). Only drafts can be discarded; received and sent mail is never deleted."
    }

    /// The one row `discard` may act on. A sent draft's copy keeps the id, so only a row in Drafts counts.
    static func draftRow(_ rows: [EmailSearch.MessageLocation]) -> EmailSearch.MessageLocation? {
        rows.first { discardRefusal(mailboxURL: $0.mailboxURL) == nil }
    }

    private func discard(id: String) -> (String, Bool) {
        guard let documentID = UUID(uuidString: id) else {
            return ("not a draft id: discard takes the id that draft or reply returned", true)
        }
        let rows: [EmailSearch.MessageLocation]
        do { rows = try EmailSearch.rows(documentID: documentID) } catch { return ("\(error)", true) }
        guard let newest = rows.first else {
            return ("no draft with this id. It may already be gone from Mail.", true)
        }
        guard let loc = Self.draftRow(rows) else {
            return (Self.discardRefusal(mailboxURL: newest.mailboxURL) ?? "not a draft", true)
        }

        let since = MailDraftVerifier.snapshotMaxRowID()
        do {
            try EmailIntegration.discardDraft(rowID: loc.rowID, mailboxURL: loc.mailboxURL)
        } catch EmailIntegration.EmailError.notFound {
            return ("draft not discarded: Mail can't find it in Drafts any more", true)
        } catch {
            return ("draft not discarded: \(error)", true)
        }
        var result: [String: Any] = ["id": id]
        result.merge(EmailSearch.accountFields(loc.mailboxURL)) { a, _ in a }
        // Mail applies the delete asynchronously; the trashed copy shows up as a new row.
        let deadline = Date().addingTimeInterval(5)
        var landed: String?
        while Date() < deadline, landed == nil {
            let now = (try? EmailSearch.rows(documentID: documentID)) ?? []
            if !now.contains(where: { $0.rowID == loc.rowID }), let moved = now.first(where: { $0.rowID > since }) {
                landed = EmailSearch.mailboxName(moved.mailboxURL)
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        result["discarded"] = landed != nil ? true : "pending"
        if let landed = landed { result["moved_to"] = landed }
        else { result["note"] = "Mail accepted the discard but hasn't shown the draft in Trash yet" }

        // Gmail and iCloud save a new draft a second time 10-30s after the first, which brings a
        // just-discarded draft back. Stay until that has passed and trash the copy too.
        // ponytail: window is from a handful of observations; widen it if drafts are seen coming back.
        let settled = (loc.date ?? .distantPast).addingTimeInterval(Self.draftResaveWindow)
        while Date() < settled {
            Thread.sleep(forTimeInterval: 1)
            guard let back = Self.draftRow((try? EmailSearch.rows(documentID: documentID)) ?? []) else { continue }
            do {
                try EmailIntegration.discardDraft(rowID: back.rowID, mailboxURL: back.mailboxURL)
            } catch {
                result["discarded"] = "pending"
                result["note"] = "Mail saved the draft again after it was discarded, and that copy is still in Drafts: \(error)"
                break
            }
        }
        return (jsonEncode(result), false)
    }

    /// How long after a draft is saved Mail may still save it again by itself.
    static var draftResaveWindow: TimeInterval = 45

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
