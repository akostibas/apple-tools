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
        cloud: String = "", playedComponents: String = "", id: String = "1",
        addedComponents: String = ""
    ) -> String {
        return [name, artist, album, "\(duration)", "\(played)", "\(rating)",
                "\(loved)", kind, cloud, playedComponents, id, addedComponents].joined(separator: fs)
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

    // MARK: - mix (derived pick queries)

    /// Fixed reference "now" so relative-date logic is deterministic.
    private let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!

    /// ISO-8601 (UTC) timestamp `daysAgo` before `now`.
    private func iso(daysAgo: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f.string(from: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func mkTrack(
        name: String, played: Int = 0, rating: Int = 0, loved: Bool = false,
        playedDate: String? = nil, dateAdded: String? = nil, id: String = "1"
    ) -> MusicIntegration.Track {
        MusicIntegration.Track(
            name: name, artist: "A", album: "Alb", duration: 100,
            playedCount: played, rating: rating, loved: loved,
            kind: "file track", cloudStatus: nil,
            playedDate: playedDate, databaseID: id, dateAdded: dateAdded
        )
    }

    private func rank(_ tracks: [MusicIntegration.Track], by: MusicIntegration.MixKind,
                      months: Int = 6, days: Int = 30, limit: Int = 20) -> [String] {
        MusicIntegration.rankMix(tracks, by: by, limit: limit, months: months, days: days, now: now)
            .map { $0.name }
    }

    func testMixNeglectedFavoritesFiltersToStaleFavorites() {
        let tracks = [
            mkTrack(name: "LovedFresh", loved: true, playedDate: iso(daysAgo: 5), id: "1"),   // favorite but played recently → out
            mkTrack(name: "LovedStale", loved: true, playedDate: iso(daysAgo: 400), id: "2"), // favorite, cold → in
            mkTrack(name: "HighRatedStale", rating: 100, playedDate: iso(daysAgo: 300), id: "3"), // 5★ cold → in
            mkTrack(name: "NeverHeardFav", loved: true, playedDate: nil, id: "4"),             // favorite never played → in, first
            mkTrack(name: "PlainStale", rating: 40, playedDate: iso(daysAgo: 400), id: "5"),   // not a favorite → out
        ]
        let names = rank(tracks, by: .neglectedFavorites)
        // Never-heard favorite first (most neglected), then oldest-played:
        // LovedStale (400d ago) is older/colder than HighRatedStale (300d ago).
        XCTAssertEqual(names, ["NeverHeardFav", "LovedStale", "HighRatedStale"])
    }

    func testMixRediscoverNeedsHighPlaysAndStaleness() {
        let tracks = [
            mkTrack(name: "HeavyStale", played: 40, playedDate: iso(daysAgo: 400), id: "1"), // in
            mkTrack(name: "HeavyFresh", played: 40, playedDate: iso(daysAgo: 3), id: "2"),   // played recently → out
            mkTrack(name: "LightStale", played: 2, playedDate: iso(daysAgo: 400), id: "3"),  // too few plays → out
            mkTrack(name: "MediumStale", played: 12, playedDate: iso(daysAgo: 400), id: "4"),// in
        ]
        let names = rank(tracks, by: .rediscover)
        XCTAssertEqual(names, ["HeavyStale", "MediumStale"], "high-play cold tracks, most-played first")
    }

    func testMixVelocityRanksPlaysPerDaySinceAdded() {
        let tracks = [
            mkTrack(name: "OldWarhorse", played: 40, dateAdded: iso(daysAgo: 2000), id: "1"), // 0.02/day
            mkTrack(name: "FreshObsession", played: 8, dateAdded: iso(daysAgo: 7), id: "2"),  // ~1.1/day
            mkTrack(name: "Never", played: 0, dateAdded: iso(daysAgo: 5), id: "3"),           // no plays → excluded
        ]
        let names = rank(tracks, by: .velocity)
        XCTAssertEqual(names, ["FreshObsession", "OldWarhorse"],
                       "recent obsession outranks old warhorse despite fewer total plays")
    }

    func testMixFreshFiltersRecentlyAddedAndBarelyPlayed() {
        let tracks = [
            mkTrack(name: "NewUnplayed", played: 0, dateAdded: iso(daysAgo: 3), id: "1"),  // in
            mkTrack(name: "NewButPlayed", played: 9, dateAdded: iso(daysAgo: 3), id: "2"), // played a lot → out
            mkTrack(name: "OldUnplayed", played: 0, dateAdded: iso(daysAgo: 400), id: "3"),// added long ago → out
            mkTrack(name: "NewestBarely", played: 1, dateAdded: iso(daysAgo: 1), id: "4"), // in, newest
        ]
        let names = rank(tracks, by: .fresh)
        XCTAssertEqual(names, ["NewestBarely", "NewUnplayed"], "recent + barely-played, newest add first")
    }

    func testMixUnplayedGemsAreFlaggedNeverPlayed() {
        let tracks = [
            mkTrack(name: "GemA", played: 0, rating: 100, dateAdded: iso(daysAgo: 10), id: "1"),
            mkTrack(name: "GemB", played: 0, loved: true, dateAdded: iso(daysAgo: 5), id: "2"),
            mkTrack(name: "PlayedGem", played: 3, rating: 100, id: "3"), // played → out
            mkTrack(name: "PlainUnplayed", played: 0, rating: 20, id: "4"), // not a favorite → out
        ]
        let names = rank(tracks, by: .unplayedGems)
        // Higher rating first (GemA 100 > GemB's loved-only 0 rating).
        XCTAssertEqual(names, ["GemA", "GemB"])
    }

    func testMixRespectsLimit() {
        let tracks = (1...10).map { mkTrack(name: "T\($0)", played: $0 * 10, dateAdded: iso(daysAgo: 5), id: "\($0)") }
        XCTAssertEqual(rank(tracks, by: .velocity, limit: 3).count, 3)
    }

    // MARK: - mix wiring (through the tool)

    func testMixRejectsInvalidBy() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("mix"),
            "by": AnyCodable("bangers"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("invalid by"))
    }

    func testMixRequiresBy() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("mix")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("by"))
    }

    func testMixThroughToolReturnsLocalSourceEnvelope() {
        MusicIntegration.runAppleScript = { [weak self] _, _, _ in
            guard let self = self else { return ("", nil) }
            // Two loved-but-never-played gems.
            return ([
                self.trackLine(name: "Gem", played: 0, loved: true, id: "1", addedComponents: "2026,7,1,0,0,0"),
            ].joined(separator: "\n"), nil)
        }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("mix"),
            "by": AnyCodable("unplayed-gems"),
        ])
        XCTAssertFalse(isError)
        let obj = json(result)
        XCTAssertEqual(obj["source"] as? String, "local")
        XCTAssertEqual(obj["by"] as? String, "unplayed-gems")
        XCTAssertEqual(obj["count"] as? Int, 1)
    }

    // MARK: - playback control (Group B)

    func testControlActionsAreReadWrite() {
        guard case .perAction(let map) = tool.accessPolicy else { return XCTFail() }
        for action in ["play", "pause", "playpause", "next", "previous", "stop",
                       "volume", "shuffle", "repeat", "seek"] {
            XCTAssertEqual(map[action], .readWrite, "\(action) must be classified read/write")
        }
    }

    /// Capture the AppleScript a control action generates, returning a canned
    /// now-playing line so the confirmation envelope is exercised too.
    private func captureScript(_ params: [String: AnyCodable], stdout: String? = nil) -> (script: String, env: [String: String], result: String) {
        var captured = ""
        var capturedEnv: [String: String] = [:]
        MusicIntegration.runAppleScript = { [ss, fs] script, env, _ in
            captured = script
            capturedEnv = env
            return (stdout ?? "playing\(fs)5\(ss)", nil)
        }
        let (result, _) = tool.handle(params: params)
        return (captured, capturedEnv, result)
    }

    func testPauseIssuesPauseAndReportsState() {
        let (script, _, result) = captureScript(["action": AnyCodable("pause")],
                                                 stdout: "paused\(fs)5\(ss)")
        XCTAssertTrue(script.contains("pause"))
        let obj = json(result)
        XCTAssertEqual(obj["ok"] as? Bool, true)
        XCTAssertEqual(obj["state"] as? String, "paused")
    }

    func testNextUsesNextTrackVerb() {
        let (script, _, _) = captureScript(["action": AnyCodable("next")])
        XCTAssertTrue(script.contains("next track"))
    }

    func testPreviousUsesPreviousTrackVerb() {
        let (script, _, _) = captureScript(["action": AnyCodable("previous")])
        XCTAssertTrue(script.contains("previous track"))
    }

    func testPlayResumesWhenNoTarget() {
        let (script, env, _) = captureScript(["action": AnyCodable("play")])
        XCTAssertTrue(script.contains("play"))
        XCTAssertTrue(env.isEmpty, "bare play passes no query/playlist env")
    }

    func testPlayPlaylistPassesNameViaEnv() {
        let (script, env, _) = captureScript([
            "action": AnyCodable("play"),
            "playlist": AnyCodable("Road Trip"),
        ])
        XCTAssertEqual(env["APPLE_TOOLS_MUSIC_PLAYLIST"], "Road Trip")
        XCTAssertTrue(script.contains("user playlist"))
    }

    func testPlayQueryPassesQueryViaEnvAndMatchesField() {
        let (script, env, _) = captureScript([
            "action": AnyCodable("play"),
            "query": AnyCodable("hey jude"),
            "field": AnyCodable("title"),
        ])
        XCTAssertEqual(env["APPLE_TOOLS_MUSIC_QUERY"], "hey jude")
        XCTAssertTrue(script.contains("name contains theQuery"))
    }

    func testPlayQueryNoMatchReturnsError() {
        MusicIntegration.runAppleScript = { _, _, _ in ("", "error \"NO_MATCH\"") }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("play"),
            "query": AnyCodable("zzznope"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("no library track matches"))
    }

    func testVolumeSetsClampedLevel() {
        let (script, _, result) = captureScript([
            "action": AnyCodable("volume"),
            "level": AnyCodable(60),
        ], stdout: "60")
        XCTAssertTrue(script.contains("set sound volume to 60"))
        XCTAssertEqual(json(result)["volume"] as? Int, 60)
    }

    func testVolumeRequiresLevel() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("volume")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("level"))
    }

    func testShuffleOnSetsEnabledTrue() {
        let (script, _, result) = captureScript([
            "action": AnyCodable("shuffle"),
            "state": AnyCodable("on"),
        ], stdout: "true")
        XCTAssertTrue(script.contains("set shuffle enabled to true"))
        XCTAssertEqual(json(result)["shuffle"] as? Bool, true)
    }

    func testShuffleRejectsBadState() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("shuffle"),
            "state": AnyCodable("maybe"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("on or off"))
    }

    func testRepeatSetsMode() {
        let (script, _, result) = captureScript([
            "action": AnyCodable("repeat"),
            "mode": AnyCodable("all"),
        ], stdout: "all")
        XCTAssertTrue(script.contains("set song repeat to all"))
        XCTAssertEqual(json(result)["repeat"] as? String, "all")
    }

    func testRepeatRejectsBadMode() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("repeat"),
            "mode": AnyCodable("sometimes"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("off, one, or all"))
    }

    func testSeekSetsPlayerPosition() {
        let (script, _, _) = captureScript([
            "action": AnyCodable("seek"),
            "position": AnyCodable(90),
        ])
        XCTAssertTrue(script.contains("set player position to 90"))
    }

    func testSeekRequiresPosition() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("seek")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("position"))
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
