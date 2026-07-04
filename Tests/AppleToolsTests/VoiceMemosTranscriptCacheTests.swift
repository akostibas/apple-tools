import XCTest
@testable import AppleToolsLib

/// Hermetic tests for the transcript cache. The cache dir is redirected to a
/// temp dir via `APPLE_TOOLS_CACHE_DIR`, so nothing touches the real
/// Application Support store.
final class VoiceMemosTranscriptCacheTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "transcript-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        setenv("APPLE_TOOLS_CACHE_DIR", tmp, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("APPLE_TOOLS_CACHE_DIR")
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func entry(id: String = "REC1", digest: String? = "abc123", locale: String = "en-US",
                       text: String = "hello world") -> VoiceMemosTranscriptCache.Entry {
        VoiceMemosTranscriptCache.Entry(
            id: id, digestHex: digest, locale: locale, text: text,
            segments: [.init(start: 0, end: 1.5, text: "hello world")],
            transcribedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testWriteThenReadRoundTrips() {
        XCTAssertTrue(VoiceMemosTranscriptCache.write(entry()))
        let got = VoiceMemosTranscriptCache.read(id: "REC1", digestHex: "abc123", locale: "en-US")
        XCTAssertEqual(got?.text, "hello world")
        XCTAssertEqual(got?.segments.first?.end, 1.5)
    }

    func testDigestMismatchMisses() {
        VoiceMemosTranscriptCache.write(entry(digest: "abc123"))
        // Recording was trimmed/re-recorded → different digest → cache invalid.
        XCTAssertNil(VoiceMemosTranscriptCache.read(id: "REC1", digestHex: "DIFFERENT", locale: "en-US"))
    }

    func testLocaleMismatchMisses() {
        VoiceMemosTranscriptCache.write(entry(locale: "en-US"))
        XCTAssertNil(VoiceMemosTranscriptCache.read(id: "REC1", digestHex: "abc123", locale: "es-ES"))
    }

    func testMissingEntryReturnsNil() {
        XCTAssertNil(VoiceMemosTranscriptCache.read(id: "NOPE", digestHex: "abc123", locale: "en-US"))
    }

    func testNilDigestMatchesNilDigest() {
        // A recording with no ZAUDIODIGEST caches under a nil digest and reads
        // back with a nil digest — but must NOT match a concrete digest.
        VoiceMemosTranscriptCache.write(entry(digest: nil))
        XCTAssertNotNil(VoiceMemosTranscriptCache.read(id: "REC1", digestHex: nil, locale: "en-US"))
        XCTAssertNil(VoiceMemosTranscriptCache.read(id: "REC1", digestHex: "abc123", locale: "en-US"))
    }

    func testWritePersistsAsFilePerRecording() {
        VoiceMemosTranscriptCache.write(entry(id: "REC-A"))
        VoiceMemosTranscriptCache.write(entry(id: "REC-B"))
        let dir = "\(tmp!)/transcripts"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertTrue(files.contains("REC-A.json"))
        XCTAssertTrue(files.contains("REC-B.json"))
    }
}
