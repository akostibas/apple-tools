import Foundation
import SQLite3

/// Read-only Apple Voice Memos integration.
///
/// Voice Memos stores its metadata in a Core Data-backed SQLite store and its
/// audio as plain `.m4a` files, both inside the app's group container:
///
///   ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
///     ├── CloudRecordings.db      ← Core Data store (metadata)
///     ├── <name>.m4a              ← one audio file per recording
///     └── <name>.waveform         ← optional waveform sidecar
///
/// This is READ-ONLY. The store is owned by Voice Memos, backed by Core Data
/// with WAL journaling and CloudKit-sync tables; writing could corrupt it or
/// conflict with sync. We only ever `sqlite3_open_v2(... READONLY)`.
///
/// Notable schema facts (confirmed against macOS 15):
///   - `ZCLOUDRECORDING` holds one row per recording.
///   - `ZENCRYPTEDTITLE` is the user-facing title and is stored **plaintext**
///     despite the name (e.g. "Heartland senior living tour").
///   - `ZDATE` / `ZDURATION` are Core Data timestamps/floats. `ZDATE` is
///     seconds since the reference date (2001-01-01), i.e.
///     `Date(timeIntervalSinceReferenceDate:)`.
///   - `ZPATH` is the bare `.m4a` filename, resolved against `Recordings/`.
///   - `ZFOLDER` FKs into `ZFOLDER.ZENCRYPTEDNAME` (also plaintext); NULL for
///     top-level recordings.
///
/// If Apple reorganizes the schema in a future release, `validateSchema`
/// returns false and callers degrade gracefully (empty/nil) rather than crash.
///
/// Design: stateless enum with static methods (mirrors `PhotosIntegration`,
/// `RemindersDB`).
public enum VoiceMemosIntegration {

    /// SQLite's `SQLITE_TRANSIENT` sentinel (copy bound bytes immediately). The
    /// SQLite3 module map doesn't surface the C macro, so we reconstruct it as
    /// the other DB-reading integrations do.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Types

    /// A single voice-memo recording's metadata.
    public struct Recording {
        public let id: String            // ZUNIQUEID — stable handle for export
        public let title: String         // ZENCRYPTEDTITLE (plaintext), fallback "Recording"
        public let date: Date            // ZDATE
        public let duration: Double       // ZDURATION, seconds
        public let folder: String?       // ZFOLDER.ZENCRYPTEDNAME, nil if top-level
        public let filename: String      // ZPATH — bare .m4a filename
        public let audioPath: String     // absolute path to the audio file (may not exist)
        public let available: Bool       // audio file present locally (false = cloud-only/evicted)
        public let audioDigest: Data?    // ZAUDIODIGEST — per-recording audio hash (cache validator)

        public init(id: String, title: String, date: Date, duration: Double,
                    folder: String?, filename: String, audioPath: String, available: Bool,
                    audioDigest: Data? = nil) {
            self.id = id
            self.title = title
            self.date = date
            self.duration = duration
            self.folder = folder
            self.filename = filename
            self.audioPath = audioPath
            self.available = available
            self.audioDigest = audioDigest
        }

        /// Lowercase hex of the audio digest — a stable content key that changes
        /// when the recording is trimmed/re-recorded. Used to validate cached
        /// transcripts. Nil if the store has no digest for this recording.
        public var digestHex: String? {
            audioDigest.map { $0.map { String(format: "%02x", $0) }.joined() }
        }

        /// Absolute path to the `.waveform` sidecar, if any (existence not checked).
        public var waveformPath: String {
            let base = (audioPath as NSString).deletingPathExtension
            return "\(base).waveform"
        }
    }

    // MARK: - Paths

