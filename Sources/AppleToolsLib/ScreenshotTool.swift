import AppKit
import Foundation

public struct ScreenshotTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "screenshot",
        description: "Capture the Mac screen. Prompts the user for confirmation before capturing. Returns a reference to the saved screenshot.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [:],
            required: nil
        )
    )

    public let host: ToolHost

    public let accessPolicy: ToolAccessPolicy = .whole(.read)

    public init(host: ToolHost) {
        self.host = host
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        // Ask the user for permission before capturing.
        guard requestConfirmation() else {
            return ("User denied the screenshot request.", true)
        }

        // Capture to a temp file.
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let tmpPath = NSTemporaryDirectory() + "\(host.appName)-screenshot-\(timestamp).png"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", tmpPath]  // -x: no sound

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("screencapture failed: \(error.localizedDescription)", true)
        }

        guard process.terminationStatus == 0 else {
            return ("screencapture exited with status \(process.terminationStatus). Screen Recording permission may be required (System Settings > Privacy & Security > Screen Recording).", true)
        }

        guard let pngData = FileManager.default.contents(atPath: tmpPath) else {
            return ("screencapture produced no output. Screen Recording permission may be required (System Settings > Privacy & Security > Screen Recording).", true)
        }

        // Resize for LLM consumption.
        guard let data = ImageResizer.resizeForLLM(imageData: pngData) else {
            return ("failed to resize screenshot", true)
        }
        let filename = "screenshot-\(timestamp).jpg"

        // Hand off to the host's file sink.
        let result = host.fileSink.deliver(filename: filename, data: data)
        switch result {
        case .success(let ref):
            let response: [String: Any] = [
                ref.key: ref.value,
                "filename": filename,
            ]
            return (jsonEncode(response), false)
        case .failure(let error):
            return ("upload failed: \(error)", true)
        }
    }

    // MARK: - Confirmation

    private func requestConfirmation() -> Bool {
        return host.confirmer.confirm(
            title: "\(host.appName): Screenshot",
            message: "Allow \(host.appName) to take a screenshot of your screen?"
        )
    }

    // MARK: - Helpers

    private func jsonEncode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
