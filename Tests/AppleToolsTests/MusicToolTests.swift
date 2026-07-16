import XCTest
@testable import AppleToolsLib

final class MusicToolTests: XCTestCase {
    var tool: MusicTool!
    var savedRunner: ((String, [String: String], (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?))!

    private let fs = "\u{1F}"  // field separator
    private let ss = "\u{1E}"  // section separator

    override func setUp() {
        super.setUp()
        tool = MusicTool()
        savedRunner = MusicIntegration.runAppleScript
    }

    override func tearDown() {
        MusicIntegration.runAppleScript = savedRunner
        super.tearDown()
    }

    /// Build one track record line in the fixed field order the AppleScript
    /// emits. `playedComponents` is the raw "y,m,d,h,mm,ss" the date handler
    /// produces (empty = never played); `cloud` empty = missing value.
    private func trackLine(
        name: String, artist: String = "A", album: String = "Alb",
        duration: Double = 100, played: Int = 0, rating: Int = 0,
        loved: Bool = false, kind: String = "file track",
        cloud: String = "", playedComponents: String = "", id: String = "1"
    ) -> String {
        return [name, artist, album, "\(duration)", "\(played)", "\(rating)",
                "\(loved)", kind, cloud, playedComponents, id].joined(separator: fs)
    }

    private func json(_ result: String) -> [String: Any] {
        let data = result.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - Definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "music")
    }

    func testToolDefinitionRequiresAction() {
        XCTAssertEqual(tool.definition.parameters?.required, ["action"])
    }

    func testToolDefinitionAdvertisesActions() {
        let desc = tool.definition.description
        XCTAssertTrue(desc.contains("now-playing"))
        XCTAssertTrue(desc.contains("search"))
        XCTAssertTrue(desc.contains("stats"))
    }

    func testAccessPolicyClassifiesEveryActionAsRead() {
        guard case .perAction(let map) = tool.accessPolicy else {
            return XCTFail("expected per-action policy")
        }
        XCTAssertEqual(map["now-playing"], .read)
        XCTAssertEqual(map["search"], .read)
        XCTAssertEqual(map["stats"], .read)
    }

    // MARK: - Validation

    func testNilParams() {
        let (result, isError) = tool.handle(params: nil)
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    func testUnknownAction() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("bogus")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown action"))
    }

