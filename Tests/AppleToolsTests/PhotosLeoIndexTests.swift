import XCTest
import SQLite3
@testable import AppleToolsLib

/// Exercises the macOS 27 Photos search index (`leo.sqlite`) against fixture
/// databases. Covers the index half only — resolving UUIDs to assets needs
/// PhotoKit and a real library, so the seam is `leoMatches`.
///
/// `items.lexeme_ids` is a packed array of little-endian UInt32 lexeme ids, so
/// fixture blobs are written as hex literals: 100 -> X'64000000'.
final class PhotosLeoIndexTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("leo-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func runSQLite(_ dbPath: String, _ sql: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath]
        let stdin = Pipe()
        proc.standardInput = stdin
        try? proc.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        stdin.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "sqlite3 fixture build failed")
    }

    private func open(_ path: String) -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        return db!
    }

    /// lexeme 100 = Dog/Dogs (scene), 200 = Beach (scene), 300 = "dog" (OCR text).
    private func makeLeoDB() -> String {
        let path = dir.appendingPathComponent("leo.sqlite").path
        runSQLite(path, """
            CREATE TABLE lexicon (
                pk INTEGER PRIMARY KEY AUTOINCREMENT, lexeme_id INTEGER, type INTEGER,
                category INTEGER, content TEXT, identifier TEXT, score REAL);
            INSERT INTO lexicon VALUES (1, 100, 1, 4000, 'Dog',   'scene/493', 1.0);
            INSERT INTO lexicon VALUES (2, 100, 2, 4000, 'Dogs',  'scene/493', 1.0);
            INSERT INTO lexicon VALUES (3, 200, 1, 4000, 'Beach', 'scene/12',  1.0);
            INSERT INTO lexicon VALUES (4, 300, 1, 4120, 'dog',   '',          1.0);

            CREATE TABLE items (
                pk INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT UNIQUE, type INTEGER,
                lexeme_ids BLOB, date_created TIMESTAMP, change_timestamp TIMESTAMP,
                lexeme_scores BLOB, thumbnail_info BLOB);
            -- A: scene Dog only.
            INSERT INTO items VALUES (1,'AAAA',1,X'64000000',0,0,NULL,NULL);
            -- B: Beach, an unknown lexeme, then Dog — Dog is NOT the first entry,
            -- so a decoder that only reads the leading 4 bytes fails this row.
            INSERT INTO items VALUES (2,'BBBB',1,X'C8000000E703000064000000',0,0,NULL,NULL);
            -- C: OCR "dog" only — the word appears IN the photo, no dog depicted.
            INSERT INTO items VALUES (3,'CCCC',1,X'2C010000',0,0,NULL,NULL);
            -- D: Beach only.
            INSERT INTO items VALUES (4,'DDDD',1,X'C8000000',0,0,NULL,NULL);
            """)
        return path
    }

    func testMatchesSceneLabelAndItsSynonyms() {
        let db = open(makeLeoDB())
        defer { sqlite3_close(db) }

        let match = PhotosIntegration.leoMatches(db: db, query: "dog")
        XCTAssertNotNil(match, "a readable index must not report as unqueryable")
        XCTAssertEqual(match!.identifiers.sorted(), ["AAAA/L0/001", "BBBB/L0/001"])
        XCTAssertEqual(match!.labels.sorted(), ["Dog", "Dogs"],
                       "synonyms share a lexeme_id and should both be reported")
    }

    /// The decisive one: an item whose matching lexeme sits mid-blob proves the
    /// stride decode. Regression guard for reading only the first element.
    func testMatchesLexemeInMiddleOfPackedBlob() {
        let db = open(makeLeoDB())
        defer { sqlite3_close(db) }

        let match = PhotosIntegration.leoMatches(db: db, query: "dog")
        XCTAssertTrue(match!.identifiers.contains("BBBB/L0/001"),
                      "lexeme 100 is the third of three ids in this item's blob")
    }

    /// Category 4120 is text scanned out of the image, not a depiction. Folding
    /// it into content search makes "dog" match a sign reading DOG — and "the"
    /// match half the library.
    func testOCRTextIsNotContent() {
        let db = open(makeLeoDB())
        defer { sqlite3_close(db) }

        let match = PhotosIntegration.leoMatches(db: db, query: "dog")
        XCTAssertFalse(match!.identifiers.contains("CCCC/L0/001"),
                       "item CCCC only has the OCR lexeme, nothing depicting a dog")
    }

    /// Empty is not the same as broken: this must be an empty result, never nil.
    func testGenuineNoMatchIsEmptyNotFailure() {
        let db = open(makeLeoDB())
        defer { sqlite3_close(db) }

        let match = PhotosIntegration.leoMatches(db: db, query: "xyzzy")
        XCTAssertNotNil(match, "'no such label' must not read as 'index unreadable'")
        XCTAssertTrue(match!.identifiers.isEmpty)
    }

    func testUnrecognizedSchemaIsRejected() {
        let path = dir.appendingPathComponent("wrong.sqlite").path
        runSQLite(path, "CREATE TABLE lexicon (pk INTEGER, content TEXT);")
        let db = open(path)
        defer { sqlite3_close(db) }

        XCTAssertFalse(PhotosIntegration.validateLeoSchema(db),
                       "a store missing items/lexeme_ids must be refused, not read as empty")
    }
}
