import SQLite3
import XCTest
@testable import AppleToolsLib

final class EmailSearchSubjectTests: XCTestCase {
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "envelope-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, subject_prefix TEXT, mailbox INTEGER,
            sender INTEGER, deleted INTEGER DEFAULT 0, date_received INTEGER, global_message_id INTEGER, summary INTEGER,
            read INTEGER DEFAULT 0);
        CREATE TABLE attachments (message INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER DEFAULT 0, unread_count INTEGER DEFAULT 0);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT, generated_summary INTEGER);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
        INSERT INTO subjects VALUES (1, 'Invitation: EFKaylaire');
        INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://A/INBOX');
        INSERT INTO addresses VALUES (1, 'kayla@sway.co', 'Kayla'), (2, 'claire@sway.co', 'Claire');
        INSERT INTO message_global_data VALUES (1, '<invite@x>', NULL), (2, '<reply@x>', NULL);
        INSERT INTO messages (ROWID, subject, subject_prefix, mailbox, sender, deleted, date_received, global_message_id, summary) VALUES (1, 1, NULL, 1, 1, 0, 100, 1, NULL), (2, 1, 'Re: ', 1, 2, 0, 200, 2, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testReplyKeepsItsPrefix() throws {
        var c = EmailSearch.Criteria()
        c.query = "EFKaylaire"
        c.excludeSelf = false
        let subjects = try EmailSearch.run(c, dbPath: dbPath).map(\.subject)
        XCTAssertEqual(subjects, ["Re: Invitation: EFKaylaire", "Invitation: EFKaylaire"])
    }

    func testInboxMergesAccountsNewestFirstAndSkipsOtherMailboxes() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        // Account B is Gmail-shaped: the message lives in All Mail and INBOX is a label.
        let sql = """
        INSERT INTO mailboxes (ROWID, url) VALUES (2, 'imap://A/Archive'), (3, 'imap://B/INBOX'),
            (4, 'imap://B/%5BGmail%5D/All%20Mail'), (5, 'imap://A/INBOX/Team%20mail');
        INSERT INTO message_global_data VALUES (3, '<gmail@x>', NULL), (4, '<archived@x>', NULL), (5, '<team@x>', NULL);
        INSERT INTO messages (ROWID, subject, mailbox, sender, date_received, global_message_id, read) VALUES
            (3, 1, 4, 1, 150, 3, 1), (4, 1, 2, 1, 900, 4, 0), (5, 1, 5, 1, 950, 5, 0);
        INSERT INTO labels VALUES (3, 3);
        INSERT INTO attachments VALUES (3), (3);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let hits = try EmailSearch.inbox(limit: 10, dbPath: dbPath)
        XCTAssertEqual(hits.map(\.messageID), ["<reply@x>", "<gmail@x>", "<invite@x>"])
        XCTAssertEqual(hits.map(\.read), [false, true, false])
        XCTAssertEqual(hits.map(\.attachmentCount), [0, 2, 0])
        XCTAssertEqual(try EmailSearch.inbox(limit: 1, dbPath: dbPath).map(\.messageID), ["<reply@x>"])
    }

    func testHasAttachmentsFiltersBeforeTheLimitAndStandsAlone() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        // Row 1 is the OLDER message; a filter applied after the limit would return nothing.
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO attachments VALUES (1), (1)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        var c = EmailSearch.Criteria()
        c.excludeSelf = false
        c.limit = 1
        c.hasAttachments = true
        let hits = try EmailSearch.run(c, dbPath: dbPath)
        XCTAssertEqual(hits.map(\.messageID), ["<invite@x>"])
        XCTAssertEqual(hits.map(\.attachmentCount), [2])

        c.hasAttachments = false
        c.query = "EFKaylaire"
        c.limit = 10
        XCTAssertEqual(try EmailSearch.run(c, dbPath: dbPath).map(\.attachmentCount), [0, 2])
    }

    func testExcludedAccountsAreLeftOutBeforeTheLimit() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        // Newer than everything in account A; "AB" must not be mistaken for "A".
        let sql = """
        INSERT INTO mailboxes (ROWID, url) VALUES (2, 'imap://B/INBOX'), (3, 'local://L/Saved'), (4, 'ews://AB/INBOX');
        INSERT INTO message_global_data VALUES (3, '<b@x>', NULL), (4, '<local@x>', NULL), (5, '<ab@x>', NULL);
        INSERT INTO messages (ROWID, subject, mailbox, sender, date_received, global_message_id) VALUES
            (3, 1, 2, 1, 900, 3), (4, 1, 3, 1, 800, 4), (5, 1, 4, 1, 50, 5);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        var c = EmailSearch.Criteria()
        c.excludeSelf = false
        c.after = Date(timeIntervalSince1970: 1)
        c.limit = 1
        c.excludedAccounts = ["B", "local"]
        XCTAssertEqual(try EmailSearch.run(c, dbPath: dbPath).map(\.messageID), ["<reply@x>"])
        c.limit = 10
        c.excludedAccounts = ["A"]
        XCTAssertEqual(try EmailSearch.run(c, dbPath: dbPath).map(\.messageID), ["<b@x>", "<local@x>", "<ab@x>"])
        XCTAssertEqual(try EmailSearch.inbox(limit: 1, excludedAccounts: ["B"], dbPath: dbPath).map(\.messageID), ["<reply@x>"])
    }

    func testAccountsAreExcludedByNameNeverByAddress() {
        let accounts = ["1": EmailSearch.Account(name: "Gmail", email: "a@x.com"), "2": EmailSearch.Account(name: "iCloud", email: "a@x.com")]
        XCTAssertEqual(EmailSearch.accountIDs(named: ["gmail", "gone"], in: accounts), ["1"])
        XCTAssertEqual(EmailSearch.accountIDs(named: ["a@x.com"], in: accounts), [])
        XCTAssertEqual(EmailSearch.accountIDs(named: ["On My Mac"], in: accounts), ["local"])
    }

    func testMoveRefusesDraftsAsSourceAndDestination() {
        for drafts in ["imap://A/Drafts", "imap://A/%5BGmail%5D/Drafts", "local://Local/Drafts", "ews://A/drafts"] {
            XCTAssertEqual(EmailTool.draftsMoveRefusal(from: drafts, to: "imap://A/Archive")?.contains("out of Drafts"), true, drafts)
            XCTAssertEqual(EmailTool.draftsMoveRefusal(from: "imap://A/Trash", to: drafts)?.contains("into Drafts"), true, drafts)
        }
        for box in ["Archive/Drafts", "Drafts%20Backup", "Trash"] {
            XCTAssertNil(EmailTool.draftsMoveRefusal(from: "imap://A/INBOX", to: "imap://A/\(box)"), box)
        }
    }

    func testMoveTakesCopiesSharingAMailboxAndRefusesCopiesSpreadOverSeveral() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let sql = """
        INSERT INTO mailboxes (ROWID, url) VALUES (2, 'imap://A/Trash'), (3, 'imap://A/Sent%20Messages');
        INSERT INTO message_global_data VALUES (3, '<twice@x>', NULL), (4, '<self@x>', NULL);
        INSERT INTO messages (ROWID, subject, subject_prefix, mailbox, sender, deleted, date_received, global_message_id, summary) VALUES (3, 1, NULL, 2, 1, 0, 300, 3, NULL), (4, 1, NULL, 2, 1, 0, 300, 3, NULL),
            (5, 1, NULL, 2, 1, 1, 300, 3, NULL), (6, 1, NULL, 1, 1, 0, 400, 4, NULL), (7, 1, NULL, 3, 1, 0, 400, 4, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let twice = try EmailSearch.copies(messageID: "twice@x", dbPath: dbPath)
        XCTAssertEqual(twice.map(\.rowID), [3, 4], "both live copies, the deleted row left out")
        XCTAssertNil(EmailTool.moveRefusal(copies: twice), "copies in one mailbox are one message")
        XCTAssertNil(EmailTool.moveRefusal(copies: try EmailSearch.copies(messageID: "<invite@x>", dbPath: dbPath)))

        let selfSent = try EmailSearch.copies(messageID: "<self@x>", dbPath: dbPath)
        let refusal = try XCTUnwrap(EmailTool.moveRefusal(copies: selfSent))
        XCTAssertTrue(refusal.contains("ambiguous"), refusal)
        XCTAssertTrue(refusal.contains("INBOX") && refusal.contains("Sent Messages"), refusal)
    }
}
