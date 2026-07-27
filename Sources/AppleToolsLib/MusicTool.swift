import Foundation

/// Read-only Apple Music / Music.app tool. Covers the zero-auth local surface:
/// what's playing, searching the local library, and local play-history stats.
/// Catalog search, playback control, and true cross-device history are out of
/// scope here (issue #55, #56).
public struct MusicTool: ProbeTool {
    private static let defaultSearchLimit = 25
    private static let defaultStatsLimit = 20
    private static let defaultMixLimit = 20
    private static let defaultStaleMonths = 6
    private static let defaultFreshDays = 30

    public let definition = ToolDefinition(
        name: "music",
        description: "Read and control Apple Music / Music.app. Read: 'now-playing' (current track + state, works for streams), 'search' (local library), 'stats' (raw play history: most-played, recently-played, most-loved), 'mix' ('what to play now' picks: neglected-favorites, rediscover, velocity, fresh, unplayed-gems), 'airplay-list' (output devices). Control: 'play' (resume, or a --playlist / --query), 'pause', 'playpause', 'next', 'previous', 'stop', 'volume' (--level 0-100), 'shuffle' (--state on|off), 'repeat' (--mode off|one|all), 'seek' (--position seconds), 'airplay-select' (--device). Curate (edits the library — each reads back and reports 'verified'): 'love' (--state on|off, current track or --query), 'rate' (--stars 0-5, current track or --query), 'playlist-create' (--name), 'playlist-add' (--name --query), 'playlist-remove' (--name --query). Play counts/dates are local to THIS Mac, not your full cross-device Apple Music history.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "now-playing, search, stats, mix, play, pause, playpause, next, previous, stop, volume, shuffle, repeat, seek, love, rate, playlist-create, playlist-add, playlist-remove, airplay-list, or airplay-select"),
                "query": PropertySchema(type_: "string", description: "Text to match (required for search, playlist-add, playlist-remove; optional for play/love/rate — targets the top library match)",
                    summary: "Search / target-match text", actions: ["search", "play", "love", "rate", "playlist-add", "playlist-remove"]),
                "field": PropertySchema(type_: "string", description: "Which field to match: any (default), title, artist, or album",
                    summary: "Match field: any (default), title, artist, album", actions: ["search", "play", "love", "rate", "playlist-add", "playlist-remove"]),
                "playlist": PropertySchema(type_: "string", description: "Play a user playlist by name (for play)",
                    summary: "Playlist name to play", actions: ["play"]),
                "name": PropertySchema(type_: "string", description: "User playlist name (required for playlist-create, playlist-add, playlist-remove)",
                    summary: "Playlist name", actions: ["playlist-create", "playlist-add", "playlist-remove"]),
                "stars": PropertySchema(type_: "integer", description: "Star rating 0–5 (required for rate; 0 clears it)",
                    summary: "Star rating 0–5", actions: ["rate"]),
                "device": PropertySchema(type_: "string", description: "AirPlay device name, exact match (required for airplay-select)",
                    summary: "AirPlay device name", actions: ["airplay-select"]),
                "by": PropertySchema(type_: "string", description: "For stats: most-played, recently-played, most-loved. For mix: neglected-favorites, rediscover, velocity, fresh, unplayed-gems. (required for stats and mix)",
                    summary: "Ranking / pick query", actions: ["stats", "mix"]),
                "months": PropertySchema(type_: "integer", description: "Staleness window in months for mix neglected-favorites/rediscover — 'not heard in the last N months' (default 6)",
                    summary: "Staleness window (months, default 6)", actions: ["mix"]),
                "days": PropertySchema(type_: "integer", description: "Recency window in days for mix fresh — 'added in the last N days' (default 30)",
                    summary: "Recency window (days, default 30)", actions: ["mix"]),
                "limit": PropertySchema(type_: "integer", description: "Max results (search default 25, stats/mix default 20)",
                    summary: "Max results", actions: ["search", "stats", "mix"]),
                "level": PropertySchema(type_: "integer", description: "Volume 0–100 (required for volume)",
                    summary: "Volume 0–100", actions: ["volume"]),
                "state": PropertySchema(type_: "string", description: "on or off (required for shuffle and love)",
                    summary: "on or off", actions: ["shuffle", "love"]),
                "mode": PropertySchema(type_: "string", description: "Repeat mode: off, one, or all (required for repeat)",
                    summary: "off, one, or all", actions: ["repeat"]),
                "position": PropertySchema(type_: "integer", description: "Seconds into the current track (required for seek)",
                    summary: "Seconds into the track", actions: ["seek"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Read & control Apple Music — now playing, search, stats, mixes, and playback.",
        actions: [
            ActionHelp(name: "now-playing", summary: "Show the current track and player state",
                example: "apple-tools music now-playing"),
            ActionHelp(name: "search", summary: "Find tracks in the local library",
                example: "apple-tools music search --query <text> [--field any|title|artist|album] [--limit N]", required: ["query"]),
            ActionHelp(name: "stats", summary: "Rank the library by raw local play history",
                example: "apple-tools music stats --by most-played|recently-played|most-loved [--limit N]", required: ["by"]),
            ActionHelp(name: "mix", summary: "Derived 'what should I play right now' picks",
                example: "apple-tools music mix --by neglected-favorites|rediscover|velocity|fresh|unplayed-gems [--months N] [--days N] [--limit N]", required: ["by"]),
            ActionHelp(name: "play", summary: "Resume, or play a playlist / library match",
                example: "apple-tools music play [--playlist <name>] [--query <text> [--field …]]"),
            ActionHelp(name: "pause", summary: "Pause playback", example: "apple-tools music pause"),
            ActionHelp(name: "playpause", summary: "Toggle play/pause", example: "apple-tools music playpause"),
            ActionHelp(name: "next", summary: "Skip to the next track", example: "apple-tools music next"),
            ActionHelp(name: "previous", summary: "Go to the previous track", example: "apple-tools music previous"),
            ActionHelp(name: "stop", summary: "Stop playback", example: "apple-tools music stop"),
            ActionHelp(name: "volume", summary: "Set the app volume (0–100)",
                example: "apple-tools music volume --level 60", required: ["level"]),
            ActionHelp(name: "shuffle", summary: "Turn shuffle on or off",
                example: "apple-tools music shuffle --state on", required: ["state"]),
            ActionHelp(name: "repeat", summary: "Set repeat mode",
                example: "apple-tools music repeat --mode all", required: ["mode"]),
            ActionHelp(name: "seek", summary: "Jump to a position in the current track",
                example: "apple-tools music seek --position 90", required: ["position"]),
            ActionHelp(name: "love", summary: "Favorite/unfavorite the current or matched track (verifies)",
                example: "apple-tools music love --state on [--query <text>]", required: ["state"]),
            ActionHelp(name: "rate", summary: "Set a 0–5 star rating on the current or matched track (verifies)",
                example: "apple-tools music rate --stars 5 [--query <text>]", required: ["stars"]),
            ActionHelp(name: "playlist-create", summary: "Create a user playlist (idempotent by name)",
                example: "apple-tools music playlist-create --name \"Road Trip\"", required: ["name"]),
            ActionHelp(name: "playlist-add", summary: "Add a matching library track to a playlist (verifies)",
                example: "apple-tools music playlist-add --name \"Road Trip\" --query \"hey jude\"", required: ["name", "query"]),
            ActionHelp(name: "playlist-remove", summary: "Remove a matching track from a playlist (verifies)",
                example: "apple-tools music playlist-remove --name \"Road Trip\" --query \"hey jude\"", required: ["name", "query"]),
            ActionHelp(name: "airplay-list", summary: "List AirPlay output devices",
                example: "apple-tools music airplay-list"),
            ActionHelp(name: "airplay-select", summary: "Route output to an AirPlay device (verifies)",
                example: "apple-tools music airplay-select --device \"Living Room\"", required: ["device"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "now-playing": .read,
        "search":      .read,
        "stats":       .read,
        "mix":         .read,
        "play":        .readWrite,
        "pause":       .readWrite,
        "playpause":   .readWrite,
        "next":        .readWrite,
        "previous":    .readWrite,
        "stop":        .readWrite,
        "volume":      .readWrite,
        "shuffle":     .readWrite,
        "repeat":      .readWrite,
        "seek":        .readWrite,
        "love":            .readWrite,
        "rate":            .readWrite,
        "playlist-create": .readWrite,
        "playlist-add":    .readWrite,
        "playlist-remove": .readWrite,
        "airplay-list":    .read,
        "airplay-select":  .readWrite,
    ])

    public init() {}

    public func preflight() -> (ok: Bool, message: String) {
        return MusicIntegration.preflight()
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "now-playing":
            return nowPlaying()
        case "search":
            guard let query = params?["query"]?.value as? String, !query.isEmpty else {
                return ("missing required parameter: query", true)
            }
            let fieldRaw = (params?["field"]?.value as? String) ?? "any"
            guard let field = MusicIntegration.SearchField(rawValue: fieldRaw) else {
                return ("invalid field: \(fieldRaw) (use any, title, artist, or album)", true)
            }
            let limit = intParam(params, "limit") ?? Self.defaultSearchLimit
            return search(query: query, field: field, limit: limit)
        case "stats":
            guard let byRaw = params?["by"]?.value as? String, !byRaw.isEmpty else {
                return ("missing required parameter: by", true)
            }
            guard let by = MusicIntegration.StatKind(rawValue: byRaw) else {
                return ("invalid by: \(byRaw) (use most-played, recently-played, or most-loved)", true)
            }
            let limit = intParam(params, "limit") ?? Self.defaultStatsLimit
            return stats(by: by, limit: limit)
        case "mix":
            guard let byRaw = params?["by"]?.value as? String, !byRaw.isEmpty else {
                return ("missing required parameter: by", true)
            }
            guard let by = MusicIntegration.MixKind(rawValue: byRaw) else {
                return ("invalid by: \(byRaw) (use neglected-favorites, rediscover, velocity, fresh, or unplayed-gems)", true)
            }
            let limit = intParam(params, "limit") ?? Self.defaultMixLimit
            let months = intParam(params, "months") ?? Self.defaultStaleMonths
            let days = intParam(params, "days") ?? Self.defaultFreshDays
            return mix(by: by, limit: limit, months: months, days: days)

        // MARK: Playback control (Group B)
        case "play":
            return play(params: params)
        case "pause":
            return transport("pause")
        case "playpause":
            return transport("playpause")
        case "next":
            return transport("next track")
        case "previous":
            return transport("previous track")
        case "stop":
            return transport("stop")
        case "volume":
            guard let level = intParam(params, "level") else {
                return ("missing required parameter: level (0–100)", true)
            }
            return volume(level: level)
        case "shuffle":
            guard let state = params?["state"]?.value as? String, let on = onOff(state) else {
                return ("shuffle requires --state on or off", true)
            }
            return shuffle(on: on)
        case "repeat":
            guard let mode = params?["mode"]?.value as? String,
                  ["off", "one", "all"].contains(mode) else {
                return ("repeat requires --mode off, one, or all", true)
            }
            return repeatMode(mode)
        case "seek":
            guard let position = intParam(params, "position") else {
                return ("missing required parameter: position (seconds)", true)
            }
            return report { try MusicIntegration.seek(toSeconds: position) }

        // MARK: Curation (Group C)
        case "love":
            guard let s = params?["state"]?.value as? String, let on = onOff(s) else {
                return ("love requires --state on or off", true)
            }
            return curationTarget(params) { query, field in
                try MusicIntegration.setLoved(on, query: query, field: field)
            } render: { curationDict($0, valueKey: "loved", value: $0.value == 1) }
        case "rate":
            guard let stars = intParam(params, "stars"), (0...5).contains(stars) else {
                return ("rate requires --stars 0–5", true)
            }
            return curationTarget(params) { query, field in
                try MusicIntegration.setRating(stars: stars, query: query, field: field)
            } render: { curationDict($0, valueKey: "rating", value: $0.value, extra: ["stars": $0.value / 20]) }
        case "playlist-create":
            guard let name = params?["name"]?.value as? String, !name.isEmpty else {
                return ("missing required parameter: name", true)
            }
            return playlist { try MusicIntegration.createPlaylist(name) }
        case "playlist-add":
            return playlistTrack(params, add: true)
        case "playlist-remove":
            return playlistTrack(params, add: false)
        case "airplay-list":
            return airplayList()
        case "airplay-select":
            guard let device = params?["device"]?.value as? String, !device.isEmpty else {
                return ("missing required parameter: device", true)
            }
            do {
                let r = try MusicIntegration.airplaySelect(device)
                return (jsonString(["ok": true, "verified": r.verified, "device": r.name]) ?? "{}", false)
            } catch { return (errorText(error), true) }
        default:
            return ("unknown action: \(action) (use now-playing, search, stats, mix, play, pause, playpause, next, previous, stop, volume, shuffle, repeat, seek, love, rate, playlist-create, playlist-add, playlist-remove, airplay-list, or airplay-select)", true)
        }
    }

    // MARK: - Curation

    /// Resolve the optional `--query`/`--field` target, run a curation write,
    /// and render its `{ok, verified, track}` envelope.
    private func curationTarget(
        _ params: [String: AnyCodable]?,
        _ body: (_ query: String?, _ field: MusicIntegration.SearchField) throws -> MusicIntegration.CurationResult,
        render: (MusicIntegration.CurationResult) -> [String: Any]
    ) -> (String, Bool) {
        let query = (params?["query"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fieldRaw = (params?["field"]?.value as? String) ?? "any"
        guard let field = MusicIntegration.SearchField(rawValue: fieldRaw) else {
            return ("invalid field: \(fieldRaw) (use any, title, artist, or album)", true)
        }
        do {
            let result = try body(query, field)
            return (jsonString(render(result)) ?? "{}", false)
        } catch { return (errorText(error), true) }
    }

    private func curationDict(_ r: MusicIntegration.CurationResult, valueKey: String, value: Any,
                              extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = ["ok": true, "verified": r.verified, valueKey: value]
        for (k, v) in extra { dict[k] = v }
        if let track = r.track { dict["track"] = trackDict(track) }
        return dict
    }

    private func playlist(_ body: () throws -> MusicIntegration.PlaylistResult) -> (String, Bool) {
        do {
            let r = try body()
            var dict: [String: Any] = ["ok": true, "verified": r.verified]
            if r.already { dict["already_existed"] = true }
            if let id = r.playlistID { dict["playlist_id"] = id }
            if let track = r.track { dict["track"] = trackDict(track) }
            return (jsonString(dict) ?? "{}", false)
        } catch { return (errorText(error), true) }
    }

    private func playlistTrack(_ params: [String: AnyCodable]?, add: Bool) -> (String, Bool) {
        guard let name = params?["name"]?.value as? String, !name.isEmpty else {
            return ("missing required parameter: name", true)
        }
        guard let query = params?["query"]?.value as? String, !query.isEmpty else {
            return ("missing required parameter: query", true)
        }
        let fieldRaw = (params?["field"]?.value as? String) ?? "any"
        guard let field = MusicIntegration.SearchField(rawValue: fieldRaw) else {
            return ("invalid field: \(fieldRaw) (use any, title, artist, or album)", true)
        }
        return playlist {
            add ? try MusicIntegration.playlistAdd(name: name, query: query, field: field)
                : try MusicIntegration.playlistRemove(name: name, query: query, field: field)
        }
    }

    private func airplayList() -> (String, Bool) {
        do {
            let devices = try MusicIntegration.airplayList()
            let rows: [[String: Any]] = devices.map { d in
                var dict: [String: Any] = ["name": d.name, "selected": d.selected, "kind": d.kind]
                if let vol = d.volume { dict["volume"] = vol }
                return dict
            }
            return (jsonString(["count": devices.count, "devices": rows]) ?? "{}", false)
        } catch { return (errorText(error), true) }
    }

    // MARK: - Playback control

    private func play(params: [String: AnyCodable]?) -> (String, Bool) {
        if let playlist = params?["playlist"]?.value as? String, !playlist.isEmpty {
            return report { try MusicIntegration.playPlaylist(playlist) }
        }
        if let query = params?["query"]?.value as? String, !query.isEmpty {
            let fieldRaw = (params?["field"]?.value as? String) ?? "any"
            guard let field = MusicIntegration.SearchField(rawValue: fieldRaw) else {
                return ("invalid field: \(fieldRaw) (use any, title, artist, or album)", true)
            }
            return report { try MusicIntegration.playQuery(query, field: field) }
        }
        // No target — resume whatever's cued.
        return transport("play")
    }

    private func transport(_ command: String) -> (String, Bool) {
        return report { try MusicIntegration.transport(command) }
    }

    /// Run a control that returns now-playing, and render the standard
    /// `{ok, state, track}` confirmation.
    private func report(_ body: () throws -> MusicIntegration.NowPlaying) -> (String, Bool) {
        let np: MusicIntegration.NowPlaying
        do {
            np = try body()
        } catch {
            return (errorText(error), true)
        }
        var response: [String: Any] = ["ok": true, "state": np.state]
        if let pos = np.position { response["position"] = pos }
        if let track = np.track { response["track"] = trackDict(track) }
        return (jsonString(response) ?? "{}", false)
    }

    private func volume(level: Int) -> (String, Bool) {
        do {
            let newLevel = try MusicIntegration.setVolume(level)
            return (jsonString(["ok": true, "volume": newLevel]) ?? "{}", false)
        } catch { return (errorText(error), true) }
    }

    private func shuffle(on: Bool) -> (String, Bool) {
        do {
            let result = try MusicIntegration.setShuffle(on)
            return (jsonString(["ok": true, "shuffle": result]) ?? "{}", false)
        } catch { return (errorText(error), true) }
    }

    private func repeatMode(_ mode: String) -> (String, Bool) {
        do {
            let result = try MusicIntegration.setRepeat(mode)
            return (jsonString(["ok": true, "repeat": result]) ?? "{}", false)
        } catch { return (errorText(error), true) }
    }

    private func onOff(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: return nil
        }
    }

    // MARK: - Actions

    private func nowPlaying() -> (String, Bool) {
        let np: MusicIntegration.NowPlaying
        do {
            np = try MusicIntegration.nowPlaying()
        } catch {
            return (errorText(error), true)
        }
        var response: [String: Any] = ["state": np.state]
        if let pos = np.position { response["position"] = pos }
        if let track = np.track { response["track"] = trackDict(track) }
        return (jsonString(response) ?? "{}", false)
    }

    private func search(query: String, field: MusicIntegration.SearchField, limit: Int) -> (String, Bool) {
        let tracks: [MusicIntegration.Track]
        do {
            tracks = try MusicIntegration.search(query: query, field: field, limit: limit)
        } catch {
            return (errorText(error), true)
        }
        let response: [String: Any] = [
            "count": tracks.count,
            "tracks": tracks.map { trackDict($0) },
        ]
        return (jsonString(response) ?? "{}", false)
    }

    private func stats(by: MusicIntegration.StatKind, limit: Int) -> (String, Bool) {
        let tracks: [MusicIntegration.Track]
        do {
            tracks = try MusicIntegration.stats(by: by, limit: limit)
        } catch {
            return (errorText(error), true)
        }
        let response: [String: Any] = [
            "by": by.rawValue,
            // Play stats are what this Mac recorded locally — NOT a true
            // cross-device Apple Music history (issue #55). Labeled so callers
            // don't overclaim.
            "source": "local",
            "count": tracks.count,
            "tracks": tracks.map { trackDict($0) },
        ]
        return (jsonString(response) ?? "{}", false)
    }

    private func mix(by: MusicIntegration.MixKind, limit: Int, months: Int, days: Int) -> (String, Bool) {
        let tracks: [MusicIntegration.Track]
        do {
            tracks = try MusicIntegration.mix(by: by, limit: limit, months: months, days: days)
        } catch {
            return (errorText(error), true)
        }
        let response: [String: Any] = [
            "by": by.rawValue,
            "source": "local",
            "count": tracks.count,
            "tracks": tracks.map { trackDict($0) },
        ]
        return (jsonString(response) ?? "{}", false)
    }

    // MARK: - Formatting

    private func trackDict(_ track: MusicIntegration.Track) -> [String: Any] {
        var dict: [String: Any] = [
            "name": track.name,
            "artist": track.artist,
            "album": track.album,
            "duration": track.duration,
            "played_count": track.playedCount,
            "rating": track.rating,
            "stars": track.rating / 20,
            "loved": track.loved,
            // "file track" / "shared track" / "URL track" — reveals whether it's
            // a local file, an undownloaded cloud track, or a pure stream.
            "kind": track.kind,
            "database_id": track.databaseID,
        ]
        // Present only when Music reports one — distinguishes streamed-in Apple
        // Music content ("subscription") from the user's own files.
        if let cloud = track.cloudStatus { dict["cloud_status"] = cloud }
        if let played = track.playedDate { dict["played_date"] = played }
        if let added = track.dateAdded { dict["date_added"] = added }
        return dict
    }

    private func intParam(_ params: [String: AnyCodable]?, _ key: String) -> Int? {
        if let i = params?[key]?.value as? Int { return i }
        if let d = params?[key]?.value as? Double { return Int(d) }
        if let s = params?[key]?.value as? String { return Int(s) }
        return nil
    }

    private func errorText(_ error: Error) -> String {
        if let musicError = error as? MusicIntegration.MusicError {
            return musicError.description
        }
        return "music error: \(error.localizedDescription)"
    }

    private func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
