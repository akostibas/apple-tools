import XCTest
@testable import AppleToolsLib

/// Tests for the read-only Voice Memos integration. The DB-backed tests build a
/// deterministic fixture store (a real SQLite file shaped like Voice Memos'
/// `CloudRecordings.db`, with `.m4a` files beside it) rather than depending on
/// the developer's own recordings — so they're hermetic and CI-safe.
final class VoiceMemosIntegrationTests: XCTestCase {

    // MARK: - Fixture

    /// A temp dir holding a fixture `CloudRecordings.db` and its audio files.
    private struct Fixture {
        let dir: URL
        var dbPath: String { dir.appendingPathComponent("CloudRecordings.db").path }
    }

    /// `ZDATE` values are seconds since the Core Data reference date
    /// (2001-01-01Z), i.e. `timeIntervalSinceReferenceDate`.
    private enum FixtureDate {
        static let alpha = 100_000_000.0  // 2004-03-...
        static let gamma = 150_000_000.0
        static let beta  = 200_000_000.0  // newest
    }

    /// Build the fixture store. Two recordings have audio on disk (available),
    /// one (gamma) intentionally does not (cloud-only/evicted).
    private func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voicememos-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sql = """
            CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZENCRYPTEDNAME VARCHAR);
            INSERT INTO ZFOLDER (Z_PK, ZENCRYPTEDNAME) VALUES (1, 'Amelia');
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK INTEGER PRIMARY KEY, ZFOLDER INTEGER, ZDATE FLOAT, ZDURATION FLOAT,
                ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR, ZUNIQUEID VARCHAR, ZAUDIODIGEST BLOB
            );
            INSERT INTO ZCLOUDRECORDING VALUES (1, 1, \(FixtureDate.alpha), 12.4, 'Alpha memo', 'alpha.m4a', 'AAA', x'0a0b0c');
            INSERT INTO ZCLOUDRECORDING VALUES (2, NULL, \(FixtureDate.beta), 61.6, 'Beta note', 'beta.m4a', 'BBB', NULL);
            INSERT INTO ZCLOUDRECORDING VALUES (3, 1, \(FixtureDate.gamma), 5.0, 'Gamma', 'gamma.m4a', 'CCC', NULL);
            """
        try runSQLite(dbPath: dir.appendingPathComponent("CloudRecordings.db").path, sql: sql)

        // alpha + beta have audio on disk; gamma deliberately does not.
        let audio = Data("fake-m4a".utf8)
        try audio.write(to: dir.appendingPathComponent("alpha.m4a"))
        try audio.write(to: dir.appendingPathComponent("beta.m4a"))

