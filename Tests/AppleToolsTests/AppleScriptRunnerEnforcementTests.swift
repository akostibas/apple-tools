import XCTest
@testable import AppleToolsLib

/// Enforces the mutation contract from ADR-032: any source file that calls
/// `AppleScriptRunner.run` or `AppleScriptRunner.runLegacy` with a script
/// containing AppleScript mutation primitives must also include
/// `PHASE: pre-commit` and `PHASE: committed` markers in the script literal.
///
/// Read-only call sites opt out via a `// applescript-runner: read-only`
/// comment within ~5 lines of the call site.
///
/// Heuristic, not a proof. The goal is to catch the realistic miss — a new
/// mutating tool added without markers — without false-flagging genuinely
/// read-only tools.
final class AppleScriptRunnerEnforcementTests: XCTestCase {

    /// AppleScript primitives that indicate a script mutates user-visible state.
    /// Conservative list; expand as new mutation patterns appear in the codebase.
    static let mutationPrimitives: [String] = [
        "make new",
        "send ",
        "delete ",
        " save ",
        "set body of",
        "set name of",
    ]

    static let optOutMarker = "applescript-runner: read-only"
    /// Opt-out for mutating call sites that have no viable post-verify
    /// strategy (e.g., schema-side joins that aren't keyed on a single
    /// recipient handle). Reviewer judgment, not test, polices abuse.
    static let noVerifierMarker = "applescript-runner: no-verifier"

    func testEveryMutatingScriptHasPhaseMarkers() throws {
        let sourceRoot = try Self.locateProbeLibSources()
        let swiftFiles = try Self.swiftFiles(under: sourceRoot)

        var violations: [String] = []

        for fileURL in swiftFiles {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents.components(separatedBy: "\n")
            // Skip the runner itself and its tests — they reference the API
            // for documentation and validation, not as a tool implementation.
            if fileURL.lastPathComponent == "AppleScriptRunner.swift" { continue }

            let scripts = Self.extractScriptLiterals(from: contents, fileLines: lines)
            for script in scripts {
                // Skip string-template fragments — only complete dispatched
                // scripts (containing `tell application`) carry the marker
                // contract. Fragments are interpolated into a parent script
                // that supplies the markers.
                guard script.body.contains("tell application") else { continue }

                // Read-only opt-out short-circuits the check. The opt-out
                // exists precisely to acknowledge "yes, this script contains
                // mutation primitives but they don't affect user-visible
                // state" (e.g. saving an attachment to a temp dir). Reviewer
                // judgment, not test, polices opt-out abuse.
                if Self.optedOut(at: script.lineRange, in: lines) { continue }

                let mutated = Self.mutationPrimitives.first { script.body.contains($0) }
                guard let primitive = mutated else { continue }

                let hasPreCommit = script.body.contains("PHASE: pre-commit")
                let hasCommitted = script.body.contains("PHASE: committed")

                if !hasPreCommit || !hasCommitted {
                    let missing = [hasPreCommit ? nil : "PHASE: pre-commit",
                                   hasCommitted ? nil : "PHASE: committed"]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                    violations.append("\(fileURL.lastPathComponent):\(script.lineRange.lowerBound + 1) " +
                        "mutation primitive '\(primitive)' present but missing markers: \(missing). " +
                        "See ADR-032.")
                    continue
                }

                // Post-verify hook requirement (ADR-032 /): a mutating
                // script must either supply a verifier at its dispatch site
                // (typed runner with `onOutcomeUnknown:`, or a wrapper that
                // accepts a verifier built via `makeVerifyHook(...)`), OR
                // carry an explicit `applescript-runner: no-verifier` opt-out
                // explaining why no verify strategy applies.
                if Self.noVerifierOptOut(at: script.lineRange, in: lines) { continue }
                if !Self.hasPostVerifyHook(near: script.lineRange, in: lines) {
                    violations.append("\(fileURL.lastPathComponent):\(script.lineRange.lowerBound + 1) " +
                        "mutating script must supply a post-verify hook " +
                        "(`onOutcomeUnknown:` on AppleScriptRunner.run, or a verifier built " +
                        "via `makeVerifyHook(...)`). To opt out, add a comment with " +
                        "`applescript-runner: no-verifier` and a one-line reason. See ADR-032 /.")
                }
            }
        }

        XCTAssertTrue(violations.isEmpty,
                      "ADR-032 violations:\n  " + violations.joined(separator: "\n  "))
    }

