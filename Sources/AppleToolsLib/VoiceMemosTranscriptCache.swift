import Foundation

/// On-disk cache of Voice Memo transcripts, so transcription cost is paid once
/// per recording. Stored under our OWN Application Support dir — never the
/// Voice Memos store.
///
/// Validity is content-based: an entry is keyed by the recording's `ZUNIQUEID`
/// and carries the `ZAUDIODIGEST` (hex) and locale it was produced from. On
/// read, the caller supplies the current digest + locale; a mismatch (the memo
/// was trimmed/re-recorded, or a different language was requested) misses the
/// cache and forces re-transcription. This is more robust than mtime/size.
public enum VoiceMemosTranscriptCache {

    /// A cached transcript plus the metadata proving it's still valid.
    public struct Entry: Codable {
        public let id: String
        public let digestHex: String?
        public let locale: String
        public let text: String
        public let segments: [Segment]
        public let transcribedAt: Date

        public struct Segment: Codable {
            public let start: Double
            public let end: Double
            public let text: String
            public init(start: Double, end: Double, text: String) {
                self.start = start; self.end = end; self.text = text
            }
        }

        public init(id: String, digestHex: String?, locale: String, text: String,
                    segments: [Segment], transcribedAt: Date) {
            self.id = id
            self.digestHex = digestHex
            self.locale = locale
            self.text = text
            self.segments = segments
            self.transcribedAt = transcribedAt
        }
    }

    /// Cache directory. Overridable for tests via `APPLE_TOOLS_CACHE_DIR`.
    public static var cacheDir: String {
        if let env = ProcessInfo.processInfo.environment["APPLE_TOOLS_CACHE_DIR"], !env.isEmpty {
            return "\(env)/transcripts"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/apple-tools/transcripts"
    }

    private static func path(for id: String) -> String {
        // ZUNIQUEID is a UUID — safe as a filename, but sanitize defensively.
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return "\(cacheDir)/\(safe).json"
    }

    /// Return the cached transcript for `id` iff it matches `digestHex` and
    /// `locale`. Returns nil on any mismatch, absence, or read/decode failure.
    public static func read(id: String, digestHex: String?, locale: String) -> Entry? {
        guard let data = FileManager.default.contents(atPath: path(for: id)),
              let entry = try? JSONDecoder.cacheDecoder.decode(Entry.self, from: data) else {
            return nil
        }
        guard entry.locale == locale, entry.digestHex == digestHex else { return nil }
        return entry
    }

    /// Persist `entry`. Best-effort: returns false if the write fails (caller
    /// still has the fresh transcript in hand, so a cache-write failure is not
    /// fatal).
    @discardableResult
    public static func write(_ entry: Entry) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        guard let data = try? JSONEncoder.cacheEncoder.encode(entry) else { return false }
        return fm.createFile(atPath: path(for: entry.id), contents: data,
                             attributes: [.posixPermissions: 0o600])
    }
}

private extension JSONEncoder {
    static var cacheEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var cacheDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