        return Fixture(dir: dir)
    }

    /// Execute SQL against a new SQLite file using the system `sqlite3` CLI.
    private func runSQLite(dbPath: String, sql: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath]
        let stdin = Pipe()
        proc.standardInput = stdin
        try proc.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        stdin.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "sqlite3 fixture build failed")
    }

    private func cleanup(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.dir)
    }

    // MARK: - list / filters

    func testListReturnsAllNewestFirst() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(dbPath: fx.dbPath))
        XCTAssertEqual(recs.map { $0.id }, ["BBB", "CCC", "AAA"], "newest first")
    }

    func testAvailabilityReflectsFilePresence() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(dbPath: fx.dbPath))
        let byID = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        XCTAssertEqual(byID["AAA"]?.available, true)
        XCTAssertEqual(byID["BBB"]?.available, true)
        XCTAssertEqual(byID["CCC"]?.available, false, "gamma has no audio file on disk")
    }

    func testFolderIsPopulatedAndNilForTopLevel() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(dbPath: fx.dbPath))
        let byID = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        XCTAssertEqual(byID["AAA"]?.folder, "Amelia")
        XCTAssertNil(byID["BBB"]?.folder ?? nil, "top-level recording has no folder")
    }

    func testDateDecodesFromCoreDataEpoch() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let rec = try XCTUnwrap(VoiceMemosIntegration.find(id: "AAA", dbPath: fx.dbPath))
        XCTAssertEqual(rec.date, Date(timeIntervalSinceReferenceDate: FixtureDate.alpha))
    }

    func testQueryFiltersByTitleSubstring() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(query: "beta", dbPath: fx.dbPath))
        XCTAssertEqual(recs.map { $0.id }, ["BBB"])
    }

    func testFolderFilterIsCaseInsensitive() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(folder: "amelia", dbPath: fx.dbPath))
        XCTAssertEqual(Set(recs.map { $0.id }), ["AAA", "CCC"])
    }

    func testDateRangeFilter() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        // A lower bound above alpha but below gamma keeps only gamma + beta.
        let start = Date(timeIntervalSinceReferenceDate: FixtureDate.alpha + 1)
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(start: start, dbPath: fx.dbPath))
        XCTAssertEqual(Set(recs.map { $0.id }), ["BBB", "CCC"])
    }

    func testLimit() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let recs = try XCTUnwrap(VoiceMemosIntegration.list(limit: 1, dbPath: fx.dbPath))
        XCTAssertEqual(recs.map { $0.id }, ["BBB"])
    }

    // MARK: - find

    func testFindResolvesAudioPathAndFolder() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let rec = try XCTUnwrap(VoiceMemosIntegration.find(id: "AAA", dbPath: fx.dbPath))
        XCTAssertEqual(rec.title, "Alpha memo")
        XCTAssertEqual(rec.audioPath, fx.dir.appendingPathComponent("alpha.m4a").path)
        XCTAssertTrue(rec.waveformPath.hasSuffix("alpha.waveform"))
    }

    func testFindUnknownIDReturnsNil() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        XCTAssertNil(VoiceMemosIntegration.find(id: "NOPE", dbPath: fx.dbPath))
    }

    func testAudioDigestDecodesToHex() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let alpha = try XCTUnwrap(VoiceMemosIntegration.find(id: "AAA", dbPath: fx.dbPath))
        XCTAssertEqual(alpha.digestHex, "0a0b0c", "blob decodes to lowercase hex")
        let beta = try XCTUnwrap(VoiceMemosIntegration.find(id: "BBB", dbPath: fx.dbPath))
        XCTAssertNil(beta.digestHex, "NULL digest → nil hex")
    }

    // MARK: - Graceful degradation

    func testListWithBogusDBPathReturnsNil() {
        XCTAssertNil(VoiceMemosIntegration.list(dbPath: "/nonexistent/CloudRecordings.db"))
    }

    func testPreflightWithBogusDBPathFails() {
        let (ok, _) = VoiceMemosIntegration.preflight(dbPath: "/nonexistent/CloudRecordings.db")
        XCTAssertFalse(ok)
    }

    func testPreflightSucceedsOnFixture() throws {
        let fx = try makeFixture(); defer { cleanup(fx) }
        let (ok, _) = VoiceMemosIntegration.preflight(dbPath: fx.dbPath)
        XCTAssertTrue(ok)
    }

    // MARK: - Date parsing

    func testParseDateAcceptsDateOnlyAndTimestamp() {
        XCTAssertNotNil(VoiceMemosIntegration.parseDate("2026-01-15"))
        XCTAssertNotNil(VoiceMemosIntegration.parseDate("2026-01-15T09:00:00Z"))
        XCTAssertNil(VoiceMemosIntegration.parseDate("not-a-date"))
    }

    func testParseEndDateWidensDateOnlyToEndOfDay() throws {
        let end = try XCTUnwrap(VoiceMemosIntegration.parseEndDate("2026-01-15"))
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: end)
        XCTAssertEqual(comps.hour, 23)
        XCTAssertEqual(comps.minute, 59)
        XCTAssertEqual(comps.second, 59)
    }
}
