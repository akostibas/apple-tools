import XCTest
@testable import AppleToolsLib

private typealias Reply = (obj: [String: Any], text: String, isError: Bool)
private typealias TrackInfo = [String: Any]

private enum MusicLive {
    static func call(_ action: String, _ params: [String: Any] = [:]) -> Reply {
        var all = params.mapValues { AnyCodable($0) }
        all["action"] = AnyCodable(action)
        let (text, isError) = MusicTool().handle(params: all)
        let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (obj, text, isError)
    }

    /// For state the tool has no read for (volume, shuffle, repeat) and for putting playback back.
    static func script(_ body: String) -> String {
        let (out, err) = MusicIntegration.runAppleScript("tell application \"Music\"\n\(body)\nend tell", [:], nil)
        return err == nil ? out : "error: \(err!)"
    }

    static func id(_ track: TrackInfo?) -> String? { track?["database_id"] as? String }
    static func name(_ track: TrackInfo?) -> String { track?["name"] as? String ?? "?" }
    static func describe(_ track: TrackInfo?) -> String { "\"\(name(track))\" by \(track?["artist"] as? String ?? "?")" }

    static func find(_ track: TrackInfo) -> TrackInfo? {
        (call("search", ["query": name(track), "field": "title", "limit": 1]).obj["tracks"] as? [TrackInfo])?.first
    }

    /// Library tracks, never the cued one, that an action can be aimed at.
    static func pickTracks(_ count: Int, where ok: (TrackInfo) -> Bool) -> [TrackInfo] {
        let current = id(call("now-playing").obj["track"] as? TrackInfo)
        var picked: [TrackInfo] = []
        for track in call("search", ["query": "a", "limit": 40]).obj["tracks"] as? [TrackInfo] ?? [] {
            guard picked.count < count, let trackID = id(track), trackID != current, ok(track),
                  !picked.contains(where: { name($0) == name(track) }) else { continue }
            // Actions take a query, not an id: a track is usable only if its own title finds it first.
            if id(find(track)) == trackID { picked.append(track) }
        }
        return picked
    }
}

/// Live tests against the real Music library. They create one labeled playlist
/// and delete it, and change one track's favorite and rating and put them back;
/// they never touch playback. Run with `make test-slow TOOL=music`.
final class MusicLiveTests: XCTestCase {

    private let playlistName = "\(LiveTest.label) \(UUID().uuidString.prefix(8))"
    private var createdByUs = false

    override func setUpWithError() throws {
        try LiveTest.writes("music", "playlist-create", "playlist-delete", "playlist-add", "playlist-remove", "love", "rate")
        try LiveTest.requireRunning("Music")
    }

    override func tearDown() {
        // Only ever clean up a playlist this run made.
        if createdByUs { _ = run("playlist-delete") }
        super.tearDown()
    }

    private func run(_ action: String, query: String? = nil) -> Reply {
        var params: [String: Any] = ["name": playlistName]
        if let query { params["query"] = query; params["field"] = "title" }
        return MusicLive.call(action, params)
    }

    @discardableResult
    private func createPlaylist() throws -> Reply {
        let made = run("playlist-create")
        XCTAssertFalse(made.isError, made.text)
        // A pre-existing playlist with our name is not ours to delete.
        try XCTSkipIf(made.obj["already_existed"] as? Bool == true, "\(playlistName) already exists")
        createdByUs = true
        XCTAssertEqual(made.obj["verified"] as? Bool, true, made.text)
        return made
    }

    func testCreateThenDeletePlaylistLeavesNothingBehind() throws {
        let made = try createPlaylist()

        let deleted = run("playlist-delete")
        XCTAssertFalse(deleted.isError, deleted.text)
        XCTAssertEqual(deleted.obj["verified"] as? Bool, true, deleted.text)
        XCTAssertEqual(deleted.obj["playlist_id"] as? String, made.obj["playlist_id"] as? String)
        createdByUs = false

        let again = run("playlist-delete")
        XCTAssertTrue(again.isError, "playlist should be gone: \(again.text)")
        XCTAssertEqual(again.text, "no playlist named: \(playlistName)")
    }

