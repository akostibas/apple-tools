import Foundation
import SQLite3

/// Post-verify hook for `Mail.app` draft creation. ADR-032 reference
/// implementation #2 (after `IMessageSender.makeVerifyHook`).
///
/// The shape mirrors the iMessage chat.db poll: capture a "before" max ROWID
/// against Mail's Envelope Index, run the AppleScript that creates the draft,
/// and — only when the runner classifies the outcome as `outcome_unknown` —
/// poll the Envelope Index for a Drafts-mailbox row newer than the snapshot
/// whose subject matches and whose recipients include the intended address.
///
/// ## Why no `.absent` return
///
/// The iMessage hook can return `.absent` (definitively not delivered) because
/// chat.db's outgoing-status state machine is reliable: a `.rejected` row is
/// proof of non-delivery. Mail's Envelope Index, by contrast, is updated
/// asynchronously by Mail.app — a draft created via AppleScript may not appear
/// in the index for several seconds even on a healthy machine. Returning
/// `.absent` (which would upgrade `outcome_unknown` → `failed` and license the
/// agent to retry) on an index lag would risk duplicate drafts.
///
/// This verifier therefore only ever upgrades `outcome_unknown` → `success`.
/// If the matching draft doesn't appear within the deadline, the outcome
/// stays `outcome_unknown` and the agent handles ambiguity through its usual
/// channels (idempotency cache on retry, etc.).
///
/// ## Live diagnostic
///
/// `probe-macos/Diagnostics/post-verify-live-check.swift mail` exercises this
/// path end-to-end against real Mail.app. Run it if you change the SQL query
/// below or after a macOS update that may bump the Envelope Index version
/// (currently V10). It is intentionally unbuilt — invoke via
/// `swift probe-macos/Diagnostics/post-verify-live-check.swift mail`.
public enum MailDraftVerifier {

    /// How often to re-query the Envelope Index while waiting. Cheap read.
    public static let defaultPollInterval: TimeInterval = 0.25

    /// Path override for testing. Defaults to the live Envelope Index.
    public static var databasePath: String = EmailSearch.defaultDatabasePath

    /// Snapshot the current max `messages.ROWID` in the Envelope Index. Used
    /// as the cursor passed to `verify(...)` so the poll only sees rows
    /// created after the AppleScript runs.
    ///
    /// Returns 0 on any failure — callers should treat that as a permissive
    /// cursor (the subject+recipient match still filters out unrelated rows).
    public static func snapshotMaxRowID() -> Int64 {
        var db: OpaquePointer?
        let uri = "file://\(databasePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databasePath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = db else { return 0 }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM messages", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    /// Build a hook closure to pass to `AppleScriptRunner.run`. Captures the
    /// match criteria up front; the closure does the polling when invoked.
    ///
    /// `recipient` is the to-address used in the AppleScript. `subject` is the
    /// exact subject (case-insensitive equality, after trimming).
    public static func makeVerifyHook(
        recipient: String,
        subject: String,
        sinceROWID: Int64,
        deadline: TimeInterval = 5.0
    ) -> () -> AppleScriptRunner.VerifyResult {
        return {
            return verify(recipient: recipient, subject: subject, sinceROWID: sinceROWID, deadline: deadline)
        }
    }

    /// Poll the Envelope Index for a matching draft. Returns `.confirmed(id)`
    /// (id = `messages.ROWID` as a string) as soon as a row appears, or
    /// `.inconclusive` on deadline.
    public static func verify(
        recipient: String,
        subject: String,
        sinceROWID: Int64,
        deadline: TimeInterval = 5.0,
        pollInterval: TimeInterval = defaultPollInterval
    ) -> AppleScriptRunner.VerifyResult {
        let start = Date()
        let normalizedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // Escape LIKE metacharacters in the recipient so an address containing
        // `_` (common — `john_doe@x.com`) or `%` isn't treated as a wildcard,
        // which let a near-miss draft row falsely confirm (issue #33). Paired
        // with the `ESCAPE '\'` clause in the query.
        let recipientPattern = "%\(SQLEscaping.escapeLIKE(recipient))%"

        while Date().timeIntervalSince(start) < deadline {
            if let rowid = findMatchingDraft(
                recipient: recipientPattern,
                subject: normalizedSubject,
                sinceROWID: sinceROWID
            ) {
                return .confirmed(id: String(rowid))
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return .inconclusive
    }

    // MARK: - SQLite query

    /// One-shot lookup against the Envelope Index. Joins `messages` →
    /// `subjects` and `recipients` → `addresses`, filtered to mailboxes whose
    /// URL contains `/Drafts` (matches `imap://...[Gmail]/Drafts`, `local://Local/Drafts`,
    /// `imap://.../Drafts`, etc.). Returns the newest matching row id, or nil.
    static func findMatchingDraft(recipient: String, subject: String, sinceROWID: Int64) -> Int64? {
        var db: OpaquePointer?
        let uri = "file://\(databasePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databasePath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = db else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT m.ROWID
        FROM messages m
        JOIN subjects s   ON s.ROWID  = m.subject
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE m.ROWID > ?
          AND m.deleted = 0
          AND mb.url LIKE '%/Drafts%'
          -- TRIM both sides: the bound subject is already trimmed, and Mail may
          -- store the draft subject with the caller's leading/trailing
          -- whitespace intact. Comparing trimmed==untrimmed meant a draft whose
          -- subject had surrounding whitespace could never confirm (issue #36).
          AND TRIM(s.subject) = ? COLLATE NOCASE
          AND EXISTS (
            SELECT 1 FROM recipients r
            JOIN addresses a ON a.ROWID = r.address
            WHERE r.message = m.ROWID
              AND a.address LIKE ? ESCAPE '\\' COLLATE NOCASE
          )
        ORDER BY m.ROWID DESC
        LIMIT 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, sinceROWID)
        sqlite3_bind_text(stmt, 2, subject, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, recipient, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }
}
