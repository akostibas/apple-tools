import Foundation
import SQLite3

// RemindersDB reads subtask relationships from the Apple Reminders SQLite
// database. EventKit has no public API for parent/child relationships on
// EKReminder (confirmed by Apple DTS as of April 2026), so we read them
// directly from the CoreData-backed SQLite store.
//
// This is READ-ONLY. We never write to this database — it's owned by the
// Reminders daemon and backed by CoreData with WAL journaling. Writing
// could corrupt it or conflict with sync.
//
// The key columns in ZREMCDREMINDER:
//   - Z_PK: internal integer primary key
//   - ZDACALENDARITEMUNIQUEIDENTIFIER: matches EventKit's calendarItemExternalIdentifier
//   - ZPARENTREMINDER: integer FK to Z_PK of the parent reminder (NULL if top-level)
//   - ZTITLE: reminder title
//   - ZCOMPLETED: 0 or 1
//
// If Apple changes the schema or locks down the database in a future macOS
// release, all methods here return empty/nil results — the caller gracefully
// degrades to showing reminders without subtask info.
enum RemindersDB {

    /// SQLite's `SQLITE_TRANSIENT` sentinel: instructs SQLite to copy the bound
    /// bytes immediately, so the caller need not keep the source buffer alive.
    /// The SQLite3 module map doesn't surface the C macro, so we reconstruct it
    /// (as `PhotosIntegration` does). Required here because we bind
    /// `(id as NSString).utf8String` — an autoreleased inner pointer that would
    /// be a use-after-free under `SQLITE_STATIC` (nil destructor).
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// A minimal reminder reference used for subtask lists and parent links.
    struct LiteReminder {
        let id: String       // ZDACALENDARITEMUNIQUEIDENTIFIER (= EK calendarItemExternalIdentifier)
        let title: String
        let completed: Bool
    }

    // MARK: - Public API

