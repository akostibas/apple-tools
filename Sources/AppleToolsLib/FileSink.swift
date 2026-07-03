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
            // 0700 on creation so the dir (and thus the files we drop in it) is
            // owner-only, even if APPLE_TOOLS_OUTPUT_DIR points somewhere
            // world-traversable.
            try fm.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failure(.message("failed to create output dir \(outputDir): \(error.localizedDescription)"))
        }

        // `createDirectory(attributes:)` only applies the mode to dirs it
        // actually creates; a pre-existing (e.g. 0755/1777) output dir keeps its
        // looser mode. Tighten to 0700 unconditionally so the documented
        // owner-only guarantee holds for the configured dir too. Best-effort: if
        // we don't own it we can't chmod it, but then it was never ours.
        _ = chmod(outputDir, 0o700)

        // Sanitize to a bare filename.
        let base = (filename as NSString).lastPathComponent
        let safe = base.isEmpty ? "file" : base

        // Atomically create a brand-new, owner-only regular file. `O_CREAT|O_EXCL`
        // never follows a symlink at the final component (POSIX: fails EEXIST),
        // which closes the planted-symlink arbitrary-write hole, and makes the
        // uniqueness check race-free (no check-then-write TOCTOU) — a concurrent
        // creator of the same name loses the exclusive create and we move on.
        guard let created = exclusiveCreate(in: outputDir, filename: safe) else {
            return .failure(.message("failed to create a unique output file in \(outputDir)"))
        }
        let (fd, dest) = created

        if !writeAll(fd: fd, data: data) {
            close(fd)
            unlink(dest)
            return .failure(.message("failed to write \(dest)"))
        }
        close(fd)
        return .success(FileReference(key: "path", value: dest))
    }

    /// Exclusively create the next non-colliding filename (`name`, `name-1`, …)
    /// as a fresh 0600 regular file. Returns the open fd and path, or nil if no
    /// slot could be created (collision storm or an unrecoverable open error).
    private func exclusiveCreate(in dir: String, filename: String) -> (fd: Int32, path: String)? {
        let dirURL = URL(fileURLWithPath: dir)
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension

        var n = 0
        while n < 10_000 {
            let name: String
            if n == 0 {
                name = filename
            } else {
                name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            }
            let path = dirURL.appendingPathComponent(name).path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                // Enforce 0600 exactly (open mode is masked by umask).
                _ = fchmod(fd, 0o600)
                return (fd, path)
            }
            if errno == EEXIST {
                n += 1
                continue
            }
            return nil
        }
        return nil
    }

    /// Write the full buffer to `fd`, retrying short writes and EINTR.
    private func writeAll(fd: Int32, data: Data) -> Bool {
        if data.isEmpty { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base.advanced(by: offset), total - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}
