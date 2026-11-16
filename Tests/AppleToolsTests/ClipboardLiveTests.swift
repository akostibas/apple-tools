import AppKit
import XCTest
@testable import AppleToolsLib

/// Writes to the real clipboard and reads it back, then puts back whatever was
/// there (any type, not just text). Run with `bin/check --slow --tool clipboard`.
final class ClipboardLiveTests: XCTestCase {
    private var saved: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUpWithError() throws {
        try LiveTest.writes("clipboard", "write", "read")
        saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    override func tearDown() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(saved.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        })
        super.tearDown()
    }

    func testWriteThenReadReturnsTheSameText() throws {
        let tool = ClipboardTool(host: .test())
        let text = "\(LiveTest.label) \(UUID().uuidString.prefix(8))"
        let (out, isError) = tool.handle(params: ["action": AnyCodable("write"), "text": AnyCodable(text)])
        XCTAssertFalse(isError, out)
        let (read, readError) = tool.handle(params: ["action": AnyCodable("read")])
        XCTAssertFalse(readError, read)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["text"] as? String, text)
    }
}
