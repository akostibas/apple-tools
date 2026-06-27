import Foundation
import SQLite3

/// `notes search`, served by reading the on-disk Notes store directly.
///
/// The original AppleScript search times out on large stores (issue #13).
/// `plaintext contains` was the obvious culprit, but the `whose name contains`
/// half is just as fatal on a broad query: AppleScript's `whose` filter costs
/// one Apple-event round-trip per match, so a query matching ~2k notes blows
/// the 60s deadline even title-only (measured: "meeting"/129 matches → 3.3s;
/// "a"/~2000 matches → timeout). The backend, not the clause, is the problem.
///
/// So both modes read `NoteStore.sqlite` read-only instead:
///  - **title (default):** a `ZTITLE1 LIKE` scan — ~10ms, no decompression.
///  - **`fullText`:** title OR gunzipped body substring scan — ~200ms for a
///    full-store sweep (see bench/notes_fulltext_bench.swift), vs. the 60s the
///    AppleScript path blows.
///
/// Caveats (same shape as NotesChecklistStore, which reads the same store):
///  - **Not real-time.** Notes flushes to this store on its own cadence; a
///    note created/renamed seconds ago may not match yet. Callers that need a
///    just-written note should `read` it by id/title (real-time), not search.
///  - **Read-only.** Never writes the store.
///  - **Best-effort.** Returns [] on any store-access failure; encrypted notes
///    (whose body won't gunzip) are skipped under `fullText` rather than failing.
public enum NotesStoreSearch {

    /// One search hit. Mirrors NotesIntegration.NoteSummary's fields so the
    /// caller can map it straight onto the existing search output schema.
    public struct Hit {
        public let id: String
        public let title: String
        public let modified: String   // ISO 8601
        public let snippet: String
    }

    /// Title substring search (default) or title+body (`fullText`), newest
    /// first, case-insensitive. Returns [] on any store-access failure so the
    /// caller degrades to an empty result rather than throwing.
    public static func search(query: String, folder: String?, fullText: Bool) -> [Hit] {
        guard !query.isEmpty else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(NotesChecklistStore.storePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let storeUUID = persistentStoreUUID(db)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

        // ZMARKEDFORDELETION filters out Recently Deleted notes. Under fullText
        // we need the body blob; title-only avoids the gunzip entirely and lets
        // SQLite do the matching with a LIKE.
        var sql = """
        SELECT o.Z_PK, o.ZTITLE1, o.ZMODIFICATIONDATE1\(fullText ? ", d.ZDATA" : "")
        FROM ZICCLOUDSYNCINGOBJECT o
        JOIN ZICNOTEDATA d ON o.ZNOTEDATA = d.Z_PK
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON o.ZFOLDER = f.Z_PK
        WHERE (o.ZMARKEDFORDELETION = 0 OR o.ZMARKEDFORDELETION IS NULL)
        """
        if !fullText { sql += " AND o.ZTITLE1 LIKE ? ESCAPE '\\'" }
        if folder != nil { sql += " AND f.ZTITLE2 = ?" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        if !fullText {
            sqlite3_bind_text(stmt, bindIdx, "%\(escapeLike(query))%", -1, transient)
            bindIdx += 1
        }
        if let folder = folder {
            sqlite3_bind_text(stmt, bindIdx, folder, -1, transient)
        }

        let needle = query.lowercased()
        var hits: [(modified: Double, hit: Hit)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let zmod = sqlite3_column_double(stmt, 2)

            var snippet = ""
            if fullText {
                guard let blobPtr = sqlite3_column_blob(stmt, 3) else { continue }
                let blob = Data(bytes: blobPtr, count: Int(sqlite3_column_bytes(stmt, 3)))
                guard let inflated = NotesChecklistStore.gunzip(blob),
                      let body = NotesChecklistStore.plaintext(fromInflated: inflated) else { continue }
                guard body.lowercased().contains(needle) || title.lowercased().contains(needle) else { continue }
                snippet = self.snippet(from: body)
            }
            // (title-only matching is done by the SQL LIKE; that path has no body snippet)

            let id = storeUUID.map { "x-coredata://\($0)/ICNote/p\(pk)" } ?? "p\(pk)"
            let modified = DateFormatting.iso(Date(timeIntervalSinceReferenceDate: zmod))
            hits.append((zmod, Hit(id: id, title: title, modified: modified, snippet: snippet)))
        }

        // Newest first — deterministic and the most useful default ordering.
        return hits.sorted { $0.modified > $1.modified }.map { $0.hit }
    }

    // MARK: - Helpers

    /// The persistent store UUID used in AppleScript note ids
    /// (`x-coredata://<uuid>/ICNote/p<pk>`), read from Z_METADATA.
    private static func persistentStoreUUID(_ db: OpaquePointer?) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_UUID FROM Z_METADATA LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// Escape LIKE wildcards in user input so a query containing %, _ or \ is
    /// matched literally (paired with `ESCAPE '\'` in the SQL).
    private static func escapeLike(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Build a snippet the same way the old AppleScript path did: drop the
    /// first line (the title), trim leading whitespace/newlines, cap at 200.
    private static func snippet(from body: String) -> String {
        guard let firstLF = body.firstIndex(of: "\n") else { return "" }
        let afterTitle = body[body.index(after: firstLF)...]
        let trimmed = afterTitle.drop { $0 == "\n" || $0 == " " }
        return String(trimmed.prefix(200))
    }
}
