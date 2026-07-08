import Foundation
import SQLite3

/// Searches Apple Mail's Envelope Index SQLite database. See docs/reference/macos-internals/mail-data.md
/// for the rationale behind this approach (vs. Spotlight or AppleScript).
enum EmailSearch {
    struct Criteria {
        var query: String?       // free text: subject / snippet / sender
        var from: String?        // sender filter (wide text net)
        var fromEmail: String?   // sender filter (EXACT full address, incl. domain)
        var to: String?          // recipient filter
        var after: Date?
        var before: Date?
        var limit: Int = 20
        var excludeSelf: Bool = true
        var excludeBulk: Bool = false  // drop likely-automated/bulk senders
    }

    struct Hit {
        let messageID: String    // RFC Message-ID header (may be empty)
        let rowID: Int64         // Envelope Index messages.ROWID — stable local handle
        let date: Date
        let senderAddress: String
        let senderName: String?
        let subject: String
        let mailboxURL: String
        let snippet: String?
        let aiSummary: String?
    }

    enum SearchError: Error, CustomStringConvertible {
        case dbMissing(String)
        case dbUnreadable(String)
        case dbOpenFailed(String)
        case sqlFailed(String)
        case noCriteria

        var description: String {
            switch self {
            case .dbMissing(let path):
                return "envelope index not found at \(path) — is Apple Mail configured?"
            case .dbUnreadable(let path):
                return "envelope index at \(path) is not readable — grant Full Disk Access"
            case .dbOpenFailed(let msg):
                return "failed to open envelope index: \(msg)"
            case .sqlFailed(let msg):
                return "sql error: \(msg)"
            case .noCriteria:
                return "search requires at least one of: query, from, to, after, before"
            }
        }
    }

    /// Stopwords stripped from `query` before tokenization: the shared generic
    /// English set plus the email-domain words people pad mail queries with
    /// ("find the *email* about…"). Layered on `QueryTerms.commonStopwords`
    /// rather than duplicated — "message"/"mail" are noise here but could be
    /// signal in another tool, so they live at this call site, not in the
    /// shared set.
    static let queryStopwords: Set<String> =
        QueryTerms.commonStopwords.union(["email", "mail", "message"])

    /// Split a free-text query into AND-able tokens via the shared tokenizer,
    /// with email's domain stopwords. Returns an empty array if the query has
    /// no usable tokens (caller treats that as "no query filter").
    static func tokenize(_ query: String) -> [String] {
        return QueryTerms.tokenize(query, stopwords: queryStopwords)
    }

