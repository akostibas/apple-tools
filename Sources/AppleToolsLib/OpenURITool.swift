import AppKit
import Foundation

public struct OpenURITool: ProbeTool {
    public let definition = ToolDefinition(
        name: "open_uri",
        description: "Open a URI on the Mac. Prompts the user for confirmation before opening. Supports web URLs, mailto:, tel:, app deep links, and other URI schemes.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "uri": PropertySchema(type_: "string", description: "URI to open (e.g. https://example.com, mailto:user@example.com, shortcuts://run-shortcut?name=...)"),
            ],
            required: ["uri"]
        )
    )

    public let accessPolicy: ToolAccessPolicy = .whole(.readWrite)

    public let host: ToolHost

    public init(host: ToolHost) {
        self.host = host
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let uriString = params?["uri"]?.value as? String, !uriString.isEmpty else {
            return ("missing required parameter: uri", true)
        }

        guard let url = URL(string: uriString) else {
            return ("invalid URI: \(uriString)", true)
        }

        guard host.confirmer.confirm(
            title: "\(host.appName): Open URI",
            message: "Allow \(host.appName) to open:\n\(uriString)"
        ) else {
            return ("User denied the request to open: \(uriString)", true)
        }

        let opened = NSWorkspace.shared.open(url)
        if opened {
            return (jsonEncode(["ok": true, "uri": uriString]), false)
        } else {
            return ("macOS could not open URI: \(uriString)", true)
        }
    }

    private func jsonEncode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
