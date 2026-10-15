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
            sender INTEGER, deleted INTEGER DEFAULT 0, date_received INTEGER, global_message_id INTEGER, summary INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT, generated_summary INTEGER);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO subjects VALUES (1, 'Invitation: EFKaylaire');
        INSERT INTO mailboxes VALUES (1, 'imap://A/INBOX');
        INSERT INTO addresses VALUES (1, 'kayla@sway.co', 'Kayla'), (2, 'claire@sway.co', 'Claire');
        INSERT INTO message_global_data VALUES (1, '<invite@x>', NULL), (2, '<reply@x>', NULL);
        INSERT INTO messages VALUES (1, 1, NULL, 1, 1, 0, 100, 1, NULL), (2, 1, 'Re: ', 1, 2, 0, 200, 2, NULL);
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
}
