import Foundation

// MARK: - Dynamic shell completion core
//
// apple-tools deliberately doesn't use swift-argument-parser (the LLM JSON
// schema is authoritative — see main.swift), so we don't get completion for
// free. Instead we follow the kubectl/Cobra model: a hidden
// `apple-tools __complete <words...>` subcommand introspects the tool registry
// at runtime and prints the candidates for whatever token comes next.
//
// Everything here derives from `ToolDefinition`/`ActionHelp`, so completion can
// never drift from the actual CLI — the same guarantee CLIHelp gives for
// `--help`. The shell function (completions/_apple-tools) is a thin adapter that
// forwards the current words and feeds these candidates to `_describe`.
//
// Positions handled (mirrors the issue's three cases):
//   1. `apple-tools <Tab>`                  → top-level commands + tool names
//   2. `apple-tools <tool> <Tab>`           → that tool's action names (if it
//                                             dispatches on `action`)
//   3. `apple-tools <tool> <action> <Tab>`  → that action's flags, minus any
//                                             already supplied
// Tools without an `action` param skip straight to their flags after the tool
// name. Completing flag *values* is a non-goal (see issue #44).

public enum CLICompletion {

    /// One completion candidate: the token to insert plus optional help text
    /// (an action's summary, a flag's summary). Rendered as `value\tdescription`
    /// by `__complete` so the zsh side can split on the tab for `_describe`.
    public struct Candidate: Equatable {
        public let value: String
        public let description: String?

        public init(value: String, description: String? = nil) {
            self.value = value
            self.description = description
        }
    }

    /// Top-level, non-tool subcommands the CLI understands. Kept here so
    /// position-1 completion offers them alongside the tool names. `__complete`
    /// itself is intentionally omitted — it's hidden.
    static let topLevelCommands: [Candidate] = [
        Candidate(value: "list", description: "List available tools"),
        Candidate(value: "permissions", description: "Preflight all tools (trigger TCC dialogs)"),
        Candidate(value: "version", description: "Print version"),
    ]

    /// Compute completion candidates for the final (partial) token in `words`.
    ///
    /// - Parameters:
    ///   - tools: the live tool registry (`allAppleTools(host:)`).
    ///   - words: the apple-tools argument tokens typed so far, *including* the
    ///     word under the cursor as the last element (which may be `""`). The
    ///     binary name and the `__complete` marker are not part of this array.
    /// - Returns: candidates whose `value` has the partial token as a prefix,
    ///   in a stable order (registry/declaration order, then alphabetical).
    public static func complete(tools: [ProbeTool], words: [String]) -> [Candidate] {
        let toComplete = words.last ?? ""
        let prior = Array(words.dropLast())

        // Position 1: no completed tokens yet → top-level commands + tool names.
        guard let toolName = prior.first else {
            let toolCandidates = tools
                .map { Candidate(value: $0.definition.name, description: $0.definition.cliSummary ?? $0.definition.description) }
                .sorted { $0.value < $1.value }
            return filter(topLevelCommands + toolCandidates, prefix: toComplete)
        }

        // A known tool must lead; anything else (a top-level command, a typo)
        // has nothing further to complete.
        guard let def = tools.first(where: { $0.definition.name == toolName })?.definition else {
            return []
        }

        let dispatchesOnAction = def.parameters?.properties?["action"] != nil
        // The action is the first positional token after the tool name (never a
        // flag). `afterTool` is everything the user has entered past the tool.
        let afterTool = Array(prior.dropFirst())
        let chosenAction: String? = {
            guard dispatchesOnAction, let candidate = afterTool.first, !candidate.hasPrefix("-") else { return nil }
            return candidate
        }()

        // Position 2: tool dispatches on action but none chosen yet → action names.
        if dispatchesOnAction && chosenAction == nil {
            let actions = (def.actions ?? [])
                .map { Candidate(value: $0.name, description: $0.summary) }
            return filter(actions, prefix: toComplete)
        }

        // Position 3: complete flags, skipping any already supplied.
        return filter(flagCandidates(def: def, action: chosenAction, supplied: suppliedFlags(prior)), prefix: toComplete)
    }

