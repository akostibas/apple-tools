import XCTest
import SQLite3
@testable import AppleToolsLib

/// Issue #67: a store Apple has moved must report itself as unreadable, not as
/// "nothing matched". These pin the detection mechanism — the shared schema
/// check and the per-reader column sets — against fixture databases.
final class StoreUnavailableTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeDB(_ name: String, _ sql: String) -> String {
        let path = dir.appendingPathComponent(name).path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [path]
        let stdin = Pipe()
        proc.standardInput = stdin
        try? proc.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        stdin.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "sqlite3 fixture build failed")
        return path
    }

    private func open(_ path: String) -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        return db!
    }

    // MARK: - SQLiteSchema

    func testValidatePassesWhenColumnsPresent() {
        let db = open(makeDB("ok.sqlite", "CREATE TABLE t (a INTEGER, b TEXT);"))
        defer { sqlite3_close(db) }
        XCTAssertTrue(SQLiteSchema.validate(db, expectations: [("t", ["a", "b"])]))
    }

    func testValidateIgnoresExtraColumns() {
        // Apple adds columns constantly; that must never read as a broken store.
        let db = open(makeDB("extra.sqlite", "CREATE TABLE t (a INTEGER, b TEXT, c BLOB, d REAL);"))
        defer { sqlite3_close(db) }
        XCTAssertTrue(SQLiteSchema.validate(db, expectations: [("t", ["a", "b"])]))
    }

    func testValidateFailsOnRenamedColumn() {
        let db = open(makeDB("renamed.sqlite", "CREATE TABLE t (a INTEGER, b_v2 TEXT);"))
        defer { sqlite3_close(db) }
        XCTAssertFalse(SQLiteSchema.validate(db, expectations: [("t", ["a", "b"])]))
    }

    func testValidateFailsOnMissingTable() {
        let db = open(makeDB("notable.sqlite", "CREATE TABLE other (a INTEGER);"))
        defer { sqlite3_close(db) }
        XCTAssertFalse(SQLiteSchema.validate(db, expectations: [("t", ["a"])]))
    }

    /// An empty file opens fine — SQLite is lazy — which is exactly why opening
    /// was never proof of anything.
    func testValidateFailsOnEmptyFile() {
        let path = dir.appendingPathComponent("empty.sqlite").path
        FileManager.default.createFile(atPath: path, contents: Data())
        let db = open(path)
        defer { sqlite3_close(db) }
        XCTAssertFalse(SQLiteSchema.validate(db, expectations: [("t", ["a"])]))
    }

    // MARK: - Notes

    private func notesDB(_ name: String, noteDataColumns: String) -> OpaquePointer {
        return open(makeDB(name, """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZTITLE2 TEXT,
                ZMODIFICATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER,
                ZNOTEDATA INTEGER, ZFOLDER INTEGER);
            CREATE TABLE ZICNOTEDATA (\(noteDataColumns));
        """))
    }

    func testNotesSchemaAcceptedWhenIntact() {
        let db = notesDB("notes-ok.sqlite", noteDataColumns: "Z_PK INTEGER PRIMARY KEY, ZDATA BLOB")
        defer { sqlite3_close(db) }
        XCTAssertTrue(SQLiteSchema.validate(db, expectations: NotesStoreSearch.expectations(fullText: false)))
        XCTAssertTrue(SQLiteSchema.validate(db, expectations: NotesStoreSearch.expectations(fullText: true)))
    }

    /// Losing the body blob must not strand title search, which never reads it.
    func testNotesMissingBodyBlobOnlyBreaksFullText() {
        let db = notesDB("notes-nobody.sqlite", noteDataColumns: "Z_PK INTEGER PRIMARY KEY")
        defer { sqlite3_close(db) }
        XCTAssertTrue(SQLiteSchema.validate(db, expectations: NotesStoreSearch.expectations(fullText: false)))
        XCTAssertFalse(SQLiteSchema.validate(db, expectations: NotesStoreSearch.expectations(fullText: true)))
    }

    func testNotesMovedTitleColumnFailsBothModes() {
        let db = open(makeDB("notes-moved.sqlite", """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY, ZTITLE3 TEXT, ZTITLE2 TEXT,
                ZMODIFICATIONDATE1 REAL, ZMARKEDFORDELETION INTEGER,
                ZNOTEDATA INTEGER, ZFOLDER INTEGER);
            CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB);
        """))
        defer { sqlite3_close(db) }
        XCTAssertFalse(SQLiteSchema.validate(db, expectations: NotesStoreSearch.expectations(fullText: false)))
        XCTAssertFalse(SQLiteSchema.validate(db, expectations: NotesStoreSearch.expectations(fullText: true)))
    }

    /// The whole point of #67: an unreadable store throws rather than answering
    /// "nothing matched" with a success code.
    func testNotesSearchThrowsWhenStoreMissing() {
        let saved = NotesIntegration.searchLookup
        defer { NotesIntegration.searchLookup = saved }
        NotesIntegration.searchLookup = { _, _, _ in
            throw NotesIntegration.NotesError.storeUnreadable("the Notes store is in an unrecognized format")
        }

        XCTAssertThrowsError(try NotesIntegration.searchNotes(query: "anything", folder: nil, offset: 0, limit: 10)) {
            guard case NotesIntegration.NotesError.storeUnreadable = $0 else {
                return XCTFail("expected storeUnreadable, got \($0)")
            }
            XCTAssertTrue("\($0)".contains("notes search is unavailable"))
        }
    }

    // MARK: - Reminders

    private let remindersSchema = """
        CREATE TABLE ZREMCDREMINDER (
            Z_PK INTEGER PRIMARY KEY, ZDACALENDARITEMUNIQUEIDENTIFIER TEXT,
            ZTITLE TEXT, ZCOMPLETED INTEGER, ZPARENTREMINDER INTEGER,
            ZMARKEDFORDELETION INTEGER, ZFLAGGED INTEGER, ZICSDISPLAYORDER INTEGER);
    """

    func testRemindersAvailableWhenSchemaIntact() {
        let path = makeDB("rem-ok.sqlite", remindersSchema)
        XCTAssertNil(RemindersDB.unavailableReason(dbPath: path))
    }

    func testRemindersUnavailableWhenFileMissing() {
        let reason = RemindersDB.unavailableReason(dbPath: "/nonexistent/reminders.sqlite")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("flags and subtasks are unavailable"))
    }

    /// Only an ORDER BY column — but a missing column fails the whole prepare,
    /// so it has to count as required.
    func testRemindersUnavailableWhenSortColumnMoves() {
        let path = makeDB("rem-nosort.sqlite", """
            CREATE TABLE ZREMCDREMINDER (
                Z_PK INTEGER PRIMARY KEY, ZDACALENDARITEMUNIQUEIDENTIFIER TEXT,
                ZTITLE TEXT, ZCOMPLETED INTEGER, ZPARENTREMINDER INTEGER,
                ZMARKEDFORDELETION INTEGER, ZFLAGGED INTEGER);
        """)
        XCTAssertNotNil(RemindersDB.unavailableReason(dbPath: path))
    }

    func testRemindersUnavailableWhenFlagColumnMoves() {
        let path = makeDB("rem-noflag.sqlite", """
            CREATE TABLE ZREMCDREMINDER (
                Z_PK INTEGER PRIMARY KEY, ZDACALENDARITEMUNIQUEIDENTIFIER TEXT,
                ZTITLE TEXT, ZCOMPLETED INTEGER, ZPARENTREMINDER INTEGER,
                ZMARKEDFORDELETION INTEGER, ZICSDISPLAYORDER INTEGER);
        """)
        XCTAssertNotNil(RemindersDB.unavailableReason(dbPath: path))
    }

    /// An empty file is the shape a wiped or relocated store takes.
    func testRemindersUnavailableOnEmptyFile() {
        let path = dir.appendingPathComponent("rem-empty.sqlite").path
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertNotNil(RemindersDB.unavailableReason(dbPath: path))
    }
}
