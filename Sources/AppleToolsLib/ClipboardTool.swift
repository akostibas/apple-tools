import AppKit
import Foundation
import UniformTypeIdentifiers

public struct ClipboardTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "clipboard",
        description: "Access the macOS clipboard. Actions: 'read' (get current contents), 'write' (set text contents).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "read or write"),
                "text": PropertySchema(type_: "string", description: "Text to write to clipboard (for write)"),
            ],
            required: ["action"]
        )
    )

    public let fileSink: FileSink

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "read":  .read,
        "write": .readWrite,
    ])

    public init(fileSink: FileSink) {
        self.fileSink = fileSink
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "read":
            return read()
        case "write":
            guard let text = params?["text"]?.value as? String else {
                return ("missing required parameter: text", true)
            }
            return write(text: text)
        default:
            return ("unknown action: \(action) (use read or write)", true)
        }
    }

    // MARK: - Read

    private func read() -> (String, Bool) {
        let pasteboard = NSPasteboard.general

        guard let types = pasteboard.types, !types.isEmpty else {
            return (jsonEncode(["type": "empty"]), false)
        }

        // Check for file URLs first (files copied in Finder).
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            let files: [[String: String]] = urls.map { url in
                var entry: [String: String] = ["path": url.path]
                if let utType = UTType(filenameExtension: url.pathExtension) {
                    entry["content_type"] = utType.preferredMIMEType ?? "application/octet-stream"
                }
                return entry
            }
            let response: [String: Any] = [
                "type": "files",
                "count": files.count,
                "files": files,
            ]
            return (jsonEncode(response), false)
        }

        // Check for image data (screenshots, copied images).
        if let imageData = imageDataFromPasteboard(pasteboard) {
            let filename = "clipboard-\(ISO8601DateFormatter().string(from: Date())).png"
            let result = fileSink.deliver(filename: filename, data: imageData)
            switch result {
            case .success(let path):
                let response: [String: Any] = [
                    "type": "image",
                    "path": path,
                    "filename": filename,
                ]
                return (jsonEncode(response), false)
            case .failure(let error):
                return ("clipboard contains an image but upload failed: \(error)", true)
            }
        }

        // Fall back to plain text.
        if let text = pasteboard.string(forType: .string) {
            // Detect if the text looks like a URL.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isURL = types.contains(.URL) || (URL(string: trimmed)?.scheme?.hasPrefix("http") == true)

            var response: [String: Any] = [
                "type": isURL ? "url" : "text",
                "text": text,
            ]
            response["length"] = text.count
            return (jsonEncode(response), false)
        }

        // Something is on the clipboard but we can't interpret it.
        let typeNames = types.map { $0.rawValue }
        let response: [String: Any] = [
            "type": "unknown",
            "pasteboard_types": typeNames,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Write

    private func write(text: String) -> (String, Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let response: [String: Any] = [
            "ok": true,
            "length": text.count,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Helpers

    /// Extract image data from the pasteboard as PNG. Checks TIFF first (most
    /// common for screenshots), then PNG directly.
    private func imageDataFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return pngData
        }
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }
        return nil
    }

    private func jsonEncode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"type\":\"error\",\"message\":\"failed to serialize response\"}"
        }
        return str
    }
}
