import AppleToolsLib
import Foundation

// MARK: - apple-tools CLI
//
// Ergonomic, schema-driven front-end over the AppleToolsLib tools. Every tool
// exposes a `ToolDefinition` (a JSON schema); this driver maps
//   apple-tools <tool> [action] [--flag value ...]
// onto that schema with no per-tool code: `action` becomes a positional
// subcommand, every other property becomes a `--flag`, and values are coerced
// to the property's declared JSON type before calling `handle(params:)`.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Pretty-print a tool result: indented JSON if it parses as JSON, else raw.
func emit(_ result: String) {
    if let data = result.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: pretty, encoding: .utf8) {
        print(str)
    } else {
        print(result)
    }
}

func toolUsage(_ tool: ProbeTool) -> String {
    let def = tool.definition
    var lines = ["\(def.name) — \(def.description)", ""]
    guard let props = def.parameters?.properties, !props.isEmpty else {
        lines.append("  (no parameters)")
        return lines.joined(separator: "\n")
    }
    let required = Set(def.parameters?.required ?? [])
    lines.append("Parameters (pass as --flag value; use --json '{...}' for raw):")
    for name in props.keys.sorted() {
        let p = props[name]!
        let req = required.contains(name) ? " (required)" : ""
        let arr = p.type_ == "array" ? "[]" : ""
        lines.append("  --\(name) <\(p.type_)\(arr)>\(req)  \(p.description ?? "")")
    }
    return lines.joined(separator: "\n")
}

func listTools(_ tools: [ProbeTool]) {
    print("Available tools (run `apple-tools <tool> --help` for details):\n")
    for tool in tools.sorted(by: { $0.definition.name < $1.definition.name }) {
        print("  \(tool.definition.name) — \(tool.definition.description)")
    }
}

func runPermissions(_ tools: [ProbeTool]) -> Never {
    print("Preflighting \(tools.count) tools (this triggers macOS permission dialogs)...\n")
    var denied: [String] = []
    for tool in tools {
        let (ok, message) = tool.preflight()
        print("  \(ok ? "✓" : "✗") \(tool.definition.name): \(message)")
        if !ok { denied.append(tool.definition.name) }
    }
    if denied.isEmpty {
        print("\nAll tools ready.")
        exit(0)
    }
    print("\n\(denied.count) tool(s) denied: \(denied.joined(separator: ", "))")
    print("Grant access in System Settings → Privacy & Security, then re-run.")
    exit(2)
}

func printTopUsage() {
    print("""
    apple-tools — local macOS/Apple integrations as a CLI

    Usage:
      apple-tools list                         List available tools
      apple-tools <tool> --help                Show a tool's parameters
      apple-tools <tool> [action] [--flag v]   Run a tool action
      apple-tools <tool> --json '{...}'        Run a tool with raw JSON params
      apple-tools permissions                  Preflight all tools (trigger TCC dialogs)
      apple-tools version                      Print version

    Global options:
      --confirm            Require an interactive Allow/Deny dialog for
                           sensitive actions (screenshot, open-uri).
      --quiet              Suppress the macOS completion notification
                           (also: APPLE_TOOLS_QUIET=1).
      --output-dir <dir>   Where file-producing tools write output
                           (default: $APPLE_TOOLS_OUTPUT_DIR or a temp dir).

    Examples:
      apple-tools calendar list --start 2026-06-15T00:00:00Z --end 2026-06-16T00:00:00Z
      apple-tools reminders list
      apple-tools contacts search --query "Jane"
      apple-tools notes create --title "Ideas" --body "..."
      apple-tools screenshot
    """)
}

/// Short, banner-friendly summary of a tool result for the notification.
func notificationBody(tool: String, action: String?, result: String, isError: Bool) -> String {
    let head = action.map { "\(tool) \($0)" } ?? tool
    if isError {
        let firstLine = result.split(separator: "\n").first.map(String.init) ?? "error"
        return "\(head) → error: \(firstLine.prefix(80))"
    }
    if let data = result.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) {
        if let arr = json as? [Any] { return "\(head) → \(arr.count) result(s)" }
        if let dict = json as? [String: Any] {
            if let c = dict["count"] { return "\(head) → \(c) result(s)" }
            if let s = dict["status"] { return "\(head) → \(s)" }
            if let t = dict["transport"] { return "\(head) → sent (\(t))" }
            if dict["path"] != nil { return "\(head) → file saved" }
            if dict["ok"] != nil { return "\(head) → ok" }
        }
        return "\(head) → done"
    }
    return "\(head) → done"
}

// MARK: - Entry

var argv = Array(CommandLine.arguments.dropFirst())

