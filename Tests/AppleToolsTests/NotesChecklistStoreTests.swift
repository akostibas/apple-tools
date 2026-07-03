import XCTest
import Compression
@testable import AppleToolsLib

/// Offline tests for NotesChecklistStore's protobuf parsing and gunzip. These
/// build synthetic document protobufs / gzip blobs in-memory so nothing touches
/// the real Notes store.
final class NotesChecklistStoreTests: XCTestCase {

    // MARK: - protobuf builders

    private func varint(_ value: Int) -> [UInt8] {
        var n = UInt64(value)
        var out: [UInt8] = []
        repeat {
            var b = UInt8(n & 0x7f)
            n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
        } while n != 0
        return out
    }

    /// Length-delimited (wire type 2) field. Field numbers here are all < 16,
    /// so the tag fits in a single byte.
    private func lenField(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        [UInt8((field << 3) | 2)] + varint(bytes.count) + bytes
    }

    /// Varint (wire type 0) field.
    private func varField(_ field: Int, _ value: Int) -> [UInt8] {
        [UInt8((field << 3) | 0)] + varint(value)
    }

    /// Wrap an assembled `note` body as NoteStoreProto.document(2).note(3).
    private func document(note: [UInt8]) -> Data {
        Data(lenField(2, lenField(3, note)))
    }

    /// A paragraph_style(2) marking a checklist run with the given done state.
    private func checklistStyle(done: Bool) -> [UInt8] {
        // style_type(1) = 103, checklist(5) { done(2) }
        varField(1, 103) + lenField(5, varField(2, done ? 1 : 0))
    }

    // MARK: - #28: UTF-16 run slicing

    func testChecklistRunsSlicedByUTF16NotCharacters() {
        // A leading emoji (2 UTF-16 code units, 1 Character) precedes the
        // checklist. Run lengths are UTF-16 counts; slicing by Character would
        // shift every subsequent segment and corrupt the item text.
        let text = "🎉\nAlpha\nBravo\n"
        let textBytes = Array(text.utf8)

        var note = lenField(2, textBytes)
        // run 1: "🎉\n" -> 3 UTF-16 units, plain paragraph (no checklist).
        note += lenField(5, varField(1, 3))
        // run 2: "Alpha\n" -> 6 units, unchecked.
        note += lenField(5, varField(1, 6) + lenField(2, checklistStyle(done: false)))
        // run 3: "Bravo\n" -> 6 units, checked.
        note += lenField(5, varField(1, 6) + lenField(2, checklistStyle(done: true)))

        let items = NotesChecklistStore.parseChecklist(document(note: note))
        XCTAssertEqual(items.map { $0.text }, ["Alpha", "Bravo"])
        XCTAssertEqual(items.map { $0.done }, [false, true])
    }

    func testLinkRunsSlicedByUTF16NotCharacters() {
        // Emoji before a linked span: UTF-16 slicing keeps the display text
        // exact; Character slicing would drop/shift a code unit.
        let text = "🎉Google\n"
        let textBytes = Array(text.utf8)
        let url = "https://g.example/"

        var note = lenField(2, textBytes)
        // run 1: "🎉" -> 2 UTF-16 units, no URL.
        note += lenField(5, varField(1, 2))
        // run 2: "Google" -> 6 units, linked.
        note += lenField(5, varField(1, 6) + lenField(9, Array(url.utf8)))
        // run 3: "\n" -> 1 unit, no URL.
        note += lenField(5, varField(1, 1))

        let links = NotesChecklistStore.parseLinks(document(note: note))
        XCTAssertEqual(links.map { $0.text }, ["Google"])
        XCTAssertEqual(links.map { $0.url }, [url])
    }

    // MARK: - #30: gunzip must not truncate at 8x expansion

    func testGunzipDoesNotTruncateHighlyCompressibleNote() {
        // Repetitive text compresses far better than 8:1, so a fixed
        // capacity = max(deflate*8, 64KB) buffer would truncate the tail.
        let original = String(repeating: "checklist item repeats. ", count: 60_000)
        let originalBytes = Data(original.utf8)   // ~1.4 MB
        let deflated = rawDeflate(originalBytes)
        XCTAssertLessThan(deflated.count * 8, originalBytes.count,
                          "test corpus must exceed the 8x buffer to exercise the retry")

        // Prepend the 10-byte gzip header (FLG=0) that Notes writes.
        var gz: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
        gz += [UInt8](deflated)

        let inflated = NotesChecklistStore.gunzip(Data(gz))
        XCTAssertEqual(inflated, originalBytes)
    }

    /// Raw DEFLATE (no zlib/gzip wrapper) via Apple's Compression, matching
    /// what `gunzip` decodes with COMPRESSION_ZLIB.
    private func rawDeflate(_ data: Data) -> Data {
        let cap = data.count + 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: dst, count: n)
    }
}
