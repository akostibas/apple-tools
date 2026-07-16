import Foundation

/// Read-only Apple Music / Music.app tool. Covers the zero-auth local surface:
/// what's playing, searching the local library, and local play-history stats.
/// Catalog search, playback control, and true cross-device history are out of
/// scope here (issue #55, #56).
public struct MusicTool: ProbeTool {
    private static let defaultSearchLimit = 25
    private static let defaultStatsLimit = 20

    public let definition = ToolDefinition(
        name: "music",
        description: "Read Apple Music / Music.app. Use 'now-playing' to see the current track and player state (works for streamed tracks too), 'search' to find tracks in the local library, 'stats' to rank the library by local play history (most-played, recently-played, most-loved). Read-only: play counts and dates reflect what THIS Mac recorded locally, not your full cross-device Apple Music listening history.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "now-playing, search, or stats"),
                "query": PropertySchema(type_: "string", description: "Text to match (required for search)",
                    summary: "Search text", actions: ["search"]),
                "field": PropertySchema(type_: "string", description: "Which field to match for search: any (default), title, artist, or album",
                    summary: "Match field: any (default), title, artist, album", actions: ["search"]),
                "by": PropertySchema(type_: "string", description: "Ranking for stats: most-played, recently-played, or most-loved (required for stats)",
                    summary: "Ranking: most-played, recently-played, most-loved", actions: ["stats"]),
                "limit": PropertySchema(type_: "integer", description: "Max results (search default 25, stats default 20)",
                    summary: "Max results", actions: ["search", "stats"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Read Apple Music — now playing, search the library, and local play stats.",
        actions: [
            ActionHelp(name: "now-playing", summary: "Show the current track and player state",
                example: "apple-tools music now-playing"),
            ActionHelp(name: "search", summary: "Find tracks in the local library",
                example: "apple-tools music search --query <text> [--field any|title|artist|album] [--limit N]", required: ["query"]),
            ActionHelp(name: "stats", summary: "Rank the library by local play history",
                example: "apple-tools music stats --by most-played|recently-played|most-loved [--limit N]", required: ["by"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "now-playing": .read,
        "search":      .read,
        "stats":       .read,
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
        default:
            return ("unknown action: \(action) (use now-playing, search, or stats)", true)
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
