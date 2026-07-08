import XCTest
@testable import AppleToolsLib

/// Covers the dynamic shell-completion core (CLICompletion) that backs the
/// hidden `apple-tools __complete` subcommand. Like CLIHelpTests, this asserts
/// the candidates derive from the live ToolDefinition metadata, so completion
/// can't drift from the CLI (issue #44).
final class CLICompletionTests: XCTestCase {

    private func tools() -> [ProbeTool] { allAppleTools(host: .test()) }

    /// Candidate values for a given partial command line (words include the
    /// token under the cursor as the last element).
    private func values(_ words: [String]) -> [String] {
        CLICompletion.complete(tools: tools(), words: words).map(\.value)
    }

    // MARK: - Position 1: tool names + top-level commands

    func testTopLevelCompletesToolsAndCommands() {
        let v = values([""])
        XCTAssertTrue(v.contains("email"), "tool names should complete at position 1")
        XCTAssertTrue(v.contains("calendar"))
        XCTAssertTrue(v.contains("list"), "top-level commands should complete too")
        XCTAssertTrue(v.contains("version"))
        XCTAssertTrue(v.contains("permissions"))
    }

    func testTopLevelFiltersByPrefix() {
        let v = values(["em"])
        XCTAssertEqual(v, ["email"], "only the prefix-matching tool should remain")
    }

    func testCompleteSubcommandItselfIsHidden() {
        XCTAssertFalse(values([""]).contains("__complete"),
                       "__complete must never be offered as a candidate")
    }

    // MARK: - Position 2: action names

    func testActionNamesCompleteAfterTool() {
        let v = values(["email", ""])
        XCTAssertTrue(v.contains("search"), "email's actions should complete")
        XCTAssertTrue(v.contains("draft"))
        XCTAssertFalse(v.contains("--query"), "flags should not appear before an action is chosen")
    }

    func testActionNamesFilterByPrefix() {
        let v = values(["email", "dr"])
        XCTAssertEqual(v, ["draft"], "only the prefix-matching action should remain")
    }

    func testActionDescriptionsComeFromSummary() {
        let candidates = CLICompletion.complete(tools: tools(), words: ["email", ""])
        let draft = candidates.first { $0.value == "draft" }
        XCTAssertNotNil(draft?.description, "action candidates carry their summary as description")
        XCTAssertFalse(draft!.description!.isEmpty)
    }

    // MARK: - Position 3: action-scoped flags

    func testFlagsCompleteForChosenAction() {
        let draft = values(["email", "draft", ""])
        XCTAssertTrue(draft.contains("--to"), "draft's flags should complete")
        XCTAssertTrue(draft.contains("--body"))
        XCTAssertFalse(draft.contains("--query"), "another action's flag must not appear")

        let search = values(["email", "search", ""])
        XCTAssertTrue(search.contains("--query"), "search's flags should complete")
        XCTAssertFalse(search.contains("--body"), "draft-only flag must not appear under search")
    }

    func testFlagsFilterByDoubleDashPrefix() {
        let v = values(["email", "draft", "--"])
        XCTAssertTrue(v.allSatisfy { $0.hasPrefix("--") }, "only flags with the -- prefix")
        XCTAssertTrue(v.contains("--to"))
    }

    func testAlreadySuppliedFlagsAreSkipped() {
        let v = values(["email", "draft", "--to", "a@b.com", "--"])
        XCTAssertFalse(v.contains("--to"), "an already-supplied flag should not be offered again")
        XCTAssertTrue(v.contains("--body"), "remaining flags still complete")
    }

    func testActionPositionalIsNeverAFlag() {
        let v = values(["email", "draft", "--"])
        XCTAssertFalse(v.contains("--action"), "the action positional must not surface as a flag")
    }

    // MARK: - Unknown / non-tool leads

    func testUnknownToolYieldsNoCandidates() {
        XCTAssertTrue(values(["nonsense", ""]).isEmpty,
                      "an unknown lead token has nothing to complete")
    }

    func testTopLevelCommandLeadYieldsNoFurtherCandidates() {
        XCTAssertTrue(values(["list", ""]).isEmpty,
                      "top-level commands take no further arguments")
    }

    // MARK: - Rendering protocol

    func testRenderEmitsTabSeparatedValueAndDescription() {
        let rendered = CLICompletion.render([
            CLICompletion.Candidate(value: "draft", description: "Draft an email"),
            CLICompletion.Candidate(value: "bare", description: nil),
        ])
        let lines = rendered.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "draft\tDraft an email")
        XCTAssertEqual(lines[1], "bare", "a candidate without a description renders as the bare value")
    }

    func testRenderEmptyCandidatesIsEmptyString() {
        XCTAssertEqual(CLICompletion.render([]), "")
    }

    // MARK: - Emitted zsh script (`apple-tools completion zsh`)

    func testZshScriptIsWellFormed() {
        let s = CLICompletion.zshScript
        XCTAssertTrue(s.hasPrefix("#compdef apple-tools"),
                      "must start with the #compdef tag so it autoloads from fpath")
        XCTAssertTrue(s.contains("_apple-tools()"), "defines the completion function")
        XCTAssertTrue(s.contains("apple-tools __complete"),
                      "delegates candidates to the __complete subcommand")
        XCTAssertTrue(s.contains("_describe"), "feeds candidates to _describe")
    }

    /// The dual-mode guard: run the function when autoloaded, else register it —
    /// so one script serves both `fpath` and `source <(...)` installs.
    func testZshScriptIsDualMode() {
        let s = CLICompletion.zshScript
        XCTAssertTrue(s.contains(#"funcstack[1]"# + #"" = "_apple-tools""#) || s.contains("funcstack[1]"),
                      "uses the funcstack guard to detect autoload vs source")
        XCTAssertTrue(s.contains("compdef _apple-tools apple-tools"),
                      "registers via compdef when sourced")
    }

    /// The literal characters `\t` must survive into the script (zsh `$'\t'`),
    /// i.e. the Swift raw string didn't collapse them into an actual tab.
    func testZshScriptPreservesLiteralTabEscape() {
        XCTAssertTrue(CLICompletion.zshScript.contains(##"$'\t'"##),
                      "the zsh tab escape must be literal backslash-t, not a real tab")
        XCTAssertFalse(CLICompletion.zshScript.contains("\t"),
                       "the script itself should contain no real tab characters")
    }

    // MARK: - Coverage: every dispatch action is completable

    /// Mirrors CLIHelpTests — every action a tool dispatches on must surface as
    /// a completion candidate, so a new action can't ship uncompletable.
    func testEveryDispatchActionIsCompletable() {
        for t in tools() {
            guard case .perAction(let policy) = t.accessPolicy else { continue }
            let name = t.definition.name
            let completed = Set(values([name, ""]))
            for action in policy.keys {
                XCTAssertTrue(completed.contains(action),
                              "\(name): action '\(action)' is not offered by completion")
            }
        }
    }
}