// Extract global options anywhere in the argument list.
var outputDir: String?
var quiet = ProcessInfo.processInfo.environment["APPLE_TOOLS_QUIET"] == "1"
// Confirmation dialogs are off by default so the CLI runs non-interactively
// under an agent (the agent's own per-invocation approval is the gate).
// `--confirm` (or APPLE_TOOLS_CONFIRM=1) opts into a blocking Allow/Deny dialog.
var confirm = ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["APPLE_TOOLS_CONFIRM"] ?? "")
var globalArgs: [String] = []
do {
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        // A standalone `--` terminates global-flag scanning: every token after
        // it is passed to the tool verbatim, so a tool-flag value that collides
        // with a global-flag name is never stolen (#34).
        if arg == "--" {
            globalArgs.append(contentsOf: argv[(i + 1)...])
            break
        }
        switch arg {
        case "--confirm":
            confirm = true
            i += 1
        case "--quiet":
            quiet = true
            i += 1
        case "--output-dir":
            guard i + 1 < argv.count else { fail("--output-dir needs a value") }
            outputDir = argv[i + 1]
            i += 2
        default:
            // `--output-dir=PATH` keeps the value in one token, so it can't
            // swallow the following token (#34).
            if arg.hasPrefix("--output-dir=") {
                outputDir = String(arg.dropFirst("--output-dir=".count))
            } else {
                globalArgs.append(arg)
            }
            i += 1
        }
    }
}
argv = globalArgs

let host = ToolHost(
    fileSink: LocalFileSink(outputDir: outputDir),
    confirmer: confirm ? AppleScriptConfirmer() : AllowAllConfirmer(),
    appName: "apple-tools"
)
let tools = allAppleTools(host: host)

// Best-effort weekly "you're behind" nudge to stderr (never stdout — the JSON
// tool contract). CLI-only: library/API hosts embedding AppleToolsLib never
// reach this call, so they see no output and make no network call.
UpdateCheck.maybeNudge()

guard let first = argv.first else {
    printTopUsage()
    exit(0)
}

switch first {
case "-h", "--help":
    printTopUsage(); exit(0)
case "version", "--version", "-version":
    print(AppleToolsVersion.description); exit(0)
case "list", "tools":
    listTools(tools); exit(0)
case "permissions", "preflight":
    runPermissions(tools)
default:
    break
}

guard let tool = tools.first(where: { $0.definition.name == first }) else {
    printErr("unknown tool: \(first)\n")
    listTools(tools)
    exit(1)
}

let rest = Array(argv.dropFirst())

// Per-tool help.
if rest.first == "--help" || rest.first == "-h" {
    print(toolUsage(tool))
    exit(0)
}

let schema = tool.definition.parameters
let hasAction = schema?.properties?["action"] != nil

var params: [String: AnyCodable]
var resolvedAction: String?

// A leading positional token (for tools that dispatch on `action`) is the
// action subcommand. Capture it up front so it survives BOTH the --flag mapper
// and the --json escape hatch — previously `<tool> <action> --json {...}`
// silently dropped the action (#34).
var positionalAction: String?
var afterAction = rest
if hasAction, let candidate = rest.first, !candidate.hasPrefix("--") {
    positionalAction = candidate
    afterAction = Array(rest.dropFirst())
}

// Raw JSON escape hatch.
if let jsonIdx = afterAction.firstIndex(of: "--json") {
    guard jsonIdx + 1 < afterAction.count else { fail("--json needs a JSON object argument") }
    let jsonStr = afterAction[jsonIdx + 1]
    guard let data = jsonStr.data(using: .utf8),
          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("--json value is not a valid JSON object")
    }
    // Merge a positional action into the JSON params. Reject the mixed form
    // loudly if the JSON also carries a *different* action rather than silently
    // preferring one (#34).
    if let action = positionalAction {
        if let jsonAction = obj["action"] as? String, jsonAction != action {
            fail("conflicting action: positional '\(action)' vs '\(jsonAction)' in --json (pass only one)")
        }
        obj["action"] = action
    }
    params = obj.mapValues { AnyCodable($0) }
    resolvedAction = params["action"]?.value as? String
} else {
    resolvedAction = positionalAction
    do {
        params = try CLIArgumentMapper.buildParams(tokens: afterAction, schema: schema, action: positionalAction)
    } catch {
        fail("\(error)")
    }
}

// Run the tool off the main thread and pump the main run loop while it works.
// Some macOS APIs (notably PHImageManager in PhotosTool) deliver their
// completion on the main queue; the integrations block on a semaphore waiting
// for it. In a menu-bar app the run loop is already alive, but a bare CLI must
// keep the main run loop turning or those callbacks never fire (deadlock).
let work = DispatchGroup()
work.enter()
var outcome: (result: String, isError: Bool) = ("", false)
DispatchQueue.global().async {
    outcome = tool.handle(params: params)
    work.leave()
}
while work.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
let (result, isError) = outcome
emit(result)

if !quiet {
    Notifier.notify(
        title: "apple-tools",
        body: notificationBody(tool: tool.definition.name, action: resolvedAction, result: result, isError: isError)
    )
}

exit(isError ? 1 : 0)
