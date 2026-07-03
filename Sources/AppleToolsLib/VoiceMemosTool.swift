import Foundation

/// LLM/CLI tool wrapper over `VoiceMemosIntegration`. Read-only: browse and
/// search recording metadata, and export the underlying `.m4a` audio.
///
/// Actions:
///   - list   — recent recordings (defaults to the last 30 days; `--all` for
///              the full history), newest first.
///   - search — filter the full history by title substring, folder, and/or
///              date range.
///   - export — copy a recording's `.m4a` into the output dir; returns its path.
public struct VoiceMemosTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "voicememos",
        description: "Read Apple Voice Memos (read-only). Actions: 'list' (recent recordings, last 30 days by default), 'search' (filter all recordings by title/folder/date), 'export' (copy a recording's .m4a audio into the local output dir; returns its path).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "list, search, or export"),
                "query": PropertySchema(type_: "string", description: "Title substring, case-insensitive (for search)"),
                "folder": PropertySchema(type_: "string", description: "Restrict to a named Voice Memos folder, case-insensitive (for list/search)"),
                "start_date": PropertySchema(type_: "string", description: "Only recordings on/after this date, ISO 8601 e.g. 2026-01-15 (for list/search)"),
                "end_date": PropertySchema(type_: "string", description: "Only recordings on/before this date, ISO 8601 (for list/search)"),
                "limit": PropertySchema(type_: "integer", description: "Max recordings to return (for list/search)"),
                "all": PropertySchema(type_: "boolean", description: "List the full history instead of just the last 30 days (for list, default false)"),
                "id": PropertySchema(type_: "string", description: "Recording id from list/search results (for export)"),
                "with_waveform": PropertySchema(type_: "boolean", description: "Also export the .waveform sidecar if present (for export, default false)"),
            ],
            required: ["action"]
        )
    )

    public let host: ToolHost

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "list":   .read,
        "search": .read,
        "export": .read,
    ])

    public init(host: ToolHost) {
        self.host = host
    }

    public func preflight() -> (ok: Bool, message: String) {
        return VoiceMemosIntegration.preflight()
    }

    /// Default browse window for `list` when the caller gives no date bounds
    /// and doesn't ask for `--all`: the last 30 days.
    private static let defaultWindowDays = 30

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "list":
            return listRecordings(params: params, isSearch: false)
        case "search":
            return listRecordings(params: params, isSearch: true)
        case "export":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let withWaveform = params?["with_waveform"]?.value as? Bool ?? false
            return export(id: id, withWaveform: withWaveform)
        default:
            return ("unknown action: \(action) (use list, search, or export)", true)
        }
    }

    // MARK: - List / search

    private func listRecordings(params: [String: AnyCodable]?, isSearch: Bool) -> (String, Bool) {
        let query = params?["query"]?.value as? String
        let folder = params?["folder"]?.value as? String
        let limit = params?["limit"]?.value as? Int
        let all = params?["all"]?.value as? Bool ?? false

        var start: Date?
        var end: Date?
        if let s = params?["start_date"]?.value as? String {
            guard let d = VoiceMemosIntegration.parseDate(s) else {
                return ("invalid start_date format (use ISO 8601, e.g. 2026-01-15 or 2026-01-15T09:00:00Z)", true)
            }
            start = d
        }
        if let e = params?["end_date"]?.value as? String {
            guard let d = VoiceMemosIntegration.parseEndDate(e) else {
                return ("invalid end_date format", true)
            }
            end = d
        }

        // `list` with no explicit bounds and no `--all` defaults to a recent
        // window so casual output stays short; `search` always spans the full
        // history (its filters are the scope).
        var windowApplied = false
        if !isSearch && !all && start == nil && end == nil {
            start = Calendar.current.date(byAdding: .day, value: -Self.defaultWindowDays, to: Date())
            windowApplied = true
        }

        guard let recordings = VoiceMemosIntegration.list(
            query: query, folder: folder, start: start, end: end, limit: limit
        ) else {
            return ("could not read the Voice Memos database (missing, unreadable, or unrecognized schema).", true)
        }

        var response: [String: Any] = [
            "count": recordings.count,
            "recordings": recordings.map(recordingMetadata),
        ]
        if windowApplied {
            response["window"] = "last_\(Self.defaultWindowDays)_days"
            response["note"] = "Showing the last \(Self.defaultWindowDays) days. Use all=true (or a date range) to see the full history."
        }
        return (jsonEncode(response), false)
    }

    // MARK: - Export

    private func export(id: String, withWaveform: Bool) -> (String, Bool) {
        guard let rec = VoiceMemosIntegration.find(id: id) else {
            return ("no recording found with id: \(id)", true)
        }
        guard rec.available else {
            return ("recording '\(rec.title)' is not downloaded locally (cloud-only/evicted). Open it in Voice Memos to download it first.", true)
        }
        guard let data = FileManager.default.contents(atPath: rec.audioPath) else {
            return ("failed to read audio file for recording '\(rec.title)' at \(rec.audioPath)", true)
        }

        let outName = exportFilename(for: rec)
        let result = host.fileSink.deliver(filename: outName, data: data)
        switch result {
        case .success(let ref):
            var response: [String: Any] = [
                ref.key: ref.value,
                "filename": outName,
                "title": rec.title,
                "date": DateFormatting.iso(rec.date),
                "duration_seconds": roundedDuration(rec.duration),
            ]
            if withWaveform {
                if let wfData = FileManager.default.contents(atPath: rec.waveformPath) {
                    let wfName = (outName as NSString).deletingPathExtension + ".waveform"
                    if case .success(let wfRef) = host.fileSink.deliver(filename: wfName, data: wfData) {
                        response["waveform_\(wfRef.key)"] = wfRef.value
                    }
                } else {
                    response["waveform_note"] = "no waveform sidecar for this recording"
                }
            }
            return (jsonEncode(response), false)
        case .failure(let error):
            return ("export failed: \(error)", true)
        }
    }

    /// Human-readable export name: `"<title> <YYYY-MM-DD>.m4a"`, with path- and
    /// title-unsafe characters folded to `-`. FileSink de-duplicates collisions.
    private func exportFilename(for rec: Recording) -> String {
        let date = DateFormatting.localDateOnly(rec.date)
        let safeTitle = sanitize(rec.title)
        let ext = (rec.filename as NSString).pathExtension
        let base = safeTitle.isEmpty ? "Recording" : safeTitle
        let stem = "\(base) \(date)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private func sanitize(_ s: String) -> String {
        var out = s
        for ch in ["/", ":", "\\", "\n", "\r", "\t"] {
            out = out.replacingOccurrences(of: ch, with: "-")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Formatting

    private typealias Recording = VoiceMemosIntegration.Recording

    private func recordingMetadata(_ rec: Recording) -> [String: Any] {
        var entry: [String: Any] = [
            "id": rec.id,
            "title": rec.title,
            "date": DateFormatting.iso(rec.date),
            "duration_seconds": roundedDuration(rec.duration),
            "available": rec.available,
        ]
        if let folder = rec.folder {
            entry["folder"] = folder
        }
        return entry
    }

    /// Whole seconds. Sub-second precision is meaningless for a voice memo, and
    /// an Int also sidesteps JSON float-noise (`2.6000000000000001`).
    private func roundedDuration(_ seconds: Double) -> Int {
        Int(seconds.rounded())
    }

    private func jsonEncode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