    func testAddThenRemoveTrackOnOwnPlaylist() throws {
        let track = try XCTUnwrap(MusicLive.pickTracks(1) { _ in true }.first, "no library track to add")
        try createPlaylist()

        let added = run("playlist-add", query: MusicLive.name(track))
        XCTAssertFalse(added.isError, added.text)
        XCTAssertEqual(added.obj["verified"] as? Bool, true, added.text)
        XCTAssertEqual(MusicLive.id(added.obj["track"] as? TrackInfo), MusicLive.id(track), added.text)

        let removed = run("playlist-remove", query: MusicLive.name(track))
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(removed.obj["verified"] as? Bool, true, removed.text)
        XCTAssertEqual(MusicLive.id(removed.obj["track"] as? TrackInfo), MusicLive.id(track), removed.text)

        let again = run("playlist-remove", query: MusicLive.name(track))
        XCTAssertEqual(again.text, "no track matches: \(MusicLive.name(track))", "the playlist should be empty again")
    }

    func testFavoriteAndRatingChangeAndGoBack() throws {
        // Unrated and not favorited, so the restore cannot turn a rating Music computed from the album into a
        // real one; not disliked, because favoriting clears a dislike and the tool cannot put that back.
        let picked = MusicLive.pickTracks(1) { track in
            track["rating"] as? Int == 0 && track["loved"] as? Bool == false
                && MusicLive.script("return (disliked of (first track of library playlist 1 whose database ID is \(MusicLive.id(track) ?? "0"))) as text") == "false"
        }.first
        let track = try XCTUnwrap(picked, "no unrated, unfavorited library track found to test on")
        let query: [String: Any] = ["query": MusicLive.name(track), "field": "title"]

        addTeardownBlock {
            _ = MusicLive.call("love", query.merging(["state": "off"]) { a, _ in a })
            _ = MusicLive.call("rate", query.merging(["stars": 0]) { a, _ in a })
            let after = MusicLive.find(track)
            if after?["loved"] as? Bool != false || after?["rating"] as? Int != 0 {
                XCTFail("""
                    could not put \(MusicLive.describe(track)) back to not favorited and unrated. \
                    It now reads favorite=\(after?["loved"] ?? "?"), rating=\(after?["rating"] ?? "?"). Fix it in Music.
                    """)
            }
        }

        let loved = MusicLive.call("love", query.merging(["state": "on"]) { a, _ in a })
        XCTAssertFalse(loved.isError, loved.text)
        XCTAssertEqual(MusicLive.id(loved.obj["track"] as? TrackInfo), MusicLive.id(track), loved.text)
        XCTAssertEqual(loved.obj["verified"] as? Bool, true, loved.text)
        XCTAssertEqual(loved.obj["loved"] as? Bool, true, loved.text)

        let rated = MusicLive.call("rate", query.merging(["stars": 3]) { a, _ in a })
        XCTAssertFalse(rated.isError, rated.text)
        XCTAssertEqual(rated.obj["verified"] as? Bool, true, rated.text)
        XCTAssertEqual(rated.obj["stars"] as? Int, 3, rated.text)

        let readBack = MusicLive.find(track)
        XCTAssertEqual(readBack?["loved"] as? Bool, true, "a separate read should see the favorite")
        XCTAssertEqual(readBack?["rating"] as? Int, 60, "a separate read should see three stars")
    }
}

/// Live tests of everything that changes what you hear. They play a few seconds
/// of two library tracks at low volume, then put the player back as it was.
/// Run with `make test-attended TOOL=music`.
final class MusicPlaybackLiveTests: XCTestCase {

    private struct Player {
        var state = "", position = 0.0, volume = 0, shuffle = false, repeatMode = ""
        var track: TrackInfo?
        var playlistID = ""
        var outputs: [String] = []

        func samePlayback(as now: Player) -> Bool {
            guard now.state == state, MusicLive.id(now.track) == MusicLive.id(track) else { return false }
            // A playing track moves on by itself; a paused one must be where it was.
            return state == "playing" ? now.position >= position - 1 : abs(now.position - position) < 2
        }
    }

    private let playlistName = "\(LiveTest.label) \(UUID().uuidString.prefix(8))"
    private var before = Player()
    private var madePlaylist = false

