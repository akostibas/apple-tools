import SQLite3
import XCTest
@testable import AppleToolsLib

/// An account counts as enabled when Mail is switched on for it or for its parent.
final class EmailAccountsEnabledTests: XCTestCase {
    private func makeStore(_ sql: String) throws -> String {
        let path = NSTemporaryDirectory() + "accounts-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private let accounts = """
    CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER VARCHAR, ZACCOUNTDESCRIPTION VARCHAR,
                           ZUSERNAME VARCHAR, ZPARENTACCOUNT INTEGER);
    INSERT INTO ZACCOUNT VALUES (1, 'PARENT-ON', 'iCloud', 'a@example.com', NULL),
                                (2, 'CHILD-ON', '', '', 1),
                                (3, 'OWN-ON', 'Work', 'b@example.com', NULL),
                                (4, 'PARENT-OFF', 'Old', 'c@example.com', NULL),
                                (5, 'CHILD-OFF', '', '', 4);
    """

    func testMailSwitchedOnForTheAccountOrItsParent() throws {
        // The numbers in the join table's names differ between macOS versions; use ones the code hasn't seen.
        let path = try makeStore(accounts + """
        CREATE TABLE ZDATACLASS (Z_PK INTEGER PRIMARY KEY, ZNAME BLOB);
        INSERT INTO ZDATACLASS VALUES (7, CAST('bplist00..com.apple.Dataclass.Mail..' AS BLOB)),
                                      (8, CAST('bplist00..com.apple.Dataclass.Calendars..' AS BLOB));
        CREATE TABLE Z_9ENABLEDDATACLASSES (Z_9ENABLEDACCOUNTS INTEGER, Z_5ENABLEDDATACLASSES INTEGER);
        INSERT INTO Z_9ENABLEDDATACLASSES VALUES (1, 7), (3, 7), (4, 8);
        """)
        let got = EmailSearch.loadAccounts(path: path)
        XCTAssertEqual(got["CHILD-ON"]?.mailEnabled, true)
        XCTAssertEqual(got["OWN-ON"]?.mailEnabled, true)
        XCTAssertEqual(got["CHILD-OFF"]?.mailEnabled, false, "only Calendars is on for its parent")
        XCTAssertEqual(got["CHILD-OFF"]?.name, "Old")
    }

    func testAnUnrecognisedStoreHidesNothing() throws {
        let got = EmailSearch.loadAccounts(path: try makeStore(accounts))
        XCTAssertEqual(got.count, 5)
        XCTAssertTrue(got.values.allSatisfy(\.mailEnabled))
    }
}
