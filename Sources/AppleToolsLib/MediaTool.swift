import Foundation

/// Read-only media-engagement tool: what you've recently listened to or read,
/// merged across Podcasts and Books (the sources with a local read path).
/// Reflects other-device activity where the source app syncs over iCloud —
/// notably podcasts listened to on a phone. See `MediaIntegration`.
public struct MediaTool: ProbeTool {
    private static let defaultHours = 24

    public let definition = ToolDefinition(
        name: "media",
        description: "See what media you've recently engaged with, newest first, merged across Apple Podcasts and Books. 'recent' returns everything played/opened in the last N hours (default 24) with resume position and progress. Reflects listening/reading from OTHER devices too, since Podcasts and Books sync over iCloud (e.g. podcasts played on your phone show up here). Read-only. Does not cover Music (use the 'music' tool) or TV/movies (no local data).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "recent"),
                "hours": PropertySchema(type_: "integer", description: "Look-back window in hours (default 24)",
                    summary: "Look-back window in hours (default 24)", actions: ["recent"]),
                "limit": PropertySchema(type_: "integer", description: "Max items (default: all in the window)",
                    summary: "Max items", actions: ["recent"]),
            ],
            required: ["action"]
        ),
        cliSummary: "See recently played/read media (podcasts + books), newest first.",
        actions: [
            ActionHelp(name: "recent", summary: "Media played or opened in the last N hours",
                example: "apple-tools media recent [--hours 24] [--limit N]"),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "recent": .read,
    ])

    public init() {}

    public func preflight() -> (ok: Bool, message: String) {
        return MediaIntegration.preflight()
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }
        switch action {
        case "recent":
            let hours = intParam(params, "hours") ?? Self.defaultHours
            guard hours > 0 else { return ("hours must be positive", true) }
            let limit = intParam(params, "limit")
            return recent(hours: hours, limit: limit)
        default:
            return ("unknown action: \(action) (use recent)", true)
        }
    }

    private func recent(hours: Int, limit: Int?) -> (String, Bool) {
        let items = MediaIntegration.recent(hours: hours, limit: limit)
        let response: [String: Any] = [
            "window_hours": hours,
            "count": items.count,
            "items": items.map { itemDict($0) },
        ]
        return (jsonString(response) ?? "{}", false)
    }

    private func itemDict(_ item: MediaIntegration.MediaItem) -> [String: Any] {
        var dict: [String: Any] = [
            "source": item.source,
            "title": item.title,
            "last_engaged": DateFormatting.iso(item.lastEngaged),
        ]
        if let creator = item.creator { dict["creator"] = creator }
        if let dur = item.durationSeconds { dict["duration_seconds"] = Int(dur.rounded()) }
        if let pct = item.percent { dict["percent"] = pct }
        return dict
    }

    private func intParam(_ params: [String: AnyCodable]?, _ key: String) -> Int? {
        if let i = params?[key]?.value as? Int { return i }
        if let d = params?[key]?.value as? Double { return Int(d) }
        if let s = params?[key]?.value as? String { return Int(s) }
        return nil
    }

    private func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
