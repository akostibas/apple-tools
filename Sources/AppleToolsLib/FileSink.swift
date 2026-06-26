import Foundation

/// A reference to a delivered file, as it should appear in a tool's JSON
/// result. `key` is the JSON field name the tool emits and `value` is the
/// reference itself — this lets each host control both halves of the contract
/// without the shared tools hardcoding either. The local CLI emits
/// `{"path": "/abs/path"}`; a server-backed host emits `{"file_id": "abc"}`.
public struct FileReference {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Abstraction over "where does a file a tool produces go?".
///
/// In this standalone CLI the answer is "a local directory" (`LocalFileSink`),
/// and `deliver` returns a `path` reference Claude can then Read. The same
/// protocol lets a server-backed host (e.g. a server-backed probe) inject an
/// uploader whose `deliver` returns a `file_id` reference instead — which is
/// why the tools depend on `FileSink` rather than any concrete storage.
public protocol FileSink {
    /// Persist `data` under `filename` and return a `FileReference` carrying
    /// both the JSON key and value the tool should emit (a `path` here; a
    /// `file_id` in a server-backed sink).
    func deliver(filename: String, data: Data) -> Result<FileReference, FileSinkError>
}

public enum FileSinkError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let s): return s }
    }
}

/// Writes produced files into a local output directory and returns their
/// absolute paths. Output dir resolution: `$APPLE_TOOLS_OUTPUT_DIR` if set,
/// otherwise the per-user temp directory (`NSTemporaryDirectory()`), which on
/// macOS is `/var/folders/…/T/` — owned by and confined to the current user.
public struct LocalFileSink: FileSink {
    public let outputDir: String

    public init(outputDir: String? = nil) {
        if let outputDir = outputDir {
            self.outputDir = outputDir
        } else if let env = ProcessInfo.processInfo.environment["APPLE_TOOLS_OUTPUT_DIR"], !env.isEmpty {
            self.outputDir = env
        } else {
            self.outputDir = NSTemporaryDirectory() + "apple-tools"
        }
    }

    public func deliver(filename: String, data: Data) -> Result<FileReference, FileSinkError> {
        let fm = FileManager.default
        do {
            // 0700 so the dir (and thus the files we drop in it) is owner-only,
            // even if APPLE_TOOLS_OUTPUT_DIR points somewhere world-traversable.
            try fm.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failure(.message("failed to create output dir \(outputDir): \(error.localizedDescription)"))
        }

        // Sanitize to a bare filename, then avoid clobbering existing files.
        let base = (filename as NSString).lastPathComponent
        let safe = base.isEmpty ? "file" : base
        let dest = uniquePath(in: outputDir, filename: safe)

        do {
            try data.write(to: URL(fileURLWithPath: dest))
        } catch {
            return .failure(.message("failed to write \(dest): \(error.localizedDescription)"))
        }
        return .success(FileReference(key: "path", value: dest))
    }

    private func uniquePath(in dir: String, filename: String) -> String {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: dir)
        var candidate = dirURL.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate.path }

        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var n = 1
        repeat {
            let next = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            candidate = dirURL.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate.path
    }
}
