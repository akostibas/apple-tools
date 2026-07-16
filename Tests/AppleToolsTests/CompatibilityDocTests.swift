import XCTest
@testable import AppleToolsLib

/// Guards the tool-compatibility convention: every registered tool must have a
/// row in `docs/tools/COMPATIBILITY.md`. Tools drift as macOS changes, so the
/// matrix is the record of what's been verified where — a new tool that skips
/// it would silently claim no coverage status at all. See COMPATIBILITY.md.
final class CompatibilityDocTests: XCTestCase {

    func testEveryRegisteredToolHasACompatibilityRow() throws {
        let doc = try compatibilityDocContents()
        let tools = allAppleTools(host: .test())
        XCTAssertFalse(tools.isEmpty)

        for tool in tools {
            let name = tool.definition.name
            // Rows are Markdown table cells: `| <name> | …`. Match the name as
            // the first cell so a substring elsewhere (a note) can't satisfy it.
            let hasRow = doc
                .components(separatedBy: "\n")
                .contains { line in
                    let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    return cells.count > 1 && cells[1] == name
                }
            XCTAssertTrue(hasRow,
                "tool '\(name)' has no row in docs/tools/COMPATIBILITY.md — add one "
                + "(use 'not recorded' for OS/version/date until it's verified, or 'n/a' "
                + "if it has no OS dependency).")
        }
    }

    // MARK: - Helpers

    private func compatibilityDocContents() throws -> String {
        // Walk up from this file to the package root (Package.swift), then
        // descend to the doc — mirrors AppleScriptRunnerEnforcementTests.
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                let doc = url.appendingPathComponent("docs/tools/COMPATIBILITY.md")
                return try String(contentsOf: doc, encoding: .utf8)
            }
            url = url.deletingLastPathComponent()
        }
        throw NSError(domain: "CompatibilityDocTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not locate Package.swift"])
    }
}
