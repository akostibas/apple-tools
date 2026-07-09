import Foundation
import UniformTypeIdentifiers

/// A named directory the documents tool may search and browse. All tool
/// paths are namespaced by root name (`<name>/<relative-path>`), so names
/// must be unique and must not contain "/".
public struct DocumentRoot {
    public let name: String
    /// Absolute, standardized path (tilde expanded at init).
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// The default root every configuration includes unless overridden.
    public static let documents = DocumentRoot(name: "Documents", path: NSHomeDirectory() + "/Documents")

    /// Home-relative rendering for help text ("~/Documents").
    var displayPath: String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

public struct DocumentsTool: ProbeTool {
    // The probe config is injected so we can derive the upload URL and API key.
    public let host: ToolHost

    /// Ordered search/browse roots. Tool paths are namespaced by root name.
    public let roots: [DocumentRoot]

    public var definition: ToolDefinition {
        let rootList = roots.map { "'\($0.name)' (\($0.displayPath))" }.joined(separator: ", ")
        let names = roots.map(\.name).joined(separator: ", ")
        return ToolDefinition(
            name: "documents",
            description: "Access the user's documents. Searchable roots: \(rootList). All paths are prefixed with their root name (e.g. '\(roots[0].name)/report.pdf'). Actions: 'search' (Spotlight query across all roots), 'list' (directory listing; omit path to list the roots), 'info' (file metadata), 'fetch' (copy a file into the local output dir; returns its path).",
            parameters: ParameterSchema(
                type_: "object",
                properties: [
                    "action": PropertySchema(type_: "string", description: "search, list, info, or fetch"),
                    "query": PropertySchema(type_: "string", description: "Spotlight search query (for search)",
                        summary: "Spotlight search query", actions: ["search"]),
                    "path": PropertySchema(type_: "string", description: "Path in the form '<root>/<relative-path>', where <root> is one of: \(names) (for list, info, fetch). For list, omit to list the roots.",
                        summary: "Path as '<root>/<relative>' (roots: \(names)); omit for list to list the roots", actions: ["list", "info", "fetch"]),
                    "offset": PropertySchema(type_: "integer", description: "Number of results to skip (for search/list, default 0)",
                        summary: "Number of results to skip (default 0)", actions: ["search", "list"]),
                    "limit": PropertySchema(type_: "integer", description: "Max results to return (for search/list, default 20, max 50)",
                        summary: "Max results (default 20, max 50)", actions: ["search", "list"]),
                ],
                required: ["action"]
            ),
            cliSummary: "Search and browse the user's documents (roots: \(rootList)).",
            actions: [
                ActionHelp(name: "search", summary: "Spotlight search across all roots",
                    example: "apple-tools documents search --query <text> [--offset <n>] [--limit <n>]", required: ["query"]),
                ActionHelp(name: "list", summary: "List a directory (omit --path to list the roots)",
                    example: "apple-tools documents list [--path <root>/<dir>] [--offset <n>] [--limit <n>]"),
                ActionHelp(name: "info", summary: "Show file metadata",
                    example: "apple-tools documents info --path <root>/<file>", required: ["path"]),
                ActionHelp(name: "fetch", summary: "Copy a file into the output dir; returns its path",
                    example: "apple-tools documents fetch --path <root>/<file>", required: ["path"]),
            ]
        )
    }

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "search": .read,
        "list":   .read,
        "info":   .read,
        "fetch":  .read,
    ])

    public init(host: ToolHost, roots: [DocumentRoot] = [.documents]) {
        self.host = host
        // A tool with zero roots would make every action an error; fall back
        // to the default rather than constructing a useless instance.
        self.roots = roots.isEmpty ? [.documents] : roots
    }

    // MARK: - Path resolution

    private struct PathError: Error {
        let message: String
    }

    /// Splits a namespaced tool path ("<root>/<relative>") into its root and
    /// the resolved absolute path, enforcing the per-root jail. The relative
    /// part may be empty (the path names the root itself).
    private func resolve(_ toolPath: String) -> Result<(root: DocumentRoot, resolved: String), PathError> {
        let components = toolPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let rootName = String(components[0])
        guard let root = roots.first(where: { $0.name == rootName }) else {
            let names = roots.map(\.name).joined(separator: ", ")
            return .failure(PathError(message: "unknown root '\(rootName)' (valid roots: \(names))"))
        }
        let relative = components.count > 1 ? String(components[1]) : ""
        let fullPath = relative.isEmpty ? root.path : (root.path as NSString).appendingPathComponent(relative)
        let resolved = (fullPath as NSString).standardizingPath
        // Require the trailing "/" so sibling dirs sharing the root's name
        // as a prefix (e.g. "~/Documents Backup") are rejected.
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
            return .failure(PathError(message: "path escapes root '\(root.name)': \(toolPath)"))
        }
        return .success((root, resolved))
    }

    /// Maps an absolute path (e.g. an mdfind hit) back to its namespaced tool
    /// path, using the longest matching root so nested roots resolve to the
    /// most specific one. Returns nil when the path is under no root.
    func toolPath(forAbsolutePath fullPath: String) -> String? {
        let match = roots
            .filter { fullPath == $0.path || fullPath.hasPrefix($0.path + "/") }
            .max(by: { $0.path.count < $1.path.count })
        guard let root = match else { return nil }
        if fullPath == root.path { return root.name }
        return root.name + "/" + fullPath.dropFirst(root.path.count + 1)
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "search":
            guard let query = params?["query"]?.value as? String, !query.isEmpty else {
                return ("missing required parameter: query", true)
            }
            let offset = (params?["offset"]?.value as? Int) ?? 0
            let limit = min((params?["limit"]?.value as? Int) ?? 20, 50)
            return search(query: query, offset: offset, limit: limit)
        case "list":
            let path = (params?["path"]?.value as? String) ?? ""
            let offset = (params?["offset"]?.value as? Int) ?? 0
            let limit = min((params?["limit"]?.value as? Int) ?? 20, 50)
            return list(toolPath: path, offset: offset, limit: limit)
        case "info":
            guard let path = params?["path"]?.value as? String, !path.isEmpty else {
                return ("missing required parameter: path", true)
            }
            return info(toolPath: path)
        case "fetch":
            guard let path = params?["path"]?.value as? String, !path.isEmpty else {
                return ("missing required parameter: path", true)
            }
            return fetch(toolPath: path)
        default:
            return ("unknown action: \(action) (use search, list, info, or fetch)", true)
        }
    }

    // MARK: - Search

    private func search(query: String, offset: Int, limit: Int) -> (String, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // mdfind unions repeated -onlyin scopes.
        process.arguments = roots.flatMap { ["-onlyin", $0.path] } + [query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ("mdfind failed: \(error.localizedDescription)", true)
        }

        // Read pipe BEFORE waitUntilExit to avoid deadlock when the pipe
        // buffer fills (mdfind blocks on write, waitUntilExit blocks on exit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return ("failed to read mdfind output", true)
        }

        let allHits = output.split(separator: "\n").map(String.init)
            .compactMap { full in toolPath(forAbsolutePath: full).map { (full: full, tool: $0) } }
        let total = allHits.count
        let page = Array(allHits.dropFirst(offset).prefix(limit))

        var results: [[String: Any]] = []
        let fm = FileManager.default
        for hit in page {
            var entry: [String: Any] = ["path": hit.tool]

            if let attrs = try? fm.attributesOfItem(atPath: hit.full) {
                if let size = attrs[.size] as? Int {
                    entry["size"] = size
                }
                if let modified = attrs[.modificationDate] as? Date {
                    entry["modified"] = DateFormatting.iso(modified)
                }
            }
            results.append(entry)
        }

        let response: [String: Any] = [
            "total": total,
            "offset": offset,
            "limit": limit,
            "results": results,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: response),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ("failed to serialize results", true)
        }
        return (jsonStr, false)
    }

    // MARK: - List

    /// With an empty path, lists the configured roots as directory entries.
    private func listRoots(offset: Int, limit: Int) -> (String, Bool) {
        let fm = FileManager.default
        let total = roots.count
        let page = Array(roots.dropFirst(offset).prefix(limit))

        var results: [[String: Any]] = []
        for root in page {
            var entry: [String: Any] = ["name": root.name, "type": "directory"]
            if let attrs = try? fm.attributesOfItem(atPath: root.path),
               let modified = attrs[.modificationDate] as? Date {
                entry["modified"] = DateFormatting.iso(modified)
            }
            results.append(entry)
        }

        let response: [String: Any] = [
            "path": ".",
            "total": total,
            "offset": offset,
            "limit": limit,
            "results": results,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: response),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ("failed to serialize results", true)
        }
        return (jsonStr, false)
    }

    private func list(toolPath: String, offset: Int, limit: Int) -> (String, Bool) {
        if toolPath.isEmpty {
            return listRoots(offset: offset, limit: limit)
        }
        let resolved: String
        switch resolve(toolPath) {
        case .failure(let error): return (error.message, true)
        case .success(let hit): resolved = hit.resolved
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return ("not a directory: \(toolPath)", true)
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: resolved) else {
            return ("failed to list directory: \(toolPath)", true)
        }

        // Sort entries alphabetically, directories first.
        let sorted = contents.sorted { a, b in
            let aPath = (resolved as NSString).appendingPathComponent(a)
            let bPath = (resolved as NSString).appendingPathComponent(b)
            var aIsDir: ObjCBool = false
            var bIsDir: ObjCBool = false
            fm.fileExists(atPath: aPath, isDirectory: &aIsDir)
            fm.fileExists(atPath: bPath, isDirectory: &bIsDir)
            if aIsDir.boolValue != bIsDir.boolValue {
                return aIsDir.boolValue
            }
            return a.localizedStandardCompare(b) == .orderedAscending
        }

        let total = sorted.count
        let page = Array(sorted.dropFirst(offset).prefix(limit))

        var results: [[String: Any]] = []
        for name in page {
            let entryPath = (resolved as NSString).appendingPathComponent(name)
            var entry: [String: Any] = ["name": name]

            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: entryPath, isDirectory: &entryIsDir)
            entry["type"] = entryIsDir.boolValue ? "directory" : "file"

            if let attrs = try? fm.attributesOfItem(atPath: entryPath) {
                if let size = attrs[.size] as? Int {
                    entry["size"] = size
                }
                if let modified = attrs[.modificationDate] as? Date {
                    entry["modified"] = DateFormatting.iso(modified)
                }
            }
            results.append(entry)
        }

        let response: [String: Any] = [
            "path": toolPath,
            "total": total,
            "offset": offset,
            "limit": limit,
            "results": results,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: response),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ("failed to serialize results", true)
        }
        return (jsonStr, false)
    }

    // MARK: - Info

    private func info(toolPath: String) -> (String, Bool) {
        let resolved: String
        switch resolve(toolPath) {
        case .failure(let error): return (error.message, true)
        case .success(let hit): resolved = hit.resolved
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
            return ("not found: \(toolPath)", true)
        }

        var response: [String: Any] = [
            "name": (resolved as NSString).lastPathComponent,
            "path": toolPath,
            "type": isDir.boolValue ? "directory" : "file",
        ]

        if let attrs = try? fm.attributesOfItem(atPath: resolved) {
            if let size = attrs[.size] as? Int {
                response["size"] = size
            }
            if let created = attrs[.creationDate] as? Date {
                response["created"] = DateFormatting.iso(created)
            }
            if let modified = attrs[.modificationDate] as? Date {
                response["modified"] = DateFormatting.iso(modified)
            }
        }

        if !isDir.boolValue {
            let ext = (resolved as NSString).pathExtension
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                response["content_type"] = utType.preferredMIMEType ?? "application/octet-stream"
            }
        }

        guard let json = try? JSONSerialization.data(withJSONObject: response),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return ("failed to serialize result", true)
        }
        return (jsonStr, false)
    }

    // MARK: - Fetch

    private func fetch(toolPath: String) -> (String, Bool) {
        let resolved: String
        switch resolve(toolPath) {
        case .failure(let error): return (error.message, true)
        case .success(let hit): resolved = hit.resolved
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            return ("file not found: \(toolPath)", true)
        }

        guard let fileData = fm.contents(atPath: resolved) else {
            return ("failed to read file: \(toolPath)", true)
        }

        let filename = (resolved as NSString).lastPathComponent

        let result = host.fileSink.deliver(filename: filename, data: fileData)
        switch result {
        case .success(let ref):
            let response: [String: String] = [
                ref.key: ref.value,
                "filename": filename,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: response),
                  let jsonStr = String(data: json, encoding: .utf8) else {
                return ("uploaded but failed to serialize response", true)
            }
            return (jsonStr, false)
        case .failure(let error):
            return ("upload failed: \(error)", true)
        }
    }
}
