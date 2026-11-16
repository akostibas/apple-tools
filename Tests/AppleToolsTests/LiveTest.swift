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
        try gate(readVar, tool: tool, hint: "make test")
    }

    static func writes(_ tool: String, _ actions: String...) throws {
        try gate(writeVar, tool: tool, hint: "make test-slow")
    }

    static func attended(_ tool: String, _ actions: String...) throws {
        try gate(attendedVar, tool: tool, hint: "make test-attended")
    }

    /// Scripting a closed app launches it in front of the user, so tests that script one wait until it is open.
    static func requireRunning(_ app: String) throws {
        // pgrep, not NSRunningApplication: its list goes stale in a process with no app run loop.
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", app]
        pgrep.standardOutput = FileHandle.nullDevice
        try pgrep.run()
        pgrep.waitUntilExit()
        try XCTSkipIf(pgrep.terminationStatus != 0,
                      "\(app) is closed, and this test would open it. Open \(app) and re-run.")
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
