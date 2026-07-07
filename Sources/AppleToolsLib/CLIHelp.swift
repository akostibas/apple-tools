import Foundation

// MARK: - Human-facing CLI help rendering
//
// `apple-tools <tool> --help` should read like documentation for a person, not
// mirror the LLM tool schema. The schema (ToolDefinition.description + property
// descriptions) is authored to steer a model — long, caveat-dense prose with
// manual `(for search)` crutches, one flat alphabetical flag list.
//
// This renderer projects the SAME ToolDefinition into human help using the
// CLI-only metadata (`cliSummary`, `actions`, per-flag `summary`/`actions`)
// that is stripped from the LLM payload (see ProbeTool.swift). Flags are grouped
// under the action that owns them, terse `summary` text replaces the model prose,
// and each action gets a usage/example line.
//
// Fallback: a tool with no `actions` metadata (single-action tools, or any not
// yet migrated) renders the legacy flat parameter list, so partial adoption is
// safe.

public enum CLIHelp {
    /// Render `apple-tools <tool> --help`.
    ///
    /// - Parameter action: when non-nil, render only that action's block
    ///   (`apple-tools <tool> <action> --help`). An unknown action falls back
    ///   to the full tool help.
    public static func render(_ def: ToolDefinition, action: String? = nil) -> String {
        let blurb = def.cliSummary ?? def.description

        // Scoped help: a single action's block.
        if let action, let actions = def.actions,
           let match = actions.first(where: { $0.name == action }) {
            return renderScoped(def: def, action: match)
        }

        // No action metadata → legacy flat list (single-action tools, etc.).
        guard let actions = def.actions, !actions.isEmpty else {
            return renderFlat(name: def.name, blurb: blurb, params: def.parameters)
        }

        var lines = ["\(def.name) — \(blurb)", ""]
        lines.append("Usage: apple-tools \(def.name) <action> [--flag value ...]")
        lines.append("")
        lines.append("Actions:")

        let props = def.parameters?.properties ?? [:]
        let nameWidth = actions.map(\.name.count).max() ?? 0
        for act in actions {
            lines.append(contentsOf: actionBlock(act, props: props, indent: "  ", nameWidth: nameWidth))
            lines.append("")
        }

        lines.append("Pass raw JSON instead:  apple-tools \(def.name) --json '{\"action\":\"…\"}'")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single-action scoped help

    private static func renderScoped(def: ToolDefinition, action: ActionHelp) -> String {
        let props = def.parameters?.properties ?? [:]
        var lines = ["\(def.name) \(action.name) — \(action.summary)", ""]
        if let example = action.example {
            lines.append("Usage: \(example)")
            lines.append("")
        }
        for line in flagLines(for: action, props: props, indent: "  ") {
            lines.append(line)
        }
        lines.append("")
        lines.append("Part of `\(def.name)`. Run `apple-tools \(def.name) --help` for all actions.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Per-action block

    private static func actionBlock(_ act: ActionHelp, props: [String: PropertySchema], indent: String, nameWidth: Int) -> [String] {
        var lines = ["\(indent)\(pad(act.name, to: nameWidth + 3))\(act.summary)"]
        if let example = act.example {
            lines.append("\(indent)    \(example)")
        }
        lines.append(contentsOf: flagLines(for: act, props: props, indent: indent + "    "))
        return lines
    }

    /// Flags owned by an action: required first (declaration order preserved via
    /// the action's `required` list), then the remaining owned flags. `action`
    /// membership comes from each property's `actions` field.
    private static func flagLines(for act: ActionHelp, props: [String: PropertySchema], indent: String) -> [String] {
        let owned = props.filter { $0.value.actions?.contains(act.name) ?? false }
        let required = act.required.filter { owned[$0] != nil }
        let optional = owned.keys.filter { !act.required.contains($0) }.sorted()
        let ordered = required + optional
        return ordered.compactMap { name in
            guard let p = owned[name] else { return nil }
            return flagLine(name: name, p: p, required: act.required.contains(name), indent: indent)
        }
    }

    private static func flagLine(name: String, p: PropertySchema, required: Bool, indent: String) -> String {
        let req = required ? "(required) " : ""
        let help = p.summary ?? p.description ?? ""
        return "\(indent)\(pad(flagSpec(name: name, p: p), to: 24))\(req)\(help)"
    }

    /// The `--flag <type>` column. Booleans are bare switches (`--flag`, no
    /// value); arrays show their element type (`--paths <string[]>`).
    private static func flagSpec(name: String, p: PropertySchema) -> String {
        switch p.type_ {
        case "boolean": return "--\(name)"
        case "array":   return "--\(name) <\(p.items?.type_ ?? "string")[]>"
        default:        return "--\(name) <\(p.type_)>"
        }
    }

    // MARK: - Legacy flat fallback

    private static func renderFlat(name: String, blurb: String, params: ParameterSchema?) -> String {
        var lines = ["\(name) — \(blurb)", ""]
        guard let props = params?.properties, !props.isEmpty else {
            lines.append("  (no parameters)")
            return lines.joined(separator: "\n")
        }
        let required = Set(params?.required ?? [])
        lines.append("Parameters (pass as --flag value; use --json '{...}' for raw):")
        for name in props.keys.sorted() {
            let p = props[name]!
            let req = required.contains(name) ? "(required) " : ""
            let help = p.summary ?? p.description ?? ""
            lines.append("  \(pad(flagSpec(name: name, p: p), to: 24))\(req)\(help)")
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s + "  " : s + String(repeating: " ", count: width - s.count)
    }
}