    private func snapshot() -> Player {
        var player = Player()
        let now = MusicLive.call("now-playing").obj
        player.state = now["state"] as? String ?? ""
        player.position = now["position"] as? Double ?? 0
        player.track = now["track"] as? TrackInfo
        let devices = MusicLive.call("airplay-list").obj["devices"] as? [[String: Any]] ?? []
        player.outputs = devices.filter { $0["selected"] as? Bool == true }.compactMap { $0["name"] as? String }.sorted()
        let parts = MusicLive.script("""
            set listID to ""
            try
                set listID to (persistent ID of current playlist)
            end try
            return (sound volume as text) & "," & (shuffle enabled as text) & "," & (song repeat as text) & "," & listID
            """).components(separatedBy: ",")
        if parts.count == 4 {
            player.volume = Int(parts[0]) ?? -1
            player.shuffle = parts[1] == "true"
            player.repeatMode = parts[2]
            player.playlistID = parts[3]
        }
        return player
    }

    /// Finds the track that was cued, in the playlist it was playing from when Music names one, and runs `then` on it.
    private func withCuedTrack(_ then: String) -> String {
        MusicLive.script("""
            set t to missing value
            try
                set t to (first track of (first playlist whose persistent ID is "\(before.playlistID)") whose database ID is \(MusicLive.id(before.track) ?? "0"))
            end try
            if t is missing value then
                try
                    set t to (first track of library playlist 1 whose database ID is \(MusicLive.id(before.track) ?? "0"))
                end try
            end if
            if t is missing value then return "missing"
            \(then)
            return "ok"
            """)
    }

    override func setUpWithError() throws {
        try LiveTest.attended("music", "play", "pause", "playpause", "next", "previous", "stop", "seek",
                              "volume", "shuffle", "repeat", "airplay-select")
        try LiveTest.requireRunning("Music")
        before = snapshot()
        try XCTSkipIf(before.repeatMode.isEmpty, "could not read Music's volume, shuffle and repeat, so they could not be put back")
        addTeardownBlock { [self] in restore() }
    }

    private func restore() {
        var now = snapshot()
        if now.shuffle != before.shuffle { _ = MusicLive.call("shuffle", ["state": before.shuffle ? "on" : "off"]) }
        if now.repeatMode != before.repeatMode { _ = MusicLive.call("repeat", ["mode": before.repeatMode]) }
        if !before.samePlayback(as: now) {
            if before.track == nil {
                _ = MusicLive.call("stop")
            } else {
                // Silent while the user's track is found again, so a paused track is not heard restarting.
                _ = MusicLive.call("volume", ["level": 0])
                now.volume = 0
                _ = withCuedTrack("""
                    play t
                    \(MusicIntegration.waitUntil("player state is playing"))
                    set player position to \(before.position)
                    \(MusicIntegration.waitUntil("player position > \(before.position - 1)"))
                    \(before.state == "playing" ? "" : "pause")
                    delay 0.3
                    """)
            }
        }
        if now.volume != before.volume { _ = MusicLive.call("volume", ["level": before.volume]) }

        now = snapshot()
        var lost: [String] = []
        if madePlaylist, MusicLive.call("playlist-delete", ["name": playlistName]).obj["verified"] as? Bool != true {
            lost.append("the playlist \"\(playlistName)\" could not be deleted")
        }
        if !before.samePlayback(as: now) {
            lost.append("playback was \(before.state) on \(MusicLive.describe(before.track)) at \(Int(before.position))s, now \(now.state) on \(MusicLive.describe(now.track)) at \(Int(now.position))s")
        }
        if now.volume != before.volume { lost.append("volume was \(before.volume), now \(now.volume)") }
        if now.shuffle != before.shuffle { lost.append("shuffle was \(before.shuffle), now \(now.shuffle)") }
        if now.repeatMode != before.repeatMode { lost.append("repeat was \(before.repeatMode), now \(now.repeatMode)") }
        if now.outputs != before.outputs { lost.append("AirPlay output was \(before.outputs), now \(now.outputs)") }
        if !lost.isEmpty { XCTFail("could not put Music back as it was: " + lost.joined(separator: "; ") + ". Fix it in Music.") }
    }

