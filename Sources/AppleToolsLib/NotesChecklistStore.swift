import Foundation
import Compression
import SQLite3

/// Reads Apple Notes checklist state from the on-disk Core Data store.
///
/// The AppleScript `body` API flattens checklists to plain `<ul>` and exposes
/// no checked/unchecked state (validated empirically — see
/// docs/reference/macos-internals/apple-notes-applescript.md). The state lives
/// only in the gzipped protobuf blob in `NoteStore.sqlite`. This reads it.
///
/// Caveats (documented for callers):
///  - **Not real-time.** Notes flushes to this store on its own cadence; a
///    just-toggled checkbox can lag by minutes. Use for "what's the state of
///    this list", not "did I just tick this box".
///  - **Read-only.** We never write this store — that would fight iCloud sync
///    and risk corruption.
///  - Best-effort: any failure (store moved, schema change, parse error)
///    returns an empty result rather than throwing, so the formatting read
///    path degrades to plain bullets.
public enum NotesChecklistStore {

    public struct Item {
        public let text: String
        public let done: Bool
    }

    public struct Link {
        public let text: String
        public let url: String
    }

    /// Path to the on-disk Notes Core Data store. Internal so the full-text
    /// search path (NotesFullTextStore) reads the same store.
    static var storePath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    /// Checklist items for the note with the given title. Returns [] on any
    /// failure. Matches by title; if multiple notes share a title, the first
    /// row wins (callers overlay by text match, so cross-note bleed is benign).
    public static func checklistItems(forTitle title: String) -> [Item] {
        guard let blob = noteDataBlob(forTitle: title),
              let inflated = gunzip(blob) else { return [] }
        return parseChecklist(inflated)
    }

    /// Link spans for the note with the given title. Returns [] on any failure.
    /// Apple Notes drops the `href` from the AppleScript `body` on write and
    /// only sometimes echoes it on read; the canonical link URL lives in the
    /// protobuf as `attribute_run` field 9. Matches by title (first row wins);
    /// callers overlay by display-text match, so cross-note bleed is benign.
    public static func linkItems(forTitle title: String) -> [Link] {
        guard let blob = noteDataBlob(forTitle: title),
              let inflated = gunzip(blob) else { return [] }
        return parseLinks(inflated)
    }

    // MARK: - SQLite