    /// Default path to the Envelope Index on this Mac. Follows the current
    /// Mail version directory (V10). If Apple bumps this, update here.
    static var defaultDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Mail/V10/MailData/Envelope Index"
    }

    /// Run a search against the Envelope Index. Database is opened read-only.
    static func run(_ criteria: Criteria, dbPath: String = defaultDatabasePath) throws -> [Hit] {
        let queryTokens: [String] = criteria.query.map(EmailSearch.tokenize) ?? []
        let hasQuery = !queryTokens.isEmpty
        let hasFrom = (criteria.from?.isEmpty == false)
        let hasFromEmail = (criteria.fromEmail?.isEmpty == false)
        let hasTo = (criteria.to?.isEmpty == false)
        if !hasQuery && !hasFrom && !hasFromEmail && !hasTo && criteria.after == nil && criteria.before == nil {
            throw SearchError.noCriteria
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { throw SearchError.dbMissing(dbPath) }
        guard fm.isReadableFile(atPath: dbPath) else { throw SearchError.dbUnreadable(dbPath) }

        var db: OpaquePointer?
        // SQLITE_OPEN_READONLY = 0x00000001. We use URI so we can be explicit.
        let uri = "file://\(dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let d = db { sqlite3_close(d) }
            throw SearchError.dbOpenFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Viewer identity (for --exclude-self). Query once per call; it's cheap (~10ms).
        let selfAddrs: Set<String> = criteria.excludeSelf ? detectSelfAddresses(db: db) : []

        // ---- build WHERE + parameter values (index-based binding) ----
        var wheres = ["m.deleted = 0"]
        var paramValues: [Any] = []

        for tok in queryTokens {
            wheres.append("""
            (
                s.subject LIKE ? COLLATE NOCASE
                OR (sm.summary IS NOT NULL AND sm.summary LIKE ? COLLATE NOCASE)
                OR a.address LIKE ? COLLATE NOCASE
                OR a.comment LIKE ? COLLATE NOCASE
            )
            """)
            let pat = "%\(tok)%"
            paramValues.append(contentsOf: [pat, pat, pat, pat])
        }
        if let f = criteria.from, !f.isEmpty {
            wheres.append("(a.address LIKE ? COLLATE NOCASE OR a.comment LIKE ? COLLATE NOCASE)")
            let pat = "%\(f)%"
            paramValues.append(contentsOf: [pat, pat])
        }
        // --from-email: EXACT full-address match (incl. domain). The scalpel
        // to --from's wide text net — postmaster@a.com ≠ postmaster@b.com.
        if let fe = criteria.fromEmail, !fe.isEmpty {
            wheres.append("a.address = ? COLLATE NOCASE")
            paramValues.append(fe)
        }
        if let t = criteria.to, !t.isEmpty {
            wheres.append("""
            EXISTS (
                SELECT 1 FROM recipients r
                JOIN addresses ra ON ra.ROWID = r.address
                WHERE r.message = m.ROWID
                  AND (ra.address LIKE ? COLLATE NOCASE OR ra.comment LIKE ? COLLATE NOCASE)
            )
            """)
            let pat = "%\(t)%"
            paramValues.append(contentsOf: [pat, pat])
        }
        if let a = criteria.after {
            wheres.append("m.date_received >= ?")
            paramValues.append(Int64(a.timeIntervalSince1970))
        }
        if let b = criteria.before {
            wheres.append("m.date_received < ?")
            paramValues.append(Int64(b.timeIntervalSince1970))
        }

        // Oversample when we're going to post-filter; else ask only for what we need.
        let postFilters = !queryTokens.isEmpty
            || (criteria.from != nil && !criteria.from!.isEmpty)
            || criteria.excludeSelf
            || criteria.excludeBulk
        let fetchLimit = postFilters ? max(criteria.limit * 10, criteria.limit) : criteria.limit
        paramValues.append(Int64(fetchLimit))

        let sql = """
        SELECT
            m.ROWID                     AS rowid,
            m.date_received             AS date_received,
            a.address                   AS sender_addr,
            a.comment                   AS sender_name,
            s.subject                   AS subject,
            mb.url                      AS mailbox_url,
            g.message_id_header         AS msgid,
            sm.summary                  AS snippet,
            g.generated_summary         AS gen_summary_rowid
        FROM messages m
        JOIN addresses a  ON a.ROWID  = m.sender
        JOIN subjects s   ON s.ROWID  = m.subject
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
        LEFT JOIN summaries sm          ON sm.ROWID = m.summary
        WHERE \(wheres.joined(separator: " AND "))
        ORDER BY m.date_received DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw SearchError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, v) in paramValues.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let s as String:
                // SQLITE_TRANSIENT = -1, asks SQLite to copy the string.
                let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int64:
                sqlite3_bind_int64(stmt, idx, n)
            default:
                throw SearchError.sqlFailed("unsupported bind value at \(i): \(type(of: v))")
            }
        }

        // ---- fetch + post-filter ----
        let term = WordBoundary()
        var hits: [Hit] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let dateRecv = sqlite3_column_int64(stmt, 1)
            let senderAddr = columnString(stmt, 2) ?? ""
            let senderName = columnString(stmt, 3)
            let subject = columnString(stmt, 4) ?? ""
            let mailboxURL = columnString(stmt, 5) ?? ""
            let msgid = columnString(stmt, 6) ?? ""
            let snippet = columnString(stmt, 7)
            let genSummaryRowID = sqlite3_column_int64(stmt, 8)

            // --exclude-self
            if !selfAddrs.isEmpty && selfAddrs.contains(senderAddr.lowercased()) {
                continue
            }

            // --exclude-spam / --humans-only: drop likely automated/bulk
            // senders. Applied before the limit break so the caller still
            // gets up to `limit` human results.
            if criteria.excludeBulk
                && BulkSenderClassifier.isLikelyBulk(address: senderAddr, name: senderName) {
                continue
            }

            // Word-boundary post-filter on sender for -f
            if let f = criteria.from, !f.isEmpty {
                if !term.senderMatches(f, address: senderAddr, name: senderName) {
                    continue
                }
            }

            // Word-boundary post-filter on -q: every token must match somewhere
            // across subject / snippet / sender.
            if !queryTokens.isEmpty {
                let allMatched = queryTokens.allSatisfy { tok in
                    term.contains(tok, in: subject)
                        || term.contains(tok, in: snippet ?? "")
                        || term.senderMatches(tok, address: senderAddr, name: senderName)
                }
                if !allMatched { continue }
            }

            let ai = (genSummaryRowID > 0) ? decodeGeneratedSummary(db: db, rowID: genSummaryRowID) : nil

            hits.append(Hit(
                messageID: msgid,
                rowID: rowid,
                date: Date(timeIntervalSince1970: TimeInterval(dateRecv)),
                senderAddress: senderAddr,
                senderName: (senderName?.isEmpty == false) ? senderName : nil,
                subject: subject,
                mailboxURL: mailboxURL,
                snippet: snippet?.isEmpty == false ? snippet : nil,
                aiSummary: ai
            ))

            if hits.count >= criteria.limit { break }
        }

        return hits
    }

    // MARK: - Distinct-sender rollup

    /// One distinct sender address in a result set, with its span.
    struct SenderSummary {
        let address: String   // original-cased address
        let count: Int
        let first: Date
        let last: Date
    }

    /// Group `hits` by distinct sender address (case-insensitive). Sorted by
    /// count desc, then most-recent desc, so the dominant sender leads.
    /// Returns an empty array when there are 0 or 1 distinct addresses — the
    /// caller uses that to decide whether a rollup is worth showing.
    static func senderRollup(_ hits: [Hit]) -> [SenderSummary] {
        struct Agg { var address: String; var count: Int; var first: Date; var last: Date }
        var byAddr: [String: Agg] = [:]
        for h in hits {
            let key = h.senderAddress.lowercased()
            if var agg = byAddr[key] {
                agg.count += 1
                if h.date < agg.first { agg.first = h.date }
                if h.date > agg.last { agg.last = h.date }
                byAddr[key] = agg
            } else {
                byAddr[key] = Agg(address: h.senderAddress, count: 1, first: h.date, last: h.date)
            }
        }
        guard byAddr.count > 1 else { return [] }
        return byAddr.values
            .map { SenderSummary(address: $0.address, count: $0.count, first: $0.first, last: $0.last) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
    }

    // MARK: - Message-ID → on-disk location

    struct MessageLocation {
        let rowID: Int64
        let mailboxURL: String
    }

    /// Look up an RFC Message-ID in the Envelope Index. Returns the ROWID
    /// and mailbox URL, which together let us derive the on-disk .emlx path.
    /// Returns nil if the Message-ID isn't known to Mail.
    static func resolveMessageID(_ messageID: String, dbPath: String = defaultDatabasePath) throws -> MessageLocation? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { throw SearchError.dbMissing(dbPath) }
        guard fm.isReadableFile(atPath: dbPath) else { throw SearchError.dbUnreadable(dbPath) }

        var db: OpaquePointer?
        let uri = "file://\(dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let d = db { sqlite3_close(d) }
            throw SearchError.dbOpenFailed(msg)
        }
        defer { sqlite3_close(db) }

        // `message_id_header` is stored WITH angle brackets (`<id@host>`), but
        // Message-IDs reach us in both forms: `search` surfaces the bracketed
        // header value, while `inbox`/AppleScript surface the bare `message id`
        // — and LLMs routinely strip the brackets when echoing an ID back.
        // Match bracket-insensitively so all three forms resolve.
        let sql = """
        SELECT m.ROWID, mb.url
        FROM messages m
        JOIN message_global_data g ON g.ROWID = m.global_message_id
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE m.deleted = 0
          AND trim(g.message_id_header, '<>') = ?
        LIMIT 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw SearchError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        let bareID = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        sqlite3_bind_text(stmt, 1, bareID, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let rowid = sqlite3_column_int64(stmt, 0)
        let url = columnString(stmt, 1) ?? ""
        return MessageLocation(rowID: rowid, mailboxURL: url)
    }

    // MARK: - Self detection

    private static func detectSelfAddresses(db: OpaquePointer) -> Set<String> {
        let sql = """
        SELECT a.address, COUNT(*) AS n
        FROM messages m
        JOIN addresses a  ON a.ROWID  = m.sender
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE m.deleted = 0
          AND (mb.url LIKE '%Sent%' OR mb.url LIKE '%sent%')
        GROUP BY a.address
        HAVING n >= 2
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = columnString(stmt, 0), !s.isEmpty {
                out.insert(s.lowercased())
            }
        }
        return out
    }

    // MARK: - AI summary decode

    /// generated_summaries.summary is an NSKeyedArchiver'd NSAttributedString.
    /// Decode and return its plain-text contents.
    private static func decodeGeneratedSummary(db: OpaquePointer, rowID: Int64) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT summary FROM generated_summaries WHERE ROWID = ?", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blobPtr = sqlite3_column_blob(stmt, 0) else { return nil }
        let blobLen = Int(sqlite3_column_bytes(stmt, 0))
        guard blobLen > 0 else { return nil }
        let data = Data(bytes: blobPtr, count: blobLen)

        // NSAttributedString supports NSSecureCoding; unarchive it.
        do {
            let attr = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
            let s = attr?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }

    // MARK: - SQLite helpers

    private static func columnString(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }
}

// MARK: - Word boundary matching

struct WordBoundary {
    /// Match `term` at word boundaries in `text`. None-safe. Case-insensitive.
    func contains(_ term: String, in text: String) -> Bool {
        if text.isEmpty { return false }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        guard let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    /// For sender matching: ignore the email domain, look only at the
    /// local-part and at the display name, with deliberately different
    /// strictness for each:
    ///
    /// - **Display name** → word-START (prefix) match, so a `from` term that
    ///   is a natural name prefix matches — "sam" matches "Samira Quinn".
    /// - **Local-part** → full word boundary, so role addresses don't leak
    ///   in — "mark" must NOT match "marketing@…" (the documented noise case).
    ///
    /// A bare local-part with no display name (e.g. "samiraquinn@…" and no
    /// name) won't match a prefix like "sam"; that's the rare cost of keeping
    /// addresses noise-free. See docs/reference/macos-internals/mail-data.md.
    func senderMatches(_ term: String, address: String, name: String?) -> Bool {
        return contains(term, in: localPart(of: address))
            || hasPrefixWord(term, in: name ?? "")
    }

    /// Match `term` at the start of a word in `text` (trailing boundary not
    /// required). Case-insensitive, none-safe. "sam" matches "Samira" but
    /// not "flotsam".
    private func hasPrefixWord(_ term: String, in text: String) -> Bool {
        if text.isEmpty { return false }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        guard let re = try? NSRegularExpression(pattern: "\\b\(escaped)", options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    private func localPart(of address: String) -> String {
        if let at = address.firstIndex(of: "@") {
            return String(address[address.startIndex..<at])
        }
        return address
    }
}