    // MARK: - Flags

    /// Flag candidates for the resolved (tool, action). Mirrors CLIHelp's
    /// ownership rule: a flag belongs to an action when its `actions` list
    /// includes it. Tools without action dispatch offer all their flags. The
    /// positional `action` param is never a flag; already-supplied flags drop.
    private static func flagCandidates(def: ToolDefinition, action: String?, supplied: Set<String>) -> [Candidate] {
        let props = def.parameters?.properties ?? [:]
        let owned = props.filter { name, p in
            guard name != "action" else { return false }
            guard let action else { return true }         // no dispatch → all flags
            return p.actions?.contains(action) ?? false
        }
        return owned.keys.sorted()
            .filter { !supplied.contains($0) }
            .map { name in
                let p = owned[name]!
                return Candidate(value: "--\(name)", description: p.summary ?? p.description)
            }
    }

    /// Flag names already present on the command line (leading `--`, stripped).
    private static func suppliedFlags(_ tokens: [String]) -> Set<String> {
        Set(tokens.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) })
    }

    // MARK: - Helpers

    private static func filter(_ candidates: [Candidate], prefix: String) -> [Candidate] {
        prefix.isEmpty ? candidates : candidates.filter { $0.value.hasPrefix(prefix) }
    }

    /// Serialize candidates for the `__complete` subcommand: one per line as
    /// `value` or `value\tdescription`. Empty when there are no candidates.
    public static func render(_ candidates: [Candidate]) -> String {
        candidates.map { c in
            if let d = c.description, !d.isEmpty { return "\(c.value)\t\(d)" }
            return c.value
        }.joined(separator: "\n")
    }

    /// The zsh completion function, emitted by `apple-tools completion zsh`.
    /// This is the single source of truth for the shell glue (there is no
    /// separately checked-in `_apple-tools` file to drift from it). It's a thin
    /// adapter — all real logic lives in the `__complete` subcommand above.
    ///
    /// Dual-mode, so one script serves both install paths (see the README):
    ///   - autoloaded from `$fpath` — the `#compdef` tag + trailing self-call,
    ///   - sourced via `source <(apple-tools completion zsh)` — the `compdef`
    ///     registration in the else branch.
    /// The `funcstack` guard (kubectl's trick) distinguishes the two: when the
    /// file is autoloaded the running function IS `_apple-tools`, so we invoke
    /// it; when sourced we only register it.
    public static let zshScript = #"""
    #compdef apple-tools
    #
    # zsh completion for apple-tools. Generated by `apple-tools completion zsh` —
    # do not edit by hand; regenerate instead. All candidates come from the
    # binary's hidden `apple-tools __complete` subcommand, which introspects the
    # live tool registry, so completion can never drift from the CLI.

    _apple-tools() {
      local -a words_to_complete
      # $words is the full command line; $CURRENT is the 1-based cursor word.
      # Forward everything after the command name up to and including the word
      # under the cursor — the last element is the partial token (empty on a
      # fresh word).
      words_to_complete=("${words[@]:1:$((CURRENT - 1))}")

      local -a candidates
      local line value desc
      # Each __complete line is `value` or `value<TAB>description`.
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        value="${line%%$'\t'*}"
        if [[ "$line" == *$'\t'* ]]; then
          desc="${line#*$'\t'}"
          candidates+=("${value}:${desc}")
        else
          candidates+=("$value")
        fi
      done < <(apple-tools __complete "${words_to_complete[@]}" 2>/dev/null)

      _describe -t apple-tools 'apple-tools' candidates
    }

    if [ "$funcstack[1]" = "_apple-tools" ]; then
      # Autoloaded from $fpath: the file name is the function — run it.
      _apple-tools
    else
      # Sourced (e.g. `source <(apple-tools completion zsh)`): just register.
      compdef _apple-tools apple-tools
    fi
    """#
}
