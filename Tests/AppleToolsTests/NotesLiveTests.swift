import XCTest
@testable import AppleToolsLib

/// Live round-trip tests against the real Notes app. Skipped unless
/// APPLE_TOOLS_NOTES_LIVE=1, because they create/delete notes and read the
/// on-disk store. Run with:
///
///     APPLE_TOOLS_NOTES_LIVE=1 swift test --filter NotesLiveTests
///
/// These are the "emit Markdown → Notes → read back → compare" checks that
/// prove fidelity end-to-end (issue).
final class NotesLiveTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["APPLE_TOOLS_NOTES_LIVE"] == "1" }
    private let folder = "AppleToolsFmtLive"

    override func setUpWithError() throws {
        try XCTSkipUnless(live, "set APPLE_TOOLS_NOTES_LIVE=1 to run live Notes tests")
    }

    override func tearDown() {
        _ = runOsa("tell application \"Notes\" to if exists folder \"\(folder)\" then delete folder \"\(folder)\"")
        super.tearDown()
    }

    func testRoundTripFormatting() throws {
        let title = "FmtRoundTrip"
        let body = """
        # Section One

        Some **bold** and *italic* and ~~struck~~ and `mono`.

        - apple
        - banana

        1. first
        2. second
        """
        _ = try NotesIntegration.createNote(title: title, body: body, folder: folder)
        // Give Notes a beat to settle the new note.
        Thread.sleep(forTimeInterval: 0.5)
        let note = try NotesIntegration.readNote(id: nil, title: title)

        // Assert each construct survived the round-trip.
        let lines = note.content.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("# Section One"), "heading; got:\n\(note.content)")
        XCTAssertTrue(note.content.contains("**bold**"), "bold; got:\n\(note.content)")
        XCTAssertTrue(note.content.contains("*italic*"), "italic; got:\n\(note.content)")
        XCTAssertTrue(note.content.contains("~~struck~~"), "strike; got:\n\(note.content)")
        XCTAssertTrue(note.content.contains("`mono`"), "mono; got:\n\(note.content)")
        XCTAssertTrue(lines.contains("- apple"), "bullet; got:\n\(note.content)")
        XCTAssertTrue(lines.contains("1. first"), "ordered; got:\n\(note.content)")
        XCTAssertTrue(lines.contains("2. second"), "ordered2; got:\n\(note.content)")
    }

    /// Requires a manually-created note titled "Checkbox Test" with at least
    /// one checked and one unchecked item. Validates the protobuf-store read.
    func testChecklistStateFromProtobufStore() throws {
        let items = NotesChecklistStore.checklistItems(forTitle: "Checkbox Test")
        try XCTSkipUnless(!items.isEmpty,
                          "create a 'Checkbox Test' note with checkboxes to run this")
        XCTAssertTrue(items.contains { $0.done }, "expected at least one checked item")
        XCTAssertTrue(items.contains { !$0.done }, "expected at least one unchecked item")
    }

    /// Reads link spans from the protobuf store for a real note. Set
    /// APPLE_TOOLS_NOTES_LINK_NOTE to a note title that contains at least one
    /// hyperlink. Prints what it found so the field-9 mapping can be eyeballed.
    func testLinkRecoveryFromProtobufStore() throws {
        let title = ProcessInfo.processInfo.environment["APPLE_TOOLS_NOTES_LINK_NOTE"] ?? ""
        try XCTSkipUnless(!title.isEmpty,
                          "set APPLE_TOOLS_NOTES_LINK_NOTE to a note title with a link")
        let links = NotesChecklistStore.linkItems(forTitle: title)
        for l in links { print("LINK text=\(l.text) url=\(l.url)") }
        XCTAssertFalse(links.isEmpty, "expected at least one link in '\(title)'")
        XCTAssertTrue(links.allSatisfy { $0.url.contains("://") },
                      "every recovered URL should look like a URL; got \(links.map { $0.url })")
    }

    @discardableResult
    private func runOsa(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