    /// Does the call-site window around the script literal include a
    /// verifier? Two accepted patterns:
    ///
    /// 1. **Typed runner with hook arg:** `AppleScriptRunner.run...` and
    ///    `onOutcomeUnknown:` both appear in the window. Used by direct
    ///    dispatchers like `EmailIntegration.createDraft`.
    /// 2. **Wrapper + makeVerifyHook:** the window binds a verifier via
    ///    `.makeVerifyHook(...)` and passes it to a per-module wrapper
    ///    (e.g., `IMessageSender.runAppleScript`). The wrapper's signature
    ///    enforces the hook param, so wrapper presence + verifier construction
    ///    is sufficient evidence.
    ///
    /// Window: literal's lines + 30 lines after. Most dispatch sites consume
    /// the literal within a handful of lines; +30 gives headroom for the
    /// `let verifyHook = ...` setup pattern.
    ///
    /// Heuristic, not a proof — but the realistic miss this guards against
    /// (a new mutating tool added without any verifier) produces zero
    /// occurrences of `onOutcomeUnknown:` AND zero `makeVerifyHook(` in the
    /// file, which this catches reliably.
    static func hasPostVerifyHook(near lineRange: ClosedRange<Int>, in lines: [String]) -> Bool {
        let lower = lineRange.lowerBound
        let upper = min(lines.count - 1, lineRange.upperBound + 30)
        guard lower <= upper else { return false }

        var sawTypedRunner = false
        var sawHookArg = false
        var sawVerifierBuild = false
        for i in lower...upper {
            let line = lines[i]
            if line.contains("AppleScriptRunner.run") { sawTypedRunner = true }
            if line.contains("onOutcomeUnknown:")     { sawHookArg = true }
            if line.contains("makeVerifyHook(")       { sawVerifierBuild = true }
        }
        return (sawTypedRunner && sawHookArg) || sawVerifierBuild
    }

    /// Same scan radius as the read-only opt-out, but with the
    /// `no-verifier` marker. Used by mutating sites that legitimately have
    /// no verify strategy (e.g., group-chat sends where chat.db join schema
    /// doesn't key on a single recipient handle).
    static func noVerifierOptOut(at lineRange: ClosedRange<Int>, in lines: [String]) -> Bool {
        let lower = max(0, lineRange.lowerBound - 15)
        let upper = min(lines.count - 1, lineRange.upperBound + 15)
        guard lower <= upper else { return false }
        for i in lower...upper {
            if lines[i].contains(noVerifierMarker) { return true }
        }
        return false
    }

    // MARK: - Helpers

    /// Walk up from this file to find `Sources/AppleToolsLib`.
    private static func locateProbeLibSources() throws -> URL {
        // #file resolves to this test file; walk up until we find Package.swift,
        // then descend to Sources/AppleToolsLib.
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url.appendingPathComponent("Sources/AppleToolsLib")
            }
            url = url.deletingLastPathComponent()
        }
        throw NSError(domain: "EnforcementTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not locate Package.swift"])
    }

    private static func swiftFiles(under dir: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "swift" { out.append(item) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A Swift triple-quoted string literal extracted from a source file,
    /// along with the line range it spans (0-indexed, inclusive).
    struct ScriptLiteral {
        let body: String
        let lineRange: ClosedRange<Int>
    }

    /// Find all `"""..."""` blocks. Crude but adequate for our codebase —
    /// AppleScript is always written this way. Multi-line triple-quoted
    /// blocks with Swift interpolation are preserved verbatim, which is
    /// fine since we're only checking for substrings.
    static func extractScriptLiterals(from source: String, fileLines: [String]) -> [ScriptLiteral] {
        var literals: [ScriptLiteral] = []
        var inLiteral = false
        var startLine = 0
        var buffer = ""

        for (idx, line) in fileLines.enumerated() {
            // Count occurrences of `"""` on this line. Even count = no state
            // change; odd count = toggle.
            let toggleCount = Self.countOccurrences(of: "\"\"\"", in: line)
            if toggleCount == 0 {
                if inLiteral { buffer += line + "\n" }
                continue
            }

            if !inLiteral && toggleCount >= 1 {
                inLiteral = true
                startLine = idx
                buffer = line + "\n"
                if toggleCount >= 2 {
                    // Single-line triple-quoted literal
                    literals.append(ScriptLiteral(body: buffer, lineRange: idx...idx))
                    inLiteral = false
                    buffer = ""
                }
            } else if inLiteral && toggleCount >= 1 {
                buffer += line + "\n"
                literals.append(ScriptLiteral(body: buffer, lineRange: startLine...idx))
                inLiteral = false
                buffer = ""
            }
        }
        return literals
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack
        while let r = search.range(of: needle) {
            count += 1
            search = String(search[r.upperBound...])
        }
        return count
    }

    /// Was the script's call site annotated with `// applescript-runner: read-only`?
    /// Scan ±15 lines around the literal's location to allow the opt-out to
    /// live in the enclosing function's doc comment.
    static func optedOut(at lineRange: ClosedRange<Int>, in lines: [String]) -> Bool {
        let lower = max(0, lineRange.lowerBound - 15)
        let upper = min(lines.count - 1, lineRange.upperBound + 15)
        guard lower <= upper else { return false }
        for i in lower...upper {
            if lines[i].contains(optOutMarker) { return true }
        }
        return false
    }
}