    private static func noteDataBlob(forTitle title: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT d.ZDATA FROM ZICNOTEDATA d
        JOIN ZICCLOUDSYNCINGOBJECT o ON o.ZNOTEDATA = d.Z_PK
        WHERE o.ZTITLE1 = ? LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT so SQLite copies the string.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, title, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: bytes, count: count)
    }

    // MARK: - gunzip

    /// Inflate a gzip blob. Notes uses a fixed 10-byte header with no extra
    /// flags (FLG=0), so we strip it and run raw DEFLATE via Compression.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18,
              data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b,
              data[data.startIndex + 2] == 0x08,
              data[data.startIndex + 3] == 0x00 else { return nil }

        let deflate = data.subdata(in: (data.startIndex + 10)..<data.endIndex)
        let capacity = max(deflate.count * 8, 64 * 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }

        let written = deflate.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst, capacity, base, deflate.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }

    // MARK: - Protobuf

    /// Extract the note's body plaintext from an inflated document protobuf.
    /// Structure: NoteStoreProto.document(2).note(3).note_text(2) string. The
    /// first line is the title. Shared with NotesFullTextStore so full-text
    /// search scans the same text the read path renders. Returns nil on any
    /// parse failure (e.g. encrypted/password-protected notes).
    static func plaintext(fromInflated data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let doc = fieldBytes(bytes, field: 2),
              let note = fieldBytes(doc, field: 3),
              let textBytes = fieldBytes(note, field: 2) else { return nil }
        return String(bytes: textBytes, encoding: .utf8)
    }

    /// Parse the Notes document protobuf far enough to recover checklist items.
    /// Structure: NoteStoreProto.document(2).note(3) { note_text(2) string,
    /// attribute_run(5) repeated }. Each run has length(1) and
    /// paragraph_style(2) { style_type(1)==103 for checklist, checklist(5)
    /// { done(2) } }. Runs partition note_text by UTF-16-ish length; we walk
    /// runs, slice the text, and emit one Item per checklist line.
    static func parseChecklist(_ data: Data) -> [Item] {
        let bytes = [UInt8](data)
        guard let doc = fieldBytes(bytes, field: 2),
              let note = fieldBytes(doc, field: 3) else { return [] }

        guard let textBytes = fieldBytes(note, field: 2),
              let text = String(bytes: textBytes, encoding: .utf8) else { return [] }
        let scalars = Array(text)

        let runs = allFieldBytes(note, field: 5)
        var items: [Item] = []
        var pos = 0
        // Accumulate consecutive runs that belong to the same checklist line
        // (Notes splits a line across multiple runs); flush on newline.
        var current = ""
        var currentIsCheck = false
        var currentDone = false

        func flushLine() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentIsCheck, !trimmed.isEmpty {
                items.append(Item(text: trimmed, done: currentDone))
            }
            current = ""
            currentIsCheck = false
            currentDone = false
        }

        for run in runs {
            let length = (fieldVarint(run, field: 1)).map { Int($0) } ?? 0
            let end = min(pos + length, scalars.count)
            let segment = String(scalars[pos..<end])
            pos = end

            var isCheck = false
            var done = false
            if let pstyle = fieldBytes(run, field: 2) {
                let styleType = fieldVarint(pstyle, field: 1)
                if styleType == 103 { isCheck = true }
                if let chk = fieldBytes(pstyle, field: 5) {
                    isCheck = true
                    done = (fieldVarint(chk, field: 2) ?? 0) != 0
                }
            }

            if isCheck { currentIsCheck = true; currentDone = currentDone || done }
            current += segment
            if segment.contains("\n") { flushLine() }
        }
        flushLine()
        return items
    }

    /// Parse the document protobuf for link spans. Same walk as parseChecklist,
    /// but keys on `attribute_run` field 9 (the link URL, a length-delimited
    /// string). Notes splits a styled span across consecutive runs, so we
    /// coalesce adjacent runs that carry the same URL into one Link.
    static func parseLinks(_ data: Data) -> [Link] {
        let bytes = [UInt8](data)
        guard let doc = fieldBytes(bytes, field: 2),
              let note = fieldBytes(doc, field: 3) else { return [] }

        guard let textBytes = fieldBytes(note, field: 2),
              let text = String(bytes: textBytes, encoding: .utf8) else { return [] }
        let scalars = Array(text)

        let runs = allFieldBytes(note, field: 5)
        var links: [Link] = []
        var pos = 0
        var currentText = ""
        var currentURL: String? = nil

        func flush() {
            if let url = currentURL {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { links.append(Link(text: trimmed, url: url)) }
            }
            currentText = ""
            currentURL = nil
        }

        for run in runs {
            let length = (fieldVarint(run, field: 1)).map { Int($0) } ?? 0
            let end = min(pos + length, scalars.count)
            let segment = String(scalars[pos..<end])
            pos = end

            var url: String? = nil
            if let urlBytes = fieldBytes(run, field: 9) {
                url = String(bytes: urlBytes, encoding: .utf8)
            }

            if url != currentURL { flush() }
            if let url = url {
                currentURL = url
                currentText += segment
            }
        }
        flush()
        return links
    }

    // MARK: - Minimal protobuf wire reader

    private static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count {
            let x = b[i]; i += 1
            result |= UInt64(x & 0x7f) << shift
            if x & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    /// Return the bytes of the first length-delimited (wire type 2) field with
    /// the given number.
    private static func fieldBytes(_ b: [UInt8], field: Int) -> [UInt8]? {
        var i = 0
        while i < b.count {
            let key = readVarint(b, &i)
            let f = Int(key >> 3); let wt = Int(key & 7)
            switch wt {
            case 0: _ = readVarint(b, &i)
            case 5: i += 4
            case 1: i += 8
            case 2:
                let len = Int(readVarint(b, &i))
                if f == field { return Array(b[i..<min(i + len, b.count)]) }
                i += len
            default: return nil
            }
        }
        return nil
    }

    private static func allFieldBytes(_ b: [UInt8], field: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i < b.count {
            let key = readVarint(b, &i)
            let f = Int(key >> 3); let wt = Int(key & 7)
            switch wt {
            case 0: _ = readVarint(b, &i)
            case 5: i += 4
            case 1: i += 8
            case 2:
                let len = Int(readVarint(b, &i))
                if f == field { out.append(Array(b[i..<min(i + len, b.count)])) }
                i += len
            default: return out
            }
        }
        return out
    }

    private static func fieldVarint(_ b: [UInt8], field: Int) -> UInt64? {
        var i = 0
        while i < b.count {
            let key = readVarint(b, &i)
            let f = Int(key >> 3); let wt = Int(key & 7)
            switch wt {
            case 0:
                let v = readVarint(b, &i)
                if f == field { return v }
            case 5: i += 4
            case 1: i += 8
            case 2:
                let len = Int(readVarint(b, &i)); i += len
            default: return nil
            }
        }
        return nil
    }
}