    func testPlaybackControlsThenPutEverythingBack() throws {
        // A streamed track that is not in the library cannot be found again, so the test would lose the user's place.
        try XCTSkipIf(before.track != nil && withCuedTrack("") != "ok", """
            Music has \(MusicLive.describe(before.track)) cued from Apple Music, not from your library, and a streamed \
            track cannot be put back afterwards. Play any song from your library (paused is fine) and re-run.
            """)
        // Downloaded only: a cloud track can take seconds to buffer, and then play reads back as paused.
        let tracks = MusicLive.pickTracks(2) { $0["kind"] as? String == "file track" && $0["duration"] as? Double ?? 0 >= 60 }
        try XCTSkipIf(tracks.count < 2, "needs two downloaded library tracks of a minute or more to play")
        let made = MusicLive.call("playlist-create", ["name": playlistName])
        XCTAssertEqual(made.obj["verified"] as? Bool, true, made.text)
        madePlaylist = made.obj["already_existed"] as? Bool != true
        for track in tracks {
            let added = MusicLive.call("playlist-add", ["name": playlistName, "query": MusicLive.name(track), "field": "title"])
            XCTAssertEqual(added.obj["verified"] as? Bool, true, added.text)
        }
        let first = MusicLive.id(tracks[0]), second = MusicLive.id(tracks[1])

        // Quiet before anything is heard.
        let quiet = before.volume == 5 ? 4 : 5
        let volume = MusicLive.call("volume", ["level": quiet])
        XCTAssertEqual(volume.obj["volume"] as? Int, quiet, volume.text)

        func expect(_ reply: Reply, _ state: String, on trackID: String?, _ step: String) {
            XCTAssertFalse(reply.isError, "\(step): \(reply.text)")
            XCTAssertEqual(reply.obj["state"] as? String, state, "\(step): \(reply.text)")
            if let trackID { XCTAssertEqual(MusicLive.id(reply.obj["track"] as? TrackInfo), trackID, "\(step): \(reply.text)") }
        }
        // Which track comes first depends on the user's shuffle setting.
        expect(MusicLive.call("play", ["playlist": playlistName]), "playing", on: nil, "play a playlist")

        // With nothing cued, Music reports shuffle off and repeat off whatever they are, and ignores changes.
        // The real settings only show once something plays, so that is when they are recorded.
        if before.track == nil {
            let real = snapshot()
            before.shuffle = real.shuffle
            before.repeatMode = real.repeatMode
        }

        // Ends with shuffle off, so the playlist plays in order below.
        for (state, expected) in [("on", true), ("off", false)] {
            let shuffle = MusicLive.call("shuffle", ["state": state])
            XCTAssertEqual(shuffle.obj["shuffle"] as? Bool, expected, shuffle.text)
        }
        for mode in ["one", "all", "off"] {
            let repeated = MusicLive.call("repeat", ["mode": mode])
            XCTAssertEqual(repeated.obj["repeat"] as? String, mode, repeated.text)
        }

        expect(MusicLive.call("play", ["playlist": playlistName]), "playing", on: first, "play a playlist in order")
        expect(MusicLive.call("pause"), "paused", on: first, "pause")
        expect(MusicLive.call("play"), "playing", on: first, "play resumes")
        expect(MusicLive.call("playpause"), "paused", on: first, "playpause while playing")
        expect(MusicLive.call("playpause"), "playing", on: first, "playpause while paused")

        let seek = MusicLive.call("seek", ["position": 30])
        expect(seek, "playing", on: first, "seek")
        let position = seek.obj["position"] as? Double ?? -1
        XCTAssertTrue((29...35).contains(position), "seek to 30s landed at \(position)s")

        expect(MusicLive.call("next"), "playing", on: second, "next")
        expect(MusicLive.call("previous"), "playing", on: first, "previous")
        expect(MusicLive.call("stop"), "stopped", on: nil, "stop")
    }

    func testSelectingTheOutputAlreadyInUseKeepsIt() throws {
        // Re-selects the current output: proves the lookup, the command and the read-back, without moving the sound.
        let devices = MusicLive.call("airplay-list").obj["devices"] as? [[String: Any]] ?? []
        try XCTSkipIf(before.outputs.count != 1,
                      "selecting one output would drop the others; \(before.outputs.count) are selected")
        let device = before.outputs[0]
        try XCTSkipIf(devices.filter { $0["name"] as? String == device }.count != 1,
                      "more than one output is named \(device), so selecting by name could move the sound")

        let selected = MusicLive.call("airplay-select", ["device": device])
        XCTAssertFalse(selected.isError, selected.text)
        XCTAssertEqual(selected.obj["verified"] as? Bool, true, selected.text)
        XCTAssertEqual(selected.obj["device"] as? String, device, selected.text)
        XCTAssertEqual(snapshot().outputs, [device])
    }
}
