// Benchmark: direct-store-read full-text search vs. the AppleScript timeout path.
//
// Mirrors the production path we'd ship for `notes search --full_text`:
//   SQLite read (readonly) -> gunzip body blob -> extract note_text from the
//   protobuf -> substring scan. Reuses the exact gunzip/wire-reader logic from
//   NotesChecklistStore so the timing is representative, not a toy.
//
// Run:  swiftc -O notes_fulltext_bench.swift -o /tmp/ntbench && /tmp/ntbench "query"
import Foundation
import Compression
import SQLite3

let query = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "the"
let storePath = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

// --- gunzip (verbatim from NotesChecklistStore) -----------------------------
func gunzip(_ data: Data) -> Data? {
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

// --- minimal protobuf wire reader (verbatim shape from NotesChecklistStore) --
func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64 {
    var result: UInt64 = 0; var shift: UInt64 = 0
    while i < b.count { let x = b[i]; i += 1; result |= UInt64(x & 0x7f) << shift
        if x & 0x80 == 0 { break }; shift += 7 }
    return result
}
func fieldBytes(_ b: [UInt8], field: Int) -> [UInt8]? {
    var i = 0
    while i < b.count {
        let key = readVarint(b, &i); let f = Int(key >> 3); let wt = Int(key & 7)
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
func noteText(_ inflated: Data) -> String? {
    let bytes = [UInt8](inflated)
    guard let doc = fieldBytes(bytes, field: 2),
          let note = fieldBytes(doc, field: 3),
          let textBytes = fieldBytes(note, field: 2) else { return nil }
    return String(bytes: textBytes, encoding: .utf8)
}

// --- load all blobs (this is the I/O the index would also have to pay once) --
var db: OpaquePointer?
guard sqlite3_open_v2(storePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    FileHandle.standardError.write("cannot open store\n".data(using: .utf8)!); exit(1)
}
defer { sqlite3_close(db) }

let sql = """
SELECT o.ZTITLE1, d.ZDATA FROM ZICNOTEDATA d
JOIN ZICCLOUDSYNCINGOBJECT o ON o.ZNOTEDATA = d.Z_PK
WHERE d.ZDATA IS NOT NULL
"""
var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exit(1) }

func now() -> Double { var t = timeval(); gettimeofday(&t, nil); return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }

let tStart = now()
var rows: [(title: String, blob: Data)] = []
while sqlite3_step(stmt) == SQLITE_ROW {
    let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "(untitled)"
    guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
    let count = Int(sqlite3_column_bytes(stmt, 1))
    rows.append((title, Data(bytes: bytes, count: count)))
}
sqlite3_finalize(stmt)
let tRead = now()

// --- gunzip + extract + scan ------------------------------------------------
let needle = query.lowercased()
var matches: [String] = []
var inflatedTotal = 0
var decoded = 0
for row in rows {
    guard let inflated = gunzip(row.blob) else { continue }
    inflatedTotal += inflated.count
    guard let text = noteText(inflated) else { continue }
    decoded += 1
    if text.lowercased().contains(needle) || row.title.lowercased().contains(needle) {
        matches.append(row.title)
    }
}
let tDone = now()

print(String(format: "notes scanned:     %d (%d decoded)", rows.count, decoded))
print(String(format: "gzipped read:      %.1f MB", Double(rows.reduce(0){$0+$1.blob.count})/1_048_576))
print(String(format: "inflated total:    %.1f MB", Double(inflatedTotal)/1_048_576))
print(String(format: "query:             %@", query))
print(String(format: "matches:           %d", matches.count))
print("---")
print(String(format: "sqlite read:       %.0f ms", (tRead - tStart) * 1000))
print(String(format: "gunzip+extract+scan: %.0f ms", (tDone - tRead) * 1000))
print(String(format: "TOTAL:             %.0f ms", (tDone - tStart) * 1000))
