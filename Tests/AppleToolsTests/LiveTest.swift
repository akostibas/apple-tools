import Foundation
import XCTest

/// Gate for tests that touch this Mac's real data. Every such test starts with
/// `LiveTest.reads` (never mutates), `LiveTest.writes` (creates and removes
/// labeled test data, nothing on screen) or `LiveTest.attended` (puts a window
/// or dialog in front of the user), naming the tool actions it exercises.
///
/// The arguments must be string literals: `LiveCoverageTests` reads them out of
/// the source to prove every action has a live test or a stated exemption.
enum LiveTest {
    static let readVar = "APPLE_TOOLS_LIVE_READ"
    static let writeVar = "APPLE_TOOLS_LIVE_WRITE"
    static let attendedVar = "APPLE_TOOLS_LIVE_ATTENDED"
    static let toolsVar = "APPLE_TOOLS_LIVE_TOOLS"

    /// Prefix for everything a write test creates, so leftovers are recognizable.
    static let label = "apple-tools live test"

    static func reads(_ tool: String, _ actions: String...) throws {
        try gate(readVar, tool: tool, hint: "bin/check")
    }

    static func writes(_ tool: String, _ actions: String...) throws {
        try gate(writeVar, tool: tool, hint: "bin/check --slow")
    }

    static func attended(_ tool: String, _ actions: String...) throws {
        try gate(attendedVar, tool: tool, hint: "bin/check --attended")
    }

    static func skipReason(env: [String: String], flag: String, tool: String, hint: String) -> String? {
        guard env[flag] == "1" else { return "live \(tool) tests are opt-in: run \(hint)" }
        if let only = env[toolsVar], !only.isEmpty,
           !only.split(separator: ",").map(String.init).contains(tool) {
            return "\(tool) not selected (\(toolsVar)=\(only))"
        }
        return nil
    }

    private static func gate(_ flag: String, tool: String, hint: String) throws {
        if let reason = skipReason(env: ProcessInfo.processInfo.environment,
                                   flag: flag, tool: tool, hint: hint) {
            throw XCTSkip(reason)
        }
    }
}
