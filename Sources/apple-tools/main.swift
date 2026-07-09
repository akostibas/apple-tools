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
//
// Why not swift-argument-parser? The source of truth here is the LLM tool
// schema (`ToolDefinition`), consumed primarily by an agent (probe-macos), and
// the CLI is a *projection* of it. ArgumentParser inverts that ownership — it
// wants the command tree (Swift structs with @Option/@Argument/subcommands) to
// be authoritative and derives parsing from types; it emits no JSON schema. Using
// it would mean maintaining two representations per tool (an ArgumentParser
// command AND the hand-written schema) and keeping them in sync — the exact drift
// this single-schema design avoids. The cost is that we hand-roll usage rendering
// (see CLIHelp) and completion (a follow-up). Revisiting this would be an ADR.

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

/// Human-facing per-tool help. Delegates to the testable renderer in the lib;
/// `action` scopes the output to a single action's block when non-nil.
func toolUsage(_ tool: ProbeTool, action: String? = nil) -> String {
    CLIHelp.render(tool.definition, action: action)
}

func listTools(_ tools: [ProbeTool]) {
    print("Available tools (run `apple-tools <tool> --help` for details):\n")
    for tool in tools.sorted(by: { $0.definition.name < $1.definition.name }) {
        let def = tool.definition
        print("  \(def.name) — \(def.cliSummary ?? def.description)")
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
      apple-tools <tool> --help                Show a tool's actions and flags
      apple-tools <tool> <action> --help       Show one action's flags
      apple-tools <tool> [action] [--flag v]   Run a tool action
      apple-tools <tool> --json '{...}'        Run a tool with raw JSON params
      apple-tools permissions                  Preflight all tools (trigger TCC dialogs)
      apple-tools completion zsh               Print the zsh completion script
      apple-tools version                      Print version

    Global options:
      --confirm            Require an interactive Allow/Deny dialog for
                           sensitive actions (screenshot, open-uri).
      --quiet              Suppress the macOS completion notification
                           (also: APPLE_TOOLS_QUIET=1).
      --output-dir <dir>   Where file-producing tools write output
                           (default: $APPLE_TOOLS_OUTPUT_DIR or a temp dir).
      --root <name>=<path> Add a named documents root alongside the built-in
                           'Documents' (~/Documents). Repeatable. Documents
                           tool paths are namespaced as '<name>/<relative>'.

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

// Hidden `__complete` subcommand for shell completion (see CLICompletion and
// completions/_apple-tools). Handled first — before global-flag scanning, the
// update nudge, or any other output — so a Tab keypress stays silent and fast
// (no network, no stderr) and the raw words reach the completer intact. In
// particular, global-flag scanning strips `--`/`--output-dir`, which would
// corrupt a partial line like `email draft --`. The words after the marker are
// what the user has typed so far, the last of which is the token under the
// cursor (possibly empty). Not registered as a tool and not listed by `list`,
// so it stays hidden.
if argv.first == "__complete" {
    let words = Array(argv.dropFirst())
    let completionHost = ToolHost(fileSink: LocalFileSink(outputDir: nil),
                                  confirmer: AllowAllConfirmer(),
                                  appName: "apple-tools")
    let candidates = CLICompletion.complete(tools: allAppleTools(host: completionHost), words: words)
    print(CLICompletion.render(candidates))
    exit(0)
}

// `apple-tools completion <shell>` prints the shell completion script to stdout
// (the kubectl/gh model). Handled here — before the update nudge — because it's
// commonly run at shell startup via `source <(apple-tools completion zsh)`, and
// any stray stderr/stdout there is noise. zsh is the only supported shell today
// (bash/fish are a follow-up; see issue #44 non-goals).
if argv.first == "completion" {
    switch argv.count > 1 ? argv[1] : nil {
    case "zsh":
        print(CLICompletion.zshScript)
        exit(0)
    case let other?:
        printErr("unsupported shell: \(other)\n\nSupported shells: zsh")
        exit(1)
    case nil:
        printErr("usage: apple-tools completion <shell>\n\nSupported shells: zsh")
        exit(1)
    }
}

// Extract global options anywhere in the argument list.
var outputDir: String?
var quiet = ProcessInfo.processInfo.environment["APPLE_TOOLS_QUIET"] == "1"
// Confirmation dialogs are off by default so the CLI runs non-interactively
// under an agent (the agent's own per-invocation approval is the gate).
// `--confirm` (or APPLE_TOOLS_CONFIRM=1) opts into a blocking Allow/Deny dialog.
var confirm = ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["APPLE_TOOLS_CONFIRM"] ?? "")
// Extra documents roots (additive — the ~/Documents default is always
// present). Parsed from repeatable `--root name=path`.
var extraDocumentRoots: [DocumentRoot] = []
func parseRootFlag(_ value: String) -> DocumentRoot {
    guard let eq = value.firstIndex(of: "="), eq != value.startIndex else {
        fail("--root expects name=path, got: \(value)")
    }
    let name = String(value[..<eq])
    let path = String(value[value.index(after: eq)...])
    if path.isEmpty { fail("--root expects name=path, got: \(value)") }
    if name.contains("/") { fail("--root name must not contain '/': \(name)") }
    if name == DocumentRoot.documents.name || extraDocumentRoots.contains(where: { $0.name == name }) {
        fail("duplicate --root name: \(name)")
    }
    return DocumentRoot(name: name, path: path)
}
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
        case "--root":
            guard i + 1 < argv.count else { fail("--root needs a value (name=path)") }
            extraDocumentRoots.append(parseRootFlag(argv[i + 1]))
            i += 2
        default:
            // `--output-dir=PATH` keeps the value in one token, so it can't
            // swallow the following token (#34).
            if arg.hasPrefix("--output-dir=") {
                outputDir = String(arg.dropFirst("--output-dir=".count))
            } else if arg.hasPrefix("--root=") {
                extraDocumentRoots.append(parseRootFlag(String(arg.dropFirst("--root=".count))))
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
let tools = allAppleTools(host: host, documentsRoots: [.documents] + extraDocumentRoots)

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

let schema = tool.definition.parameters
let hasAction = schema?.properties?["action"] != nil

// Per-tool help. `--help`/`-h` anywhere triggers it; a leading positional token
// (the action) scopes the render to that action — `apple-tools email draft --help`.
if rest.contains("--help") || rest.contains("-h") {
    let scopedAction: String? = {
        guard hasAction, let candidate = rest.first, !candidate.hasPrefix("-") else { return nil }
        return candidate
    }()
    print(toolUsage(tool, action: scopedAction))
    exit(0)
}

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
