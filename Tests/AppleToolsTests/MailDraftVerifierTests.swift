import XCTest
import SQLite3
@testable import AppleToolsLib

final class MailDraftVerifierTests: XCTestCase {

    private var fixtureDB: String!
    private var savedPath: String!

    override func setUp() {
        super.setUp()
        savedPath = MailDraftVerifier.databasePath
        fixtureDB = NSTemporaryDirectory() + "envelope-index-test-\(UUID().uuidString).sqlite"
        buildEmptyFixture(at: fixtureDB)
        MailDraftVerifier.databasePath = fixtureDB
    }

    override func tearDown() {
        MailDraftVerifier.databasePath = savedPath
        try? FileManager.default.removeItem(atPath: fixtureDB)
        super.tearDown()
    }

    /// Missing/empty DB → snapshot returns 0 (permissive cursor); verifier
    /// returns .inconclusive after deadline without crashing.
    func testVerifyAgainstEmptyDBIsInconclusive() {
        XCTAssertEqual(MailDraftVerifier.snapshotMaxRowID(), 0,
                       "empty messages table → MAX(ROWID) is nil → snapshot is 0")

        let start = Date()
        let result = MailDraftVerifier.verify(
            recipient: "alice@example.com",
            subject: "hello",
            sinceROWID: 0,
            deadline: 0.4,
            pollInterval: 0.1
        )
        let elapsed = Date().timeIntervalSince(start)
        if case .inconclusive = result { /* ok */ } else {
            XCTFail("expected .inconclusive, got \(result)")
        }
        XCTAssertLessThan(elapsed, 1.0)
    }

    /// Matching draft present → .confirmed with the row id.
    func testVerifyFindsMatchingDraft() {
        insertDraft(rowid: 100, subject: "hello", recipient: "alice@example.com",
                    mailboxURL: "imap://acct@imap/[Gmail]/Drafts")

        let result = MailDraftVerifier.verify(
            recipient: "alice@example.com",
            subject: "hello",
            sinceROWID: 0,
            deadline: 1.0
        )
        guard case .confirmed(let id) = result else {
            XCTFail("expected .confirmed, got \(result)")
            return
        }
        XCTAssertEqual(id, "100")
    }

    /// Match candidate exists but its ROWID is at-or-below the snapshot →
    /// excluded by the `m.ROWID > ?` filter → .inconclusive.
    func testVerifySkipsRowsAtOrBelowSnapshot() {
        insertDraft(rowid: 50, subject: "hello", recipient: "alice@example.com",
                    mailboxURL: "imap://acct@imap/[Gmail]/Drafts")

        let result = MailDraftVerifier.verify(
            recipient: "alice@example.com",
            subject: "hello",
            sinceROWID: 100,
            deadline: 0.4,
            pollInterval: 0.1
        )
        if case .inconclusive = result { /* ok */ } else {
            XCTFail("snapshot=100 must hide row 50; got \(result)")
        }
    }

    /// Matching subject + recipient but mailbox isn't a Drafts mailbox →
    /// excluded by the URL filter. Guards against the agent's draft action
    /// being satisfied by an unrelated inbox row.
    func testVerifyRequiresDraftsMailbox() {
        insertDraft(rowid: 200, subject: "hello", recipient: "alice@example.com",
                    mailboxURL: "imap://acct@imap/INBOX")

        let result = MailDraftVerifier.verify(
            recipient: "alice@example.com",
            subject: "hello",
            sinceROWID: 0,
            deadline: 0.4,
            pollInterval: 0.1
        )
        if case .inconclusive = result { /* ok */ } else {
            XCTFail("INBOX row must not satisfy a draft verify; got \(result)")
        }
    }

    /// Subject matching is case-insensitive (Mail can normalize subjects).
    func testVerifyCaseInsensitiveSubject() {
        insertDraft(rowid: 300, subject: "Hello World", recipient: "alice@example.com",
                    mailboxURL: "local://Local/Drafts")

        let result = MailDraftVerifier.verify(
            recipient: "alice@example.com",
            subject: "hello world",
            sinceROWID: 0,
            deadline: 1.0
        )
        if case .confirmed = result { /* ok */ } else {
            XCTFail("expected .confirmed for case-insensitive subject match; got \(result)")
        }
    }

    // MARK: - Fixture builder

    /// Build a minimal Envelope-Index-shaped SQLite file with just the tables
    /// MailDraftVerifier touches. Schema mirrors the live DB enough for the
    /// query to bind and join correctly; ignores columns we don't read.
    private func buildEmptyFixture(at path: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let ddl = [
            "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, mailbox INTEGER, sender INTEGER, deleted INTEGER DEFAULT 0, date_received INTEGER)",
            "CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT)",
            "CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT)",
            "CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER)",
        ]
        for stmt in ddl {
            XCTAssertEqual(sqlite3_exec(db, stmt, nil, nil, nil), SQLITE_OK, "DDL failed: \(stmt)")
        }
    }

    /// Insert a draft-shaped row spread across messages/subjects/mailboxes/
    /// addresses/recipients. ROWIDs are deterministic per call so tests can
    /// assert on the returned id.
    private func insertDraft(rowid: Int64, subject: String, recipient: String, mailboxURL: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixtureDB, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let subjID = rowid * 10 + 1
        let mboxID = rowid * 10 + 2
        let addrID = rowid * 10 + 3
        let recipID = rowid * 10 + 4

        exec(db: db, "INSERT INTO subjects (ROWID, subject) VALUES (\(subjID), '\(subject)')")
        exec(db: db, "INSERT INTO mailboxes (ROWID, url) VALUES (\(mboxID), '\(mailboxURL)')")
        exec(db: db, "INSERT INTO addresses (ROWID, address, comment) VALUES (\(addrID), '\(recipient)', '')")
        exec(db: db, "INSERT INTO messages (ROWID, subject, mailbox, sender, deleted) VALUES (\(rowid), \(subjID), \(mboxID), \(addrID), 0)")
        exec(db: db, "INSERT INTO recipients (ROWID, message, address, type, position) VALUES (\(recipID), \(rowid), \(addrID), 1, 0)")
    }

    private func exec(db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK,
                       "exec failed: \(sql) — \(String(cString: sqlite3_errmsg(db)))")
    }
}
