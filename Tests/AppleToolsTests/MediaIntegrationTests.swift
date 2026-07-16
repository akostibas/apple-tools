import XCTest
@testable import AppleToolsLib

/// Exercises MediaIntegration against fixture SQLite stores shaped like the
/// Podcasts (`MTLibrary.sqlite`) and Books (`BKLibrary-*.sqlite`) Core Data
/// databases. `now` is injected so the look-back window is deterministic.
final class MediaIntegrationTests: XCTestCase {
    private var dir: URL!

    // A fixed reference "now" in Core Data reference-date seconds.
    private let nowRef: Double = 1_000_000
    private var now: Date { Date(timeIntervalSinceReferenceDate: nowRef) }

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("media-fixture-\(UUID().uuidString)")
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

    /// hours=24 = 86400s. nowRef=1_000_000, so the window is [913600, 1_000_000].
    private func makePodcastsDB() -> String {
        let path = dir.appendingPathComponent("MTLibrary.sqlite").path
        runSQLite(path, """
            CREATE TABLE ZMTPODCAST (Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR);
            INSERT INTO ZMTPODCAST VALUES (1, 'The Weekly Show');
            INSERT INTO ZMTPODCAST VALUES (2, 'Inner Cosmos');
            CREATE TABLE ZMTEPISODE (
                Z_PK INTEGER PRIMARY KEY, ZPODCAST INTEGER, ZTITLE VARCHAR,
                ZLASTDATEPLAYED FLOAT, ZPLAYHEAD FLOAT, ZDURATION FLOAT, ZHASBEENPLAYED INTEGER
            );
            -- in window, half-listened
            INSERT INTO ZMTEPISODE VALUES (1, 1, 'Recent Ep', 999000, 1800, 3600, 0);
            -- in window, just started (playhead 0), most recent
            INSERT INTO ZMTEPISODE VALUES (2, 2, 'Newest Ep', 999500, 0, 2000, 0);
            -- OUT of window (played ~27h ago)
            INSERT INTO ZMTEPISODE VALUES (3, 1, 'Old Ep', 900000, 500, 1000, 1);
            -- never played (null) — must be excluded
            INSERT INTO ZMTEPISODE VALUES (4, 2, 'Unplayed Ep', NULL, 0, 1000, 0);
            """)
        return path
    }

    private func makeBooksDB() -> String {
        let path = dir.appendingPathComponent("BKLibrary-1-test.sqlite").path
        runSQLite(path, """
            CREATE TABLE ZBKLIBRARYASSET (
                Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR, ZAUTHOR VARCHAR,
                ZLASTOPENDATE FLOAT, ZREADINGPROGRESS FLOAT, ZISFINISHED INTEGER
            );
            -- in window, between the two podcasts by time
            INSERT INTO ZBKLIBRARYASSET VALUES (1, 'Future Shock', 'Alvin Toffler', 999200, 0.2, 0);
            -- out of window
            INSERT INTO ZBKLIBRARYASSET VALUES (2, 'Old Book', 'Someone', 900000, 0.9, 0);
            -- author sentinel should become nil
            INSERT INTO ZBKLIBRARYASSET VALUES (3, 'No Author Book', 'UnknownAuthor', 999100, 0.5, 1);
            """)
        return path
    }

    // MARK: - Podcasts

    func testRecentPodcastsWindowAndFields() {
        let items = MediaIntegration.recentPodcasts(
            since: now.addingTimeInterval(-86400), dbPath: makePodcastsDB())
        XCTAssertNotNil(items)
        let titles = items!.map { $0.title }
        XCTAssertEqual(titles, ["Newest Ep", "Recent Ep"], "newest first; old + never-played excluded")

        let recent = items!.first { $0.title == "Recent Ep" }!
        XCTAssertEqual(recent.source, "podcast")
        XCTAssertEqual(recent.creator, "The Weekly Show")
        XCTAssertEqual(recent.durationSeconds, 3600)
        XCTAssertEqual(recent.percent, 50, "1800/3600 = 50%")

        // Just-started episode: playhead 0 → 0%
        let newest = items!.first { $0.title == "Newest Ep" }!
        XCTAssertEqual(newest.percent, 0)
    }

    // MARK: - Books

    func testRecentBooksWindowAndAuthorSentinel() {
        let items = MediaIntegration.recentBooks(
            since: now.addingTimeInterval(-86400), dbPath: makeBooksDB())
        XCTAssertNotNil(items)
        let titles = items!.map { $0.title }
        XCTAssertEqual(titles, ["Future Shock", "No Author Book"], "newest first; old excluded")

        let future = items!.first { $0.title == "Future Shock" }!
        XCTAssertEqual(future.source, "book")
        XCTAssertEqual(future.creator, "Alvin Toffler")
        XCTAssertEqual(future.percent, 20, "0.2 → 20%")

        // "UnknownAuthor" sentinel is normalized to nil.
        let noAuthor = items!.first { $0.title == "No Author Book" }!
        XCTAssertNil(noAuthor.creator)
        XCTAssertEqual(noAuthor.percent, 50)
    }

    // MARK: - Merge

    func testRecentMergesAndSortsAcrossSources() {
        let items = MediaIntegration.recent(
            hours: 24, limit: nil, now: now,
            podcastsDBPath: makePodcastsDB(), booksDBPath: makeBooksDB())
        // Newest→oldest by last_engaged: Newest Ep (999500), Future Shock
        // (999200), No Author Book (999100), Recent Ep (999000).
        XCTAssertEqual(items.map { $0.title },
                       ["Newest Ep", "Future Shock", "No Author Book", "Recent Ep"])
        XCTAssertEqual(Set(items.map { $0.source }), ["podcast", "book"])
    }

    func testRecentRespectsLimit() {
        let items = MediaIntegration.recent(
            hours: 24, limit: 2, now: now,
            podcastsDBPath: makePodcastsDB(), booksDBPath: makeBooksDB())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0.title }, ["Newest Ep", "Future Shock"])
    }

    func testMissingBooksDBDegradesToPodcastsOnly() {
        let items = MediaIntegration.recent(
            hours: 24, limit: nil, now: now,
            podcastsDBPath: makePodcastsDB(),
            booksDBPath: dir.appendingPathComponent("does-not-exist.sqlite").path)
        XCTAssertTrue(items.allSatisfy { $0.source == "podcast" })
        XCTAssertFalse(items.isEmpty)
    }

    func testUnreadablePodcastsDBReturnsNil() {
        XCTAssertNil(MediaIntegration.recentPodcasts(
            since: now, dbPath: dir.appendingPathComponent("nope.sqlite").path))
    }
}
