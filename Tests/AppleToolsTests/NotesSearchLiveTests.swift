import XCTest
@testable import AppleToolsLib

/// Live, read-only smoke test of store-backed `notes search` against the real
/// Notes store. Skipped unless APPLE_TOOLS_NOTES_LIVE=1. Proves issue #13's
/// core acceptance criterion on real data: a broad query returns well within
/// the AppleScript deadline, and full-text is a superset of title-only.
///
///     APPLE_TOOLS_NOTES_LIVE=1 swift test --filter NotesSearchLiveTests
///
/// Mutation-free (only reads NoteStore.sqlite), so it's safe to run anytime.
final class NotesSearchLiveTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["APPLE_TOOLS_NOTES_LIVE"] == "1" }

    override func setUpWithError() throws {
        try XCTSkipUnless(live, "set APPLE_TOOLS_NOTES_LIVE=1 to run live Notes search tests")
    }

    /// A broad single-letter query is the exact shape that timed out (60s) on
    /// the old AppleScript path. The store read must finish in a small fraction
    /// of that. We assert a generous 10s ceiling to stay non-flaky on CI/cold
    /// caches while still catching any O(store) regression.
    func testBroadQueryReturnsFast() throws {
        let start = Date()
        let (total, _) = try NotesIntegration.searchNotes(query: "a", folder: nil, offset: 0, limit: 5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10, "broad query should be far under the 60s deadline")
        XCTAssertGreaterThan(total, 0, "expected the test store to contain notes titled with 'a'")
    }

    /// Full-text matches a superset of title-only for the same query: every
    /// note whose title matches also matches under body search.
    func testFullTextIsSupersetOfTitle() throws {
        let (titleTotal, _) = try NotesIntegration.searchNotes(query: "the", folder: nil, offset: 0, limit: 1)
        let (bodyTotal, _) = try NotesIntegration.searchNotes(query: "the", folder: nil, offset: 0, limit: 1, fullText: true)
        XCTAssertGreaterThanOrEqual(bodyTotal, titleTotal)
    }

    /// Reconstructed note ids are the AppleScript `x-coredata://…/ICNote/p…`
    /// form, so callers can feed a search result straight into `read`.
    func testHitIDsAreReadable() throws {
        let (_, notes) = try NotesIntegration.searchNotes(query: "a", folder: nil, offset: 0, limit: 1)
        let first = try XCTUnwrap(notes.first)
        XCTAssertTrue(first.id.hasPrefix("x-coredata://"), "got \(first.id)")
        XCTAssertTrue(first.id.contains("/ICNote/p"))
        // Round-trip: the id resolves to a readable note.
        let note = try NotesIntegration.readNote(id: first.id, title: nil)
        XCTAssertEqual(note.id, first.id)
    }
}