    func testSearchRequiresQuery() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("search")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("query"))
    }

    func testSearchRejectsInvalidField() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("x"),
            "field": AnyCodable("genre"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid field"))
    }

    func testStatsRequiresBy() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("stats")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("by"))
    }

    func testStatsRejectsInvalidBy() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("stats"),
            "by": AnyCodable("least-played"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid by"))
    }

    // MARK: - now-playing

    func testNowPlayingWithStreamingURLTrack() {
        // A pure Apple Music stream: URL track, no cloud status, never played.
        let track = trackLine(name: "Malaya (MIXED)", artist: "Lost Desert",
                              album: "Live in Stereo", duration: 327,
                              kind: "URL track", cloud: "", id: "35810")
        MusicIntegration.runAppleScript = { [fs, ss] _, _, _ in
            ("playing\(fs)36.0\(ss)\(track)", nil)
        }
        let (result, isError) = tool.handle(params: ["action": AnyCodable("now-playing")])
        XCTAssertFalse(isError)
        let obj = json(result)
        XCTAssertEqual(obj["state"] as? String, "playing")
        XCTAssertEqual(obj["position"] as? Double, 36.0)
        let t = obj["track"] as? [String: Any]
        XCTAssertEqual(t?["name"] as? String, "Malaya (MIXED)")
        XCTAssertEqual(t?["artist"] as? String, "Lost Desert")
        XCTAssertEqual(t?["kind"] as? String, "URL track")
        // A stream has no cloud_status — the key should be absent, not null.
        XCTAssertNil(t?["cloud_status"])
    }

    func testNowPlayingStoppedHasNoTrack() {
        MusicIntegration.runAppleScript = { [fs, ss] _, _, _ in
            ("stopped\(fs)\(ss)", nil)
        }
        let (result, isError) = tool.handle(params: ["action": AnyCodable("now-playing")])
        XCTAssertFalse(isError)
        let obj = json(result)
        XCTAssertEqual(obj["state"] as? String, "stopped")
        XCTAssertNil(obj["track"])
    }

    func testNowPlayingSurfacesScriptError() {
        MusicIntegration.runAppleScript = { _, _, _ in ("", "not authorized") }
        let (result, isError) = tool.handle(params: ["action": AnyCodable("now-playing")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not authorized"))
    }

    // MARK: - search

    func testSearchReturnsCountAndDistinguishesCloudContent() {
        let downloaded = trackLine(name: "Malaya (MIXED)", artist: "Lost Desert",
                                   kind: "file track", cloud: "subscription", id: "1")
        let ownFile = trackLine(name: "Malaya Demo", artist: "Me",
                                kind: "file track", cloud: "", id: "2")
        MusicIntegration.runAppleScript = { _, env, _ in
            XCTAssertEqual(env["APPLE_TOOLS_MUSIC_QUERY"], "malaya",
                           "query must be passed via env var, not interpolated")
            return ([downloaded, ownFile].joined(separator: "\n"), nil)
        }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("malaya"),
        ])
        XCTAssertFalse(isError)
        let obj = json(result)
        XCTAssertEqual(obj["count"] as? Int, 2)
        let tracks = obj["tracks"] as? [[String: Any]]
        // Streamed-in catalog content carries cloud_status: subscription; the
        // user's own file has none.
        XCTAssertEqual(tracks?[0]["cloud_status"] as? String, "subscription")
        XCTAssertNil(tracks?[1]["cloud_status"])
    }

    // MARK: - stats

    func testStatsMostPlayedSortsDescendingAndDropsUnplayed() {
        MusicIntegration.runAppleScript = { [weak self] _, _, _ in
            guard let self = self else { return ("", nil) }
            return ([
                self.trackLine(name: "Low", played: 3, id: "1"),
                self.trackLine(name: "High", played: 40, id: "2"),
                self.trackLine(name: "Never", played: 0, id: "3"),
            ].joined(separator: "\n"), nil)
        }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("stats"),
            "by": AnyCodable("most-played"),
        ])
        XCTAssertFalse(isError)
        let obj = json(result)
        XCTAssertEqual(obj["source"] as? String, "local")
        XCTAssertEqual(obj["by"] as? String, "most-played")
        let names = (obj["tracks"] as? [[String: Any]])?.map { $0["name"] as? String }
        XCTAssertEqual(names, ["High", "Low"], "unplayed track dropped, rest sorted desc")
    }

    func testStatsMostLovedFiltersToLoved() {
        MusicIntegration.runAppleScript = { [weak self] _, _, _ in
            guard let self = self else { return ("", nil) }
            return ([
                self.trackLine(name: "Loved A", played: 5, loved: true, id: "1"),
                self.trackLine(name: "Not Loved", played: 99, loved: false, id: "2"),
                self.trackLine(name: "Loved B", played: 10, loved: true, id: "3"),
            ].joined(separator: "\n"), nil)
        }
        let (result, _) = tool.handle(params: [
            "action": AnyCodable("stats"),
            "by": AnyCodable("most-loved"),
        ])
        let names = (json(result)["tracks"] as? [[String: Any]])?.map { $0["name"] as? String }
        XCTAssertEqual(names, ["Loved B", "Loved A"], "only loved, sorted by play count desc")
    }

    func testStatsRecentlyPlayedSortsByDateAndConvertsToISO() {
        MusicIntegration.runAppleScript = { [weak self] _, _, _ in
            guard let self = self else { return ("", nil) }
            return ([
                self.trackLine(name: "Older", playedComponents: "2026,7,10,9,0,0", id: "1"),
                self.trackLine(name: "Newer", playedComponents: "2026,7,14,22,0,0", id: "2"),
                self.trackLine(name: "Never", playedComponents: "", id: "3"),
            ].joined(separator: "\n"), nil)
        }
        let (result, _) = tool.handle(params: [
            "action": AnyCodable("stats"),
            "by": AnyCodable("recently-played"),
        ])
        let tracks = json(result)["tracks"] as? [[String: Any]]
        let names = tracks?.map { $0["name"] as? String }
        XCTAssertEqual(names, ["Newer", "Older"], "never-played dropped, rest newest-first")
        // Raw "y,m,d,…" components were converted to canonical ISO-8601 (UTC),
        // not passed through verbatim.
        let played = tracks?[0]["played_date"] as? String
        XCTAssertNotNil(played)
        XCTAssertTrue(played?.contains("T") ?? false, "expected ISO datetime, got \(played ?? "nil")")
        XCTAssertTrue(played?.hasSuffix("Z") ?? false, "expected UTC ISO, got \(played ?? "nil")")
        XCTAssertFalse(played?.contains(",") ?? true, "raw components leaked instead of ISO")
    }

    func testStatsRespectsLimit() {
        MusicIntegration.runAppleScript = { [weak self] _, _, _ in
            guard let self = self else { return ("", nil) }
            let lines = (1...10).map { self.trackLine(name: "T\($0)", played: $0, id: "\($0)") }
            return (lines.joined(separator: "\n"), nil)
        }
        let (result, _) = tool.handle(params: [
            "action": AnyCodable("stats"),
            "by": AnyCodable("most-played"),
            "limit": AnyCodable(3),
        ])
        let tracks = json(result)["tracks"] as? [[String: Any]]
        XCTAssertEqual(tracks?.count, 3)
    }

    // MARK: - parsing

    func testParseTrackRecordRatingToStars() {
        MusicIntegration.runAppleScript = { [weak self] _, _, _ in
            (self!.trackLine(name: "Four Star", rating: 80), nil)
        }
        let (result, _) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("four"),
        ])
        let tracks = json(result)["tracks"] as? [[String: Any]]
        XCTAssertEqual(tracks?[0]["rating"] as? Int, 80)
        XCTAssertEqual(tracks?[0]["stars"] as? Int, 4)
    }

    func testParseTrackRecordSkipsMalformedLines() {
        MusicIntegration.runAppleScript = { [fs] _, _, _ in
            // Second line has too few fields — must be dropped, not crash.
            ("Good\(fs)Artist\(fs)Album\(fs)100\(fs)0\(fs)0\(fs)false\(fs)file track\(fs)\(fs)\(fs)1\ntoo\(fs)few", nil)
        }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "query": AnyCodable("x"),
        ])
        XCTAssertFalse(isError)
        XCTAssertEqual(json(result)["count"] as? Int, 1)
    }
}
