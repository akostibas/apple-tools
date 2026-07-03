import Foundation

/// Maps ergonomic `--flag value` CLI tokens onto a tool's `ParameterSchema`,
/// producing the `[String: AnyCodable]` params dict `ProbeTool.handle` expects.
/// Pure and throwing (no process exit) so it is unit-testable and reusable.
public enum CLIArgumentMapper {

    public enum MappingError: Error, CustomStringConvertible, Equatable {
        case unexpectedArgument(String)
        case missingValue(flag: String)
        public var description: String {
            switch self {
            case .unexpectedArgument(let a): return "unexpected argument: \(a) (expected --flag value)"
            case .missingValue(let f): return "flag --\(f) needs a value"
            }
        }
    }

    /// Normalize a CLI flag (`--calendar-name` / `calendar_name`) to the
    /// snake_case property name used in the tool schemas.
    public static func normalizeKey(_ raw: String) -> String {
        var s = raw
        while s.hasPrefix("-") { s.removeFirst() }
        return s.replacingOccurrences(of: "-", with: "_")
    }

    /// Coerce a string value to the JSON type declared by the property schema.
    public static func coerce(_ value: String, type: String) -> Any {
        switch type {
        case "integer": return Int(value) ?? value
        case "number":  return Double(value) ?? value
        case "boolean": return ["1", "true", "yes"].contains(value.lowercased())
        default:        return value
        }
    }

    /// Build the params dict from `--flag value` tokens against a tool schema.
    /// `action` (if non-nil) is injected as the `action` param.
    public static func buildParams(
        tokens: [String],
        schema: ParameterSchema?,
        action: String?
    ) throws -> [String: AnyCodable] {
        let props = schema?.properties ?? [:]
        var raw: [String: Any] = [:]
        if let action = action { raw["action"] = action }

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard token.hasPrefix("--") else {
                throw MappingError.unexpectedArgument(token)
            }

            // `--flag=value` attaches the value to the flag token itself. This
            // is the documented way to pass a value that begins with `--` (or
            // that collides with a global-flag name), which the space-separated
            // form can't express because a `--`-prefixed token is always read
            // as the next flag, never as a value (#34).
            let inlineValue: String?
            let flagToken: String
            if let eq = token.firstIndex(of: "=") {
                flagToken = String(token[..<eq])
                inlineValue = String(token[token.index(after: eq)...])
            } else {
                flagToken = token
                inlineValue = nil
            }

            let key = normalizeKey(flagToken)
            let type = props[key]?.type_ ?? "string"
            // An inline value is self-contained (consumes only this token); a
            // space-separated value borrows the following non-flag token.
            let next: String? = inlineValue
                ?? ((i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--")) ? tokens[i + 1] : nil)
            let step = inlineValue != nil ? 1 : 2

            if type == "array" {
                guard let v = next else { throw MappingError.missingValue(flag: key) }
                let parts = v.split(separator: ",").map { String($0) }
                var existing = (raw[key] as? [Any]) ?? []
                existing.append(contentsOf: parts)
                raw[key] = existing
                i += step
            } else if type == "boolean" {
                if let v = next { raw[key] = coerce(v, type: type); i += step }
                else { raw[key] = true; i += 1 }
            } else {
                guard let v = next else { throw MappingError.missingValue(flag: key) }
                raw[key] = coerce(v, type: type)
                i += step
            }
        }
        return raw.mapValues { AnyCodable($0) }
    }
}
