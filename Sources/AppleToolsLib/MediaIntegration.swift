import Foundation
import SQLite3

/// Read-only "media engagement" reader: what you've recently listened to or
/// read, merged across the sources that actually reach this Mac.
///
/// Two local Core Data SQLite stores back it, both under the user's own
/// `~/Library` (no TCC prompt), opened `SQLITE_OPEN_READONLY` — never written:
///
///   - **Podcasts** — `~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/
///     Documents/MTLibrary.sqlite`. Because the Podcasts app syncs over iCloud,
///     this reflects listening done on *other devices* (e.g. a phone) too — the
///     main reason the reader is useful.
///   - **Books** — `~/Library/Containers/com.apple.iBooksX/Data/Documents/
///     BKLibrary/BKLibrary-*.sqlite` (versioned filename). Reading progress +
///     last-opened, also iCloud-synced but typically sparse.
///
/// Deliberately NOT covered: Music (it has its own `music` tool), and TV/movies
/// — Apple TV keeps watch history server-side and on the TV-connected box, with
/// no local read path (see issue #57).
///
/// Core Data timestamps (`ZLASTDATEPLAYED`, `ZLASTOPENDATE`) are seconds since
/// the reference date (2001-01-01), i.e. `Date(timeIntervalSinceReferenceDate:)`.
public enum MediaIntegration {

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Model

    /// One recently-engaged item, normalized across sources.
    public struct MediaItem {
        public let source: String            // "podcast" | "book"
        public let kind: String              // "podcast_episode" | "book"
        public let title: String             // episode / book title
        public let creator: String?          // show name / author
        public let lastEngaged: Date         // last played / opened
        public let positionSeconds: Double?  // podcast playhead (nil for books / at start)
        public let durationSeconds: Double?  // podcast duration (nil if unknown / live)
        public let percent: Int?             // 0–100 progress (book, or computed for podcast)
        public let finished: Bool?
    }

    // MARK: - Paths

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// `243LU875E5` is Apple's team identifier for the Podcasts app — stable
    /// across machines, so the group-container path is constant.
    public static var podcastsDBPath: String {
        "\(home)/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
    }

    /// Books names its store `BKLibrary-<version>.sqlite`, so resolve it by
    /// prefix rather than hard-coding the version. Nil if Books was never set up.
    public static var booksDBPath: String? {
        let dir = "\(home)/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        guard let name = entries.first(where: { $0.hasPrefix("BKLibrary-") && $0.hasSuffix(".sqlite") }) else { return nil }
        return "\(dir)/\(name)"
    }

    // MARK: - Preflight

    /// Readable if the Podcasts store (the anchor) opens read-only. Books is
    /// optional — its absence just yields fewer items.
    public static func preflight(podcastsDBPath: String? = nil) -> (ok: Bool, message: String) {
        let path = podcastsDBPath ?? Self.podcastsDBPath
        guard FileManager.default.isReadableFile(atPath: path) else {
            return (false, "Podcasts database not found (is the Podcasts app set up?): \(path)")
        }
        guard let db = openDB(path: path) else {
            return (false, "could not open Podcasts database read-only")
        }
        sqlite3_close(db)
        return (true, "media databases readable")
    }

    // MARK: - Public API

    /// Everything engaged with in the last `hours`, newest first, capped at
    /// `limit` (nil = uncapped). Sources that are unreadable degrade to nothing
    /// rather than failing the whole query.
    public static func recent(hours: Int, limit: Int?,
                              now: Date = Date(),
                              podcastsDBPath: String? = nil,
                              booksDBPath: String? = nil) -> [MediaItem] {
        let since = now.addingTimeInterval(-Double(hours) * 3600)
        var items: [MediaItem] = []
        items += recentPodcasts(since: since, dbPath: podcastsDBPath ?? Self.podcastsDBPath) ?? []
        if let booksPath = booksDBPath ?? Self.booksDBPath {
            items += recentBooks(since: since, dbPath: booksPath) ?? []
        }
        items.sort { $0.lastEngaged > $1.lastEngaged }
        if let limit = limit, limit > 0, items.count > limit {
            items = Array(items.prefix(limit))
        }
        return items
    }

