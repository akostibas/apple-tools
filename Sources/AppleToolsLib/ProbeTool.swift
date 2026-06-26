import Foundation

// MARK: - Tool protocol

/// Conform to ProbeTool to add a new tool to the probe.
/// Each tool lives in its own file and is registered in main.swift.
public protocol ProbeTool {
    var definition: ToolDefinition { get }
    func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool)

    /// Exercise a read-only operation to trigger any macOS permission dialogs at startup.
    /// Returns (ok, message) — ok is true if permission was granted, message describes the result.
    func preflight() -> (ok: Bool, message: String)

    /// Classifies each operation the tool can perform as read or read/write.
    /// Used to enforce probe read-only mode. Every operation MUST be
    /// classified — there is no implicit-RW fallback. If the tool dispatches
    /// on an `action` parameter, use `.perAction(...)` listing every action.
    /// Otherwise use `.whole(.read)` or `.whole(.readWrite)`.
    var accessPolicy: ToolAccessPolicy { get }
}

/// Read or read/write classification for a probe tool operation.
public enum AccessMode: String, Codable {
    case read
    case readWrite = "read_write"
}

/// How a tool's operations are classified for read-only enforcement.
public enum ToolAccessPolicy {
    /// Tool has no sub-actions; the whole tool is either read or read/write.
    case whole(AccessMode)
    /// Tool dispatches on an `action` parameter. Map every action to its
    /// access mode. Actions not in the map fail closed when RO is active.
    case perAction([String: AccessMode])
}

extension ProbeTool {
    public func preflight() -> (ok: Bool, message: String) {
        return (true, "no permissions required")
    }
}

/// All registered Apple tools. `host` supplies the file sink (where
/// file-producing tools deliver output), the confirmer (how sensitive actions
/// are gated), and the user-facing app name. Pure read-only tools ignore it.
public func allAppleTools(host: ToolHost) -> [ProbeTool] {
    return [
        EchoTool(),
        FilesTool(host: host),
        CalendarTool(),
        ClipboardTool(host: host),
        RemindersTool(),
        PhotosTool(host: host),
        ContactsTool(),
        ScreenshotTool(host: host),
        NotesTool(),
        EmailTool(host: host),
        IMessageTool(host: host),
        OpenURITool(host: host),
    ]
}

// MARK: - Protocol types

public struct ToolDefinition: Codable {
    public let name: String
    public let description: String
    public let parameters: ParameterSchema?

    public init(name: String, description: String, parameters: ParameterSchema?) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ParameterSchema: Codable {
    public let type_: String
    public let properties: [String: PropertySchema]?
    public let required: [String]?

    public init(type_: String, properties: [String: PropertySchema]?, required: [String]?) {
        self.type_ = type_
        self.properties = properties
        self.required = required
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case properties
        case required
    }
}

public struct PropertySchema: Codable {
    public let type_: String
    public let description: String?
    public let items: ItemsSchema?

    public init(type_: String, description: String?, items: ItemsSchema? = nil) {
        self.type_ = type_
        self.description = description
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case description
        case items
    }
}

/// JSON Schema "items" descriptor for array-typed properties. Only the
/// element type is meaningful for our use cases today (e.g. an array of
/// file path strings).
public struct ItemsSchema: Codable {
    public let type_: String

    public init(type_: String) {
        self.type_ = type_
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
    }
}

// MARK: - AnyCodable (minimal, for JSON params)

public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map { $0.value } }
        else if container.decodeNil() { value = NSNull() }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported type") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String: try container.encode(s)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let b as Bool: try container.encode(b)
        case let a as [Any]: try container.encode(a.map { AnyCodable($0) })
        case is NSNull: try container.encodeNil()
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "unsupported type"))
        }
    }
}
