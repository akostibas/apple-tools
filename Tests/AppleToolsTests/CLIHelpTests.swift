import XCTest
@testable import AppleToolsLib

/// Covers the human-facing `apple-tools <tool> --help` renderer (CLIHelp) and,
/// critically, that the CLI-only help metadata never leaks into the LLM tool
/// schema (see ProbeTool.swift / issue #43).
final class CLIHelpTests: XCTestCase {

    private func tools() -> [ProbeTool] { allAppleTools(host: .test()) }
    private func tool(_ name: String) -> ProbeTool {
        tools().first { $0.definition.name == name }!
    }

    /// Extract the indented block for a given action header from full help.
    private func actionBlock(_ help: String, _ action: String) -> String {
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("  \(action) ") || $0 == "  \(action)" }) else { return "" }
        var out: [String] = [lines[start]]
        for line in lines[(start + 1)...] {
            // Next action header (2-space indent, non-space at col 3) ends the block.
            if line.hasPrefix("  ") && !line.hasPrefix("   ") && !line.isEmpty { break }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - The critical guarantee: LLM schema is unchanged

    /// Encoding a converted ToolDefinition must not emit the CLI-only fields.
    /// The LLM sees only {name, description, parameters}, and each property only
    /// {type, description, items}.
    func testCLIMetadataNeverLeaksIntoEncodedSchema() throws {
        let encoder = JSONEncoder()
        for t in tools() {
            let data = try encoder.encode(t.definition)
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(Set(obj.keys), ["name", "description", "parameters"],
                           "\(t.definition.name): top-level schema keys changed")
            XCTAssertNil(obj["cliSummary"], "\(t.definition.name): cliSummary leaked")
            XCTAssertNil(obj["actions"], "\(t.definition.name): actions leaked")

            let params = obj["parameters"] as? [String: Any]
            let props = (params?["properties"] as? [String: Any]) ?? [:]
            for (flag, raw) in props {
                let keys = Set((raw as! [String: Any]).keys)
                XCTAssertTrue(keys.isSubset(of: ["type", "description", "items"]),
                              "\(t.definition.name).\(flag): unexpected schema keys \(keys)")
            }
        }
    }

    /// The verbose LLM description text is still intact after conversion.
    func testLLMDescriptionsPreserved() {
        let email = tool("email").definition
        XCTAssertTrue(email.description.contains("does NOT send"),
                      "email LLM description prose was altered")
        let query = email.parameters?.properties?["query"]
        XCTAssertEqual(query?.description,
                       "Whitespace-separated tokens, all must match across subject, body preview, or sender — full message body is not searched (for search)")
    }

    // MARK: - Grouping by action

    func testFlagsGroupedUnderOwningAction() {
        let help = CLIHelp.render(tool("email").definition)
        let search = actionBlock(help, "search")
        let draft = actionBlock(help, "draft")
        XCTAssertTrue(search.contains("--query"), "query should be under search")
        XCTAssertFalse(search.contains("--body"), "body should not be under search")
        XCTAssertTrue(draft.contains("--body"), "body should be under draft")
        XCTAssertFalse(draft.contains("--query"), "query should not be under draft")
    }

    // MARK: - Terse help, no LLM prose / no (for X) crutch

    func testFlagHelpIsTerseNotLLMProse() {
        let help = CLIHelp.render(tool("email").definition)
        let search = actionBlock(help, "search")
        XCTAssertTrue(search.contains("Tokens matched across subject"),
                      "should show the terse summary")
        XCTAssertFalse(search.contains("Whitespace-separated tokens"),
                       "should not show the verbose LLM prose")
        XCTAssertFalse(help.contains("(for search)"),
                       "the (for X) crutch must not appear in CLI help")
    }

    // MARK: - Required-first + usage line

    func testRequiredFlagFirstAndTaggedWithUsageLine() {
        let draft = actionBlock(CLIHelp.render(tool("email").definition), "draft")
        let lines = draft.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("apple-tools email draft --to") },
                      "draft should show a usage/example line")
        // Match flag rows (trimmed line starts with `--`), not the example line.
        func flagRow(_ flag: String) -> Int {
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--\(flag) ") }!
        }
        let toIdx = flagRow("to")
        let bodyIdx = flagRow("body")
        XCTAssertTrue(lines[toIdx].contains("(required)"), "--to should be tagged required")
        XCTAssertLessThan(toIdx, bodyIdx, "required --to should render before optional --body")
    }

    // MARK: - Booleans render as bare switches

    func testBooleanFlagsRenderWithoutTypePlaceholder() {
        let search = actionBlock(CLIHelp.render(tool("email").definition), "search")
        XCTAssertTrue(search.contains("--exclude_spam "), "boolean should appear")
        XCTAssertFalse(search.contains("--exclude_spam <boolean>"),
                       "boolean flag should be a bare switch, not <boolean>")
    }

    // MARK: - Scoped, single-action help

    func testScopedActionHelpShowsOnlyThatAction() {
        let help = CLIHelp.render(tool("email").definition, action: "draft")
        XCTAssertTrue(help.hasPrefix("email draft —"), "scoped help header")
        XCTAssertTrue(help.contains("--to"), "shows draft's flags")
        XCTAssertFalse(help.contains("--query"), "does not show other actions' flags")
        XCTAssertTrue(help.contains("apple-tools email --help"), "points back to full help")
    }

    func testUnknownScopedActionFallsBackToFullHelp() {
        let help = CLIHelp.render(tool("email").definition, action: "nonsense")
        XCTAssertTrue(help.contains("Actions:"), "unknown action falls back to full help")
        XCTAssertTrue(help.contains("search"), "full help lists all actions")
    }

    // MARK: - Fallback for definitions without action metadata

    func testFlatFallbackForToolsWithoutActionMetadata() {
        let def = ToolDefinition(
            name: "widget",
            description: "A single-action widget.",
            parameters: ParameterSchema(
                type_: "object",
                properties: ["path": PropertySchema(type_: "string", description: "A path")],
                required: ["path"]
            )
        )
        let help = CLIHelp.render(def)
        XCTAssertTrue(help.contains("widget — A single-action widget."))
        XCTAssertTrue(help.contains("--path <string>"), "flat list still renders flags")
        XCTAssertTrue(help.contains("(required)"))
    }

    // MARK: - Coverage: every action a tool dispatches on has help metadata

    /// Mirrors AccessPolicyCoverageTests — a new action can't ship without CLI
    /// help. Every action in a tool's perAction policy must have an ActionHelp.
    func testEveryDispatchActionHasHelpMetadata() {
        for t in tools() {
            guard case .perAction(let policy) = t.accessPolicy else { continue }
            let def = t.definition
            let helpActions = Set((def.actions ?? []).map(\.name))
            XCTAssertFalse(helpActions.isEmpty,
                           "\(def.name): dispatches on action but has no ActionHelp metadata")
            for action in policy.keys {
                XCTAssertTrue(helpActions.contains(action),
                              "\(def.name): action '\(action)' has no ActionHelp entry")
            }
        }
    }

    /// Every flag's `actions` membership must reference a real action.
    func testFlagActionMembershipReferencesRealActions() {
        for t in tools() {
            let def = t.definition
            guard let actions = def.actions else { continue }
            let names = Set(actions.map(\.name))
            for (flag, p) in def.parameters?.properties ?? [:] {
                for owner in p.actions ?? [] {
                    XCTAssertTrue(names.contains(owner),
                                  "\(def.name).\(flag): references unknown action '\(owner)'")
                }
            }
        }
    }
}