    // MARK: - Podcasts

    /// Episodes whose last-played time is at/after `since`. Returns nil only if
    /// the DB can't be opened or the schema doesn't match (graceful degrade);
    /// an empty window returns `[]`.
    static func recentPodcasts(since: Date, dbPath: String) -> [MediaItem]? {
        guard let db = openDB(path: dbPath) else { return nil }
        defer { sqlite3_close(db) }
        guard validate(db, "ZMTEPISODE", ["ZTITLE", "ZLASTDATEPLAYED", "ZPLAYHEAD", "ZDURATION", "ZPODCAST", "ZHASBEENPLAYED"]),
              validate(db, "ZMTPODCAST", ["Z_PK", "ZTITLE"]) else { return nil }

        let sql = """
            SELECT p.ZTITLE, e.ZTITLE, e.ZLASTDATEPLAYED, e.ZPLAYHEAD, e.ZDURATION, e.ZHASBEENPLAYED
            FROM ZMTEPISODE e
            JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
            WHERE e.ZLASTDATEPLAYED IS NOT NULL AND e.ZLASTDATEPLAYED >= ?
            ORDER BY e.ZLASTDATEPLAYED DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)

        var items: [MediaItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let episode = columnString(stmt, 1) else { continue }
            let show = columnString(stmt, 0)
            let last = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            let playhead = sqlite3_column_double(stmt, 3)
            let duration = sqlite3_column_double(stmt, 4)
            let played = sqlite3_column_int(stmt, 5) == 1
            let percent: Int? = duration > 0 ? Int((playhead / duration * 100).rounded()) : nil
            items.append(MediaItem(
                source: "podcast", kind: "podcast_episode",
                title: episode, creator: show, lastEngaged: last,
                positionSeconds: playhead > 0 ? playhead : nil,
                durationSeconds: duration > 0 ? duration : nil,
                percent: percent, finished: played))
        }
        return items
    }

    // MARK: - Books

    static func recentBooks(since: Date, dbPath: String) -> [MediaItem]? {
        guard let db = openDB(path: dbPath) else { return nil }
        defer { sqlite3_close(db) }
        guard validate(db, "ZBKLIBRARYASSET", ["ZTITLE", "ZAUTHOR", "ZLASTOPENDATE", "ZREADINGPROGRESS", "ZISFINISHED"]) else { return nil }

        let sql = """
            SELECT ZTITLE, ZAUTHOR, ZLASTOPENDATE, ZREADINGPROGRESS, ZISFINISHED
            FROM ZBKLIBRARYASSET
            WHERE ZLASTOPENDATE IS NOT NULL AND ZLASTOPENDATE >= ?
            ORDER BY ZLASTOPENDATE DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)

        var items: [MediaItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let title = columnString(stmt, 0) else { continue }
            let author = columnString(stmt, 1).flatMap { $0.isEmpty || $0 == "UnknownAuthor" ? nil : $0 }
            let last = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            let progress = sqlite3_column_double(stmt, 3)  // 0–1
            let finished = sqlite3_column_int(stmt, 4) == 1
            items.append(MediaItem(
                source: "book", kind: "book",
                title: title, creator: author, lastEngaged: last,
                positionSeconds: nil, durationSeconds: nil,
                percent: Int((progress * 100).rounded()), finished: finished))
        }
        return items
    }

    // MARK: - SQLite internals

    private static func openDB(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db = db else {
            if let d = db { sqlite3_close(d) }
            return nil
        }
        return db
    }

    /// Confirm a table exposes the columns we read, so a future macOS schema
    /// change degrades to empty rather than crashing.
    private static func validate(_ db: OpaquePointer, _ table: String, _ required: Set<String>) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        var found: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) { found.insert(String(cString: name)) }
        }
        return required.isSubset(of: found)
    }

    private static func columnString(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
}
