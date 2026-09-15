import Foundation
import SQLite3

/// Shared schema check for the Apple stores we read.
///
/// `sqlite3_open_v2` proves nothing — SQLite opens lazily, so a missing,
/// truncated, or reformatted store still returns `SQLITE_OK` and only fails
/// later, one statement at a time, in a way that reads as "no results"
/// (ADR-0004). Every reader validates the columns it depends on *before*
/// querying, so "Apple moved this store" surfaces as its own outcome rather
/// than an empty success.
enum SQLiteSchema {

    /// True when every listed table exists and carries every listed column.
    /// Extra columns are fine — Apple adds them constantly.
    ///
    /// Only ever require a column when a result WITHOUT it is worthless — an
    /// optional field in the required set is what silently killed the whole
    /// podcast source on macOS 27.
    static func validate(_ db: OpaquePointer, expectations: [(table: String, columns: Set<String>)]) -> Bool {
        for (table, requiredColumns) in expectations {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            var foundColumns: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    foundColumns.insert(String(cString: name))
                }
            }
            if !requiredColumns.isSubset(of: foundColumns) { return false }
        }
        return true
    }
}