    /// Directory holding the metadata store and audio files.
    public static var recordingsDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
    }

    /// Path to the Core Data metadata store.
    public static var databasePath: String {
        "\(recordingsDir)/CloudRecordings.db"
    }

    /// The directory holding the audio files for a given store — its parent
    /// directory. Threading this off the store path (rather than the static
    /// `recordingsDir`) lets tests point at a fixture DB whose `.m4a` files sit
    /// beside it.
    private static func audioDir(forDB dbPath: String) -> String {
        (dbPath as NSString).deletingLastPathComponent
    }

    // MARK: - Access / preflight

    /// Verify the database exists, opens read-only, and matches the expected
    /// schema. No TCC prompt: the store lives under the user's own `~/Library`.
    public static func preflight(dbPath: String? = nil) -> (ok: Bool, message: String) {
        let path = dbPath ?? databasePath
        guard FileManager.default.isReadableFile(atPath: path) else {
            return (false, "Voice Memos database not found (is Voice Memos set up?): \(path)")
        }
        guard let db = openDB(path: path) else {
            return (false, "could not open Voice Memos database read-only")
        }
        defer { sqlite3_close(db) }
        guard validateSchema(db) else {
            return (false, "Voice Memos database schema not recognized (macOS changed it?)")
        }
        return (true, "voicememos database readable")
    }

    // MARK: - Query

    /// List/search recordings, newest first. All filters are optional and AND
    /// together. Returns nil only when the database can't be opened or the
    /// schema doesn't match — an empty match set returns `[]`.
    ///
    /// - query:  case-insensitive substring on the title.
    /// - folder: exact folder name (case-insensitive).
    /// - start/end: filter on recording date.
    /// - limit:  max rows (nil = unbounded).
    public static func list(query: String? = nil,
                            folder: String? = nil,
                            start: Date? = nil,
                            end: Date? = nil,
                            limit: Int? = nil,
                            dbPath: String? = nil) -> [Recording]? {
        let path = dbPath ?? databasePath
        guard let db = openDB(path: path) else { return nil }
        defer { sqlite3_close(db) }
        guard validateSchema(db) else { return nil }
        let audioDirectory = audioDir(forDB: path)

        var sql = """
            SELECT r.ZUNIQUEID, r.ZENCRYPTEDTITLE, r.ZDATE, r.ZDURATION, r.ZPATH, f.ZENCRYPTEDNAME, r.ZAUDIODIGEST
            FROM ZCLOUDRECORDING r
            LEFT JOIN ZFOLDER f ON r.ZFOLDER = f.Z_PK
            WHERE r.ZUNIQUEID IS NOT NULL AND r.ZPATH IS NOT NULL
            """
        var binds: [Bind] = []

        if let start = start {
            sql += "\n  AND r.ZDATE >= ?"
            binds.append(.real(start.timeIntervalSinceReferenceDate))
        }
        if let end = end {
            sql += "\n  AND r.ZDATE <= ?"
            binds.append(.real(end.timeIntervalSinceReferenceDate))
        }
        if let query = query, !query.isEmpty {
            sql += "\n  AND r.ZENCRYPTEDTITLE LIKE ? ESCAPE '\\'"
            binds.append(.text("%\(SQLEscaping.escapeLIKE(query))%"))
        }
        if let folder = folder, !folder.isEmpty {
            sql += "\n  AND f.ZENCRYPTEDNAME = ? COLLATE NOCASE"
            binds.append(.text(folder))
        }

        sql += "\n  ORDER BY r.ZDATE DESC"
        // `limit` originates as a validated Int, so inlining is injection-safe
        // and avoids the awkward typing of a bound LIMIT parameter.
        if let limit = limit, limit > 0 {
            sql += "\n  LIMIT \(limit)"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        for (i, bind) in binds.enumerated() {
            bind.apply(to: stmt, at: Int32(i + 1))
        }

        let fm = FileManager.default
        var results: [Recording] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnString(stmt, 0),
                  let filename = columnString(stmt, 4) else { continue }
            let title = columnString(stmt, 1).flatMap { $0.isEmpty ? nil : $0 } ?? "Recording"
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let folderName = columnString(stmt, 5).flatMap { $0.isEmpty ? nil : $0 }
            let digest = columnBlob(stmt, 6)
            let audioPath = "\(audioDirectory)/\(filename)"
            let available = fm.fileExists(atPath: audioPath)
            results.append(Recording(id: id, title: title, date: date, duration: duration,
                                     folder: folderName, filename: filename,
                                     audioPath: audioPath, available: available,
                                     audioDigest: digest))
        }
        return results
    }

    /// Fetch a single recording by its `ZUNIQUEID`. Returns nil if not found or
    /// the database is unreadable.
    public static func find(id: String, dbPath: String? = nil) -> Recording? {
        let path = dbPath ?? databasePath
        guard let db = openDB(path: path) else { return nil }
        defer { sqlite3_close(db) }
        guard validateSchema(db) else { return nil }
        let audioDirectory = audioDir(forDB: path)

        let sql = """
            SELECT r.ZUNIQUEID, r.ZENCRYPTEDTITLE, r.ZDATE, r.ZDURATION, r.ZPATH, f.ZENCRYPTEDNAME, r.ZAUDIODIGEST
            FROM ZCLOUDRECORDING r
            LEFT JOIN ZFOLDER f ON r.ZFOLDER = f.Z_PK
            WHERE r.ZUNIQUEID = ?
            LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let rid = columnString(stmt, 0),
              let filename = columnString(stmt, 4) else {
            return nil
        }
        let title = columnString(stmt, 1).flatMap { $0.isEmpty ? nil : $0 } ?? "Recording"
        let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
        let duration = sqlite3_column_double(stmt, 3)
        let folderName = columnString(stmt, 5).flatMap { $0.isEmpty ? nil : $0 }
        let digest = columnBlob(stmt, 6)
        let audioPath = "\(audioDirectory)/\(filename)"
        let available = FileManager.default.fileExists(atPath: audioPath)
        return Recording(id: rid, title: title, date: date, duration: duration,
                         folder: folderName, filename: filename,
                         audioPath: audioPath, available: available,
                         audioDigest: digest)
    }

    // MARK: - Date parsing (input)

    /// Parse an ISO-8601 date (with or without time). Mirrors the lenient
    /// acceptance of `PhotosIntegration.parseDate` without coupling to it.
    public static func parseDate(_ str: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: str) { return d }

        let basic = ISO8601DateFormatter()
        if let d = basic.date(from: str) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = format
            if let d = df.date(from: str) { return d }
        }
        return nil
    }

    /// Parse an end-of-range date. A date-only string widens to local end-of-day
    /// so `--end 2026-06-30` includes everything recorded that day.
    public static func parseEndDate(_ str: String) -> Date? {
        guard let d = parseDate(str) else { return nil }
        let hasTime = str.contains("T") || str.contains(":")
        if hasTime { return d }
        return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d) ?? d
    }

    // MARK: - Internals

    private enum Bind {
        case text(String)
        case real(Double)

        func apply(to stmt: OpaquePointer?, at index: Int32) {
            switch self {
            case .text(let s):
                sqlite3_bind_text(stmt, index, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case .real(let d):
                sqlite3_bind_double(stmt, index, d)
            }
        }
    }

    private static func openDB(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db = db else {
            if let d = db { sqlite3_close(d) }
            return nil
        }
        return db
    }

    /// Confirm the tables/columns we depend on exist. Returns false on any
    /// mismatch so callers can degrade gracefully.
    private static func validateSchema(_ db: OpaquePointer) -> Bool {
        let expectations: [(table: String, columns: Set<String>)] = [
            ("ZCLOUDRECORDING", ["ZUNIQUEID", "ZENCRYPTEDTITLE", "ZDATE", "ZDURATION", "ZPATH", "ZFOLDER"]),
            ("ZFOLDER", ["Z_PK", "ZENCRYPTEDNAME"]),
        ]
        for (table, required) in expectations {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            var found: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) { found.insert(String(cString: name)) }
            }
            if !required.isSubset(of: found) { return false }
        }
        return true
    }

    private static func columnString(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    private static func columnBlob(_ stmt: OpaquePointer, _ idx: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, idx) else { return nil }
        let n = sqlite3_column_bytes(stmt, idx)
        guard n > 0 else { return nil }
        return Data(bytes: ptr, count: Int(n))
    }
}
