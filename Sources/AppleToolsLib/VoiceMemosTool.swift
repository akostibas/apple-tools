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
        description: "Read Apple Voice Memos (read-only). Actions: 'list' (recent recordings, last 30 days by default), 'search' (filter all recordings by title/folder/date), 'export' (copy a recording's .m4a audio into the local output dir; returns its path), 'transcribe' (on-device transcript of a recording; writes a .txt to the output dir and returns its path plus a preview; cached per recording; macOS 26+).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "list, search, export, or transcribe"),
                "query": PropertySchema(type_: "string", description: "Title substring, case-insensitive (for search)"),
                "folder": PropertySchema(type_: "string", description: "Restrict to a named Voice Memos folder, case-insensitive (for list/search)"),
                "start_date": PropertySchema(type_: "string", description: "Only recordings on/after this date, ISO 8601 e.g. 2026-01-15 (for list/search)"),
                "end_date": PropertySchema(type_: "string", description: "Only recordings on/before this date, ISO 8601 (for list/search)"),
                "limit": PropertySchema(type_: "integer", description: "Max recordings to return (for list/search)"),
                "all": PropertySchema(type_: "boolean", description: "List the full history instead of just the last 30 days (for list, default false)"),
                "id": PropertySchema(type_: "string", description: "Recording id from list/search results (for export/transcribe)"),
                "with_waveform": PropertySchema(type_: "boolean", description: "Also export the .waveform sidecar if present (for export, default false)"),
                "locale": PropertySchema(type_: "string", description: "BCP-47 locale for the speech model, e.g. en-US (for transcribe, default en-US)"),
                "refresh": PropertySchema(type_: "boolean", description: "Bypass the transcript cache and re-transcribe (for transcribe, default false)"),
                "timestamps": PropertySchema(type_: "boolean", description: "Also write a .json sidecar of per-segment {start,end,text} time ranges (for transcribe, default false)"),
                "inline": PropertySchema(type_: "boolean", description: "Return the full transcript text in the response instead of only a preview; for short memos or piping (for transcribe, default false)"),
            ],
            required: ["action"]
        )
    )

    public let host: ToolHost

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "list":       .read,
        "search":     .read,
        "export":     .read,
        // Reads audio + writes only our own derived transcript cache, never any
        // Apple-owned data — classified read.
        "transcribe": .read,
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
        case "transcribe":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let locale = (params?["locale"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "en-US"
            let refresh = params?["refresh"]?.value as? Bool ?? false
            let timestamps = params?["timestamps"]?.value as? Bool ?? false
            let inline = params?["inline"]?.value as? Bool ?? false
            return transcribe(id: id, locale: locale, refresh: refresh, timestamps: timestamps, inline: inline)
        default:
            return ("unknown action: \(action) (use list, search, export, or transcribe)", true)
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

    // MARK: - Transcribe

    private func transcribe(id: String, locale: String, refresh: Bool, timestamps: Bool, inline: Bool) -> (String, Bool) {
        guard let rec = VoiceMemosIntegration.find(id: id) else {
            return ("no recording found with id: \(id)", true)
        }
        guard rec.available else {
            return ("recording '\(rec.title)' is not downloaded locally (cloud-only/evicted). Open it in Voice Memos to download it first.", true)
        }

        let digestHex = rec.digestHex

        // Cache hit? (Validated by audio digest + locale.)
        if !refresh, let cached = VoiceMemosTranscriptCache.read(id: id, digestHex: digestHex, locale: locale) {
            let segs = cached.segments.map { (start: $0.start, end: $0.end, text: $0.text) }
            return transcriptResponse(rec: rec, locale: locale, text: cached.text,
                                      segments: segs, cached: true, timestamps: timestamps, inline: inline)
        }

        // Cold path: transcribe on-device. Requires macOS 26+.
        guard #available(macOS 26.0, *) else {
            return ("voicememos transcribe requires macOS 26 or later (on-device SpeechTranscriber). This system is older.", true)
        }
        guard VoiceMemosTranscriber.isAvailable else {
            return ("on-device speech transcription is unavailable on this system.", true)
        }

        // Bridge the async transcriber into the synchronous tool contract. The
        // wait blocks a background/global-queue thread (see main.swift), while
        // the transcription runs on the Swift concurrency pool — no deadlock.
        let url = URL(fileURLWithPath: rec.audioPath)
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<VoiceMemosTranscriber.Transcript, Error>?
        Task {
            do { outcome = .success(try await VoiceMemosTranscriber.transcribe(url: url, localeIdentifier: locale)) }
            catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()

        switch outcome! {
        case .failure(let error):
            return ("transcription failed: \(error)", true)
        case .success(let transcript):
            // Persist to cache for instant repeat calls.
            let entry = VoiceMemosTranscriptCache.Entry(
                id: id,
                digestHex: digestHex,
                locale: locale,
                text: transcript.text,
                segments: transcript.segments.map { .init(start: $0.start, end: $0.end, text: $0.text) },
                transcribedAt: Date()
            )
            VoiceMemosTranscriptCache.write(entry)

            let segs = transcript.segments.map { (start: $0.start, end: $0.end, text: $0.text) }
            return transcriptResponse(rec: rec, locale: locale, text: transcript.text,
                                      segments: segs, cached: false, timestamps: timestamps, inline: inline)
        }
    }

    /// Characters of transcript to inline as a preview when the full text is
    /// written to a file. Enough to identify the memo without flooding context.
    private static let previewChars = 280

    /// Build the transcribe JSON response (shared by cache-hit and fresh paths).
    ///
    /// The transcript is written to a `.txt` in the output dir by default and
    /// only a preview comes back inline — a long memo is tens of KB and has no
    /// business landing in an agent's context on every call. `--inline` forces
    /// the full text back; `--timestamps` also writes a `.json` segment sidecar.
    private func transcriptResponse(rec: Recording, locale: String, text: String,
                                    segments: [(start: Double, end: Double, text: String)],
                                    cached: Bool, timestamps: Bool, inline: Bool) -> (String, Bool) {
        let preview = String(text.prefix(Self.previewChars))
        var response: [String: Any] = [
            "id": rec.id,
            "title": rec.title,
            "date": DateFormatting.iso(rec.date),
            "duration_seconds": roundedDuration(rec.duration),
            "locale": locale,
            "cached": cached,
            "word_count": text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count,
            "char_count": text.count,
            "preview": preview,
            "preview_truncated": text.count > preview.count,
        ]

        // Write the full transcript to a .txt and return its path (default).
        let base = "\(sanitize(rec.title)) \(DateFormatting.localDateOnly(rec.date))"
        switch host.fileSink.deliver(filename: "\(base).txt", data: Data(text.utf8)) {
        case .success(let ref):
            response[ref.key] = ref.value
        case .failure(let error):
            // Files are the whole point, but don't strand the caller — fall
            // back to inlining the text so the transcript isn't lost.
            response["save_error"] = "\(error)"
            response["text"] = text
        }

        // Escape hatch: caller explicitly wants the full text in the response.
        if inline {
            response["text"] = text
        }

        if timestamps {
            let segObjects: [[String: Any]] = segments.map { seg in
                [
                    "start": (seg.start * 100).rounded() / 100,
                    "end": (seg.end * 100).rounded() / 100,
                    "text": seg.text,
                ]
            }
            switch host.fileSink.deliver(filename: "\(base).segments.json",
                                         data: Data(jsonEncode(segObjects).utf8)) {
            case .success(let ref):
                response["segments_\(ref.key)"] = ref.value
            case .failure(let error):
                response["segments_error"] = "\(error)"
            }
            if inline {
                response["segments"] = segObjects
            }
        }

        return (jsonEncode(response), false)
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
