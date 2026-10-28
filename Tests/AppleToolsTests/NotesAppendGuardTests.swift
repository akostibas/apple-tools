import XCTest
@testable import AppleToolsLib

final class NotesAppendGuardTests: XCTestCase {
    func testPlainNoteIsSafe() {
        XCTAssertNil(NotesIntegration.appendBlocker(utis: []))
    }

    func testCountsEachKind() {
        let reason = NotesIntegration.appendBlocker(utis: [
            "public.png",
            "com.apple.notes.table",
            "com.apple.notes.inlinetextattachment.mention",
            "com.apple.notes.inlinetextattachment.mention",
            "com.apple.notes.inlinetextattachment.hashtag",
        ])
        XCTAssertEqual(reason?.hasPrefix("the note has 1 attachment, 1 hashtag, 2 mentions, 1 table."), true, reason ?? "nil")
    }
}
