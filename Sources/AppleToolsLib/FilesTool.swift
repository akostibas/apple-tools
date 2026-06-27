import Foundation
import UniformTypeIdentifiers

public struct FilesTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "files",
        description: "Access files in ~/Documents. Actions: 'search' (Spotlight query), 'list' (directory listing), 'info' (file metadata), 'fetch' (copy a file into the local output dir; returns its path).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "search, list, info, or fetch"),
                "query": PropertySchema(type_: "string", description: "Spotlight search query (for search)"),
                "path": PropertySchema(type_: "string", description: "Relative path within ~/Documents (for list, info, fetch). For list, defaults to root."),
                "offset": PropertySchema(type_: "integer", description: "Number of results to skip (for search/list, default 0)"),
                "limit": PropertySchema(type_: "integer", description: "Max results to return (for search/list, default 20, max 50)"),
            ],
            required: ["action"]
        )
    )

    // The probe config is injected so we can derive the upload URL and API key.
    public let host: ToolHost

    private let documentsDir = NSHomeDirectory() + "/Documents"

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "search": .read,
        "list":   .read,
        "info":   .read,
        "fetch":  .read,
    ])

    public init(host: ToolHost) {
        self.host = host
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
            return list(relativePath: path, offset: offset, limit: limit)
        case "info":
            guard let path = params?["path"]?.value as? String, !path.isEmpty else {
                return ("missing required parameter: path", true)
            }
            return info(relativePath: path)
        case "fetch":
            guard let path = params?["path"]?.value as? String, !path.isEmpty else {
                return ("missing required parameter: path", true)
            }
            return fetch(relativePath: path)
        default:
            return ("unknown action: \(action) (use search, list, info, or fetch)", true)
        }
    }

    // MARK: - Search

    private func search(query: String, offset: Int, limit: Int) -> (String, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", documentsDir, query]

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

        let allPaths = output.split(separator: "\n").map(String.init)
        let total = allPaths.count
        let page = Array(allPaths.dropFirst(offset).prefix(limit))

        var results: [[String: Any]] = []
        let fm = FileManager.default
        for fullPath in page {
            let relativePath = String(fullPath.dropFirst(documentsDir.count + 1))
            var entry: [String: Any] = ["path": relativePath]

            if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
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

    private func list(relativePath: String, offset: Int, limit: Int) -> (String, Bool) {
        let fullPath: String
        if relativePath.isEmpty {
            fullPath = documentsDir
        } else {
            fullPath = (documentsDir as NSString).appendingPathComponent(relativePath)
        }
        let resolved = (fullPath as NSString).standardizingPath
        guard resolved.hasPrefix(documentsDir) else {
            return ("path escapes ~/Documents: \(relativePath)", true)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return ("not a directory: \(relativePath)", true)
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: resolved) else {
            return ("failed to list directory: \(relativePath)", true)
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
            "path": relativePath.isEmpty ? "." : relativePath,
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

    private func info(relativePath: String) -> (String, Bool) {
        let fullPath = (documentsDir as NSString).appendingPathComponent(relativePath)
        let resolved = (fullPath as NSString).standardizingPath
        guard resolved.hasPrefix(documentsDir) else {
            return ("path escapes ~/Documents: \(relativePath)", true)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
            return ("not found: \(relativePath)", true)
        }

        var response: [String: Any] = [
            "name": (resolved as NSString).lastPathComponent,
            "path": relativePath,
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

    private func fetch(relativePath: String) -> (String, Bool) {
        // Resolve and validate the path stays within ~/Documents.
        let fullPath = (documentsDir as NSString).appendingPathComponent(relativePath)
        let resolved = (fullPath as NSString).standardizingPath
        guard resolved.hasPrefix(documentsDir) else {
            return ("path escapes ~/Documents: \(relativePath)", true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            return ("file not found: \(relativePath)", true)
        }

        guard let fileData = fm.contents(atPath: resolved) else {
            return ("failed to read file: \(relativePath)", true)
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
