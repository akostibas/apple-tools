import XCTest
@testable import AppleToolsLib

/// Live tests against the real Voice Memos store. The tool is read-only, so
/// these only read; exports and transcripts go to a temp dir that's removed.
/// Skipped unless APPLE_TOOLS_VOICEMEMOS_LIVE=1, and need at least one
/// downloaded recording:
///
///     APPLE_TOOLS_VOICEMEMOS_LIVE=1 swift test --filter VoiceMemosLiveTests
final class VoiceMemosLiveTests: XCTestCase {

    private var outDir: String!
    private var tool: VoiceMemosTool!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLE_TOOLS_VOICEMEMOS_LIVE"] == "1",
                          "set APPLE_TOOLS_VOICEMEMOS_LIVE=1 to run live Voice Memos tests")
        outDir = NSTemporaryDirectory() + "vm-live-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        tool = VoiceMemosTool(host: .test(fileSink: LocalFileSink(outputDir: outDir)))
    }

    override func tearDown() {
        if let d = outDir { try? FileManager.default.removeItem(atPath: d) }
        super.tearDown()
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let (out, isError) = tool.handle(params: params.mapValues { AnyCodable($0) })
        guard !isError else { throw NSError(domain: "voicememos", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func recordings(_ r: [String: Any]) -> [[String: Any]] { r["recordings"] as? [[String: Any]] ?? [] }

    /// Shortest downloaded recording, so export/transcribe stay quick.
    private func shortest() throws -> [String: Any] {
        let all = recordings(try call(["action": "list", "all": true]))
        let local = all.filter { $0["available"] as? Bool != false }
        return try XCTUnwrap(local.min { ($0["duration_seconds"] as? Double ?? 0) < ($1["duration_seconds"] as? Double ?? 0) },
                             "need at least one downloaded recording")
    }

    func testFoldersAgreeWithList() throws {
        let f = try call(["action": "folders"])
        let folders = f["folders"] as? [[String: Any]] ?? []
        let unfiled = try XCTUnwrap(f["unfiled_count"] as? Int)
        let all = recordings(try call(["action": "list", "all": true]))
        let filed = folders.reduce(0) { $0 + ($1["count"] as? Int ?? 0) }
        XCTAssertEqual(filed + unfiled, all.count, "folder counts plus unfiled must cover every recording")

        // A folder name from `folders` works verbatim as --folder.
        if let first = folders.first(where: { ($0["count"] as? Int ?? 0) > 0 }), let name = first["name"] as? String {
            XCTAssertEqual(recordings(try call(["action": "search", "folder": name])).count, first["count"] as? Int)
        }
    }

    func testListDefaultsAndSearch() throws {
        let recent = try call(["action": "list"])
        XCTAssertNotNil(recent["window"], "default list is windowed to recent days")

        let rec = try shortest()
        let title = try XCTUnwrap(rec["title"] as? String)
        let hits = recordings(try call(["action": "search", "query": title]))
        XCTAssertTrue(hits.contains { $0["id"] as? String == rec["id"] as? String })
    }

    func testExport() throws {
        let rec = try shortest()
        let r = try call(["action": "export", "id": rec["id"]!])
        let path = try XCTUnwrap(r["path"] as? String)
        XCTAssertTrue(path.hasPrefix(outDir))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0, 0)
    }

    func testTranscribe() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("transcribe needs macOS 26+") }
        let rec = try shortest()
        let r = try call(["action": "transcribe", "id": rec["id"]!, "inline": true])
        XCTAssertNotNil(r["text"] as? String)
        XCTAssertNotNil(r["word_count"] as? Int)
    }
}
