import XCTest
@testable import AppleToolsLib

final class NotesVerifierTests: XCTestCase {

    private var savedLookup: ((String, TimeInterval) -> String?)!

    override func setUp() {
        super.setUp()
        savedLookup = NotesVerifier.findRecentNote
    }

    override func tearDown() {
        NotesVerifier.findRecentNote = savedLookup
        super.tearDown()
    }

    /// Lookup returns nil for every poll → verifier exhausts deadline and
    /// returns .inconclusive (never .absent — see NotesVerifier doc).
    func testNoMatchIsInconclusive() {
        NotesVerifier.findRecentNote = { _, _ in nil }

        let start = Date()
        let result = NotesVerifier.verify(
            title: "Shopping",
            sinceCutoff: NotesVerifier.snapshotCutoff(),
            deadline: 0.4,
            pollInterval: 0.1
        )
        let elapsed = Date().timeIntervalSince(start)
        if case .inconclusive = result { /* ok */ } else {
            XCTFail("expected .inconclusive, got \(result)")
        }
        XCTAssertLessThan(elapsed, 1.0)
    }

    /// Lookup returns an id on first poll → .confirmed immediately.
    func testFirstPollHitReturnsConfirmed() {
        NotesVerifier.findRecentNote = { title, _ in
            XCTAssertEqual(title, "Shopping", "verifier must pass the trimmed title to the lookup")
            return "x-coredata://abc"
        }

        let result = NotesVerifier.verify(
            title: "Shopping",
            sinceCutoff: NotesVerifier.snapshotCutoff(),
            deadline: 1.0
        )
        guard case .confirmed(let id) = result else {
            XCTFail("expected .confirmed, got \(result)")
            return
        }
        XCTAssertEqual(id, "x-coredata://abc")
    }

    /// Lookup returns nil for the first 3 polls then an id → .confirmed,
    /// proving the verifier doesn't give up after the first miss.
    func testPollsUntilHitOrDeadline() {
        var calls = 0
        NotesVerifier.findRecentNote = { _, _ in
            calls += 1
            return calls >= 3 ? "x-coredata://later" : nil
        }

        let result = NotesVerifier.verify(
            title: "Shopping",
            sinceCutoff: NotesVerifier.snapshotCutoff(),
            deadline: 2.0,
            pollInterval: 0.05
        )
        guard case .confirmed(let id) = result else {
            XCTFail("expected .confirmed after multiple polls, got \(result)")
            return
        }
        XCTAssertEqual(id, "x-coredata://later")
        XCTAssertGreaterThanOrEqual(calls, 3)
    }

    /// Title is trimmed before being passed to the lookup, so caller-side
    /// whitespace can't cause a miss.
    func testTitleIsTrimmed() {
        var observedTitle: String?
        NotesVerifier.findRecentNote = { title, _ in
            observedTitle = title
            return "x-coredata://abc"
        }
        _ = NotesVerifier.verify(
            title: "  Shopping  \n",
            sinceCutoff: NotesVerifier.snapshotCutoff(),
            deadline: 1.0
        )
        XCTAssertEqual(observedTitle, "Shopping")
    }

    /// Hook closure captures snapshot cutoff at construction time — so a
    /// later modification timestamp older than the snapshot would be
    /// excluded by the lookup, but the hook itself is closure-stable.
    func testMakeVerifyHookCapturesCutoff() {
        let cutoff: TimeInterval = 12345.0
        var observedCutoff: TimeInterval = -1
        NotesVerifier.findRecentNote = { _, since in
            observedCutoff = since
            return "x-coredata://abc"
        }
        let hook = NotesVerifier.makeVerifyHook(title: "x", sinceCutoff: cutoff)
        _ = hook()
        XCTAssertEqual(observedCutoff, cutoff)
    }
}