    /// Returns the subtasks (children) of a reminder, identified by its
    /// EventKit calendarItemExternalIdentifier. Returns an empty array if
    /// the reminder has no subtasks, the DB can't be opened, or the schema
    /// doesn't match expectations.
    static func subtasks(forParentID parentEKID: String, dbPath: String? = nil) -> [LiteReminder] {
        guard let db = openDB(path: dbPath) else { return [] }
        defer { sqlite3_close(db) }

        // Resolve the parent's Z_PK from its EK identifier, then find children.
        let sql = """
            SELECT c.ZDACALENDARITEMUNIQUEIDENTIFIER, c.ZTITLE, c.ZCOMPLETED
            FROM ZREMCDREMINDER c
            JOIN ZREMCDREMINDER p ON c.ZPARENTREMINDER = p.Z_PK
            WHERE p.ZDACALENDARITEMUNIQUEIDENTIFIER = ?
              AND c.ZMARKEDFORDELETION = 0
            ORDER BY c.ZICSDISPLAYORDER, c.Z_PK
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (parentEKID as NSString).utf8String, -1, SQLITE_TRANSIENT)

        var results: [LiteReminder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnString(stmt, 0),
                  let title = columnString(stmt, 1) else { continue }
            let completed = sqlite3_column_int(stmt, 2) != 0
            results.append(LiteReminder(id: id, title: title, completed: completed))
        }
        return results
    }

    /// Returns the parent of a reminder, identified by its EventKit
    /// calendarItemExternalIdentifier. Returns nil if the reminder has no
    /// parent or the DB can't be read.
    static func parent(forChildID childEKID: String, dbPath: String? = nil) -> LiteReminder? {
        guard let db = openDB(path: dbPath) else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT p.ZDACALENDARITEMUNIQUEIDENTIFIER, p.ZTITLE, p.ZCOMPLETED
            FROM ZREMCDREMINDER p
            JOIN ZREMCDREMINDER c ON c.ZPARENTREMINDER = p.Z_PK
            WHERE c.ZDACALENDARITEMUNIQUEIDENTIFIER = ?
              AND p.ZMARKEDFORDELETION = 0
            LIMIT 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (childEKID as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let id = columnString(stmt, 0),
              let title = columnString(stmt, 1) else {
            return nil
        }
        let completed = sqlite3_column_int(stmt, 2) != 0
        return LiteReminder(id: id, title: title, completed: completed)
    }

    /// Batch-fetches parent info for multiple reminder IDs at once. Returns a
    /// dictionary mapping child EK ID → parent LiteReminder. More efficient
    /// than calling parent(forChildID:) in a loop for search results.
    static func parents(forChildIDs childEKIDs: [String], dbPath: String? = nil) -> [String: LiteReminder] {
        guard !childEKIDs.isEmpty else { return [:] }
        guard let db = openDB(path: dbPath) else { return [:] }
        defer { sqlite3_close(db) }

        // Build a query with placeholders for all IDs.
        let placeholders = childEKIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT c.ZDACALENDARITEMUNIQUEIDENTIFIER,
                   p.ZDACALENDARITEMUNIQUEIDENTIFIER, p.ZTITLE, p.ZCOMPLETED
            FROM ZREMCDREMINDER c
            JOIN ZREMCDREMINDER p ON c.ZPARENTREMINDER = p.Z_PK
            WHERE c.ZDACALENDARITEMUNIQUEIDENTIFIER IN (\(placeholders))
              AND p.ZMARKEDFORDELETION = 0
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        for (i, id) in childEKIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        var results: [String: LiteReminder] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let childID = columnString(stmt, 0),
                  let parentID = columnString(stmt, 1),
                  let parentTitle = columnString(stmt, 2) else { continue }
            let completed = sqlite3_column_int(stmt, 3) != 0
            results[childID] = LiteReminder(id: parentID, title: parentTitle, completed: completed)
        }
        return results
    }

    /// Batch-fetches subtasks for multiple parent IDs at once. Returns a
    /// dictionary mapping parent EK ID → array of child LiteReminders.
    static func subtasks(forParentIDs parentEKIDs: [String], dbPath: String? = nil) -> [String: [LiteReminder]] {
        guard !parentEKIDs.isEmpty else { return [:] }
        guard let db = openDB(path: dbPath) else { return [:] }
        defer { sqlite3_close(db) }

        let placeholders = parentEKIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT p.ZDACALENDARITEMUNIQUEIDENTIFIER,
                   c.ZDACALENDARITEMUNIQUEIDENTIFIER, c.ZTITLE, c.ZCOMPLETED
            FROM ZREMCDREMINDER c
            JOIN ZREMCDREMINDER p ON c.ZPARENTREMINDER = p.Z_PK
            WHERE p.ZDACALENDARITEMUNIQUEIDENTIFIER IN (\(placeholders))
              AND c.ZMARKEDFORDELETION = 0
            ORDER BY c.ZICSDISPLAYORDER, c.Z_PK
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        for (i, id) in parentEKIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        var results: [String: [LiteReminder]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let parentID = columnString(stmt, 0),
                  let childID = columnString(stmt, 1),
                  let childTitle = columnString(stmt, 2) else { continue }
            let completed = sqlite3_column_int(stmt, 3) != 0
            let lite = LiteReminder(id: childID, title: childTitle, completed: completed)
            results[parentID, default: []].append(lite)
        }
        return results
    }

    /// Batch-fetches flag state for multiple reminder IDs at once. Returns the
    /// subset of the given EK identifiers whose ZFLAGGED column is set.
    ///
    /// EventKit exposes no public API for a reminder's flag state (it lives
    /// only in the CoreData-backed SQLite store), so — like subtask
    /// relationships — we read it directly. If the DB can't be read, returns an
    /// empty set and callers degrade to treating everything as unflagged.
    static func flagged(forIDs ekIDs: [String], dbPath: String? = nil) -> Set<String> {
        guard !ekIDs.isEmpty else { return [] }
        guard let db = openDB(path: dbPath) else { return [] }
        defer { sqlite3_close(db) }

        let placeholders = ekIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT ZDACALENDARITEMUNIQUEIDENTIFIER
            FROM ZREMCDREMINDER
            WHERE ZDACALENDARITEMUNIQUEIDENTIFIER IN (\(placeholders))
              AND ZFLAGGED = 1
              AND ZMARKEDFORDELETION = 0
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (i, id) in ekIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        var results: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = columnString(stmt, 0) {
                results.insert(id)
            }
        }
        return results
    }

    /// Returns whether a single reminder, identified by its EventKit
    /// calendarItemExternalIdentifier, is flagged. Returns false if the DB
    /// can't be read.
    static func isFlagged(forID ekID: String, dbPath: String? = nil) -> Bool {
        return flagged(forIDs: [ekID], dbPath: dbPath).contains(ekID)
    }

    // MARK: - Database discovery

    /// Finds the active Reminders SQLite database. There are multiple DB files
    /// (one per account); we pick the one with actual reminder rows.
    /// Returns nil if no readable database is found.
    private static func discoverDBPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storesDir = "\(home)/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: storesDir) else { return nil }

        let dbFiles = entries
            .filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }
            .map { "\(storesDir)/\($0)" }

        // Return the DB with the most reminders (typically only one has data).
        var bestPath: String?
        var bestCount: Int = 0

        for path in dbFiles {
            guard fm.isReadableFile(atPath: path) else { continue }
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db = db else { continue }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZREMCDREMINDER", -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else { continue }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = Int(sqlite3_column_int(stmt, 0))
                if count > bestCount {
                    bestCount = count
                    bestPath = path
                }
            }
        }
        return bestPath
    }

    // MARK: - Internals

    private static func openDB(path: String?) -> OpaquePointer? {
        guard let dbPath = path ?? discoverDBPath() else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db = db else {
            if let d = db { sqlite3_close(d) }
            return nil
        }
        return db
    }

    private static func columnString(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }
}
