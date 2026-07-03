import XCTest
@testable import AppleToolsLib

/// Offline test of readNote's overlay wiring: stub the AppleScript runner and
/// the protobuf lookups so we verify link/checkbox state is spliced onto the
/// converted Markdown without touching the real Notes app or store.
final class NotesReadOverlayTests: XCTestCase {

    override func tearDown() {
        NotesIntegration.runAppleScript = NotesIntegration.defaultRunAppleScript
        NotesIntegration.linkLookup = NotesChecklistStore.linkItems(forTitle:)
        NotesIntegration.checklistLookup = NotesChecklistStore.checklistItems(forTitle:)
        super.tearDown()
    }

    private func stubRead(title: String, html: String) {
        NotesIntegration.runAppleScript = { _, _, _ in
            let parts = ["id://1", title, "Notes", "date", "date", html]
            return (parts.joined(separator: NotesIntegration.fieldSep), nil)
        }
    }

    func testReadSplicesProtobufLinkURL() throws {
        stubRead(title: "Trip", html: "<div>Visit Lawrence Hall today.</div>")
        NotesIntegration.checklistLookup = { _ in [] }
        NotesIntegration.linkLookup = { _ in
            [NotesChecklistStore.Link(text: "Lawrence Hall", url: "https://lhs.org/")]
        }
        let note = try NotesIntegration.readNote(id: nil, title: "Trip")
        XCTAssertEqual(note.content, "Visit [Lawrence Hall](https://lhs.org/) today.")
    }

    func testReadLeavesBareLinkPlain() throws {
        stubRead(title: "Trip", html: "<div>See https://x.com/p ok.</div>")
        NotesIntegration.checklistLookup = { _ in [] }
        NotesIntegration.linkLookup = { _ in
            [NotesChecklistStore.Link(text: "https://x.com/p", url: "https://x.com/p")]
        }
        let note = try NotesIntegration.readNote(id: nil, title: "Trip")
        XCTAssertEqual(note.content, "See https://x.com/p ok.")
    }

    func testReadCombinesChecklistAndLinkOverlays() throws {
        stubRead(title: "Plan", html: "<ul>\n<li>call Lawrence Hall</li>\n</ul>")
        NotesIntegration.checklistLookup = { _ in
            [NotesChecklistStore.Item(text: "call Lawrence Hall", done: true)]
        }
        NotesIntegration.linkLookup = { _ in
            [NotesChecklistStore.Link(text: "Lawrence Hall", url: "https://lhs.org/")]
        }
        let note = try NotesIntegration.readNote(id: nil, title: "Plan")
        XCTAssertEqual(note.content, "- [x] call [Lawrence Hall](https://lhs.org/)")
    }
}
