import Foundation

public struct EchoTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "echo",
        description: "Echoes back the message. Use this to verify the probe connection is working.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "message": PropertySchema(type_: "string", description: "The message to echo back"),
            ],
            required: ["message"]
        )
    )

    public let accessPolicy: ToolAccessPolicy = .whole(.read)

    public init() {}

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let message = params?["message"]?.value as? String else {
            return ("missing required parameter: message", true)
        }
        return (message, false)
    }
}
