import Foundation
import XCTest

/// Remembers real items a read-only test found on this Mac, so a later run can
/// tell "the store moved" from "this Mac never had any".
///
/// A lookup that comes back empty proves nothing on its own. One that used to
/// find a remembered item and now finds none of them is the alarm.
struct LiveTargets {
    /// How to settle "none, or broken?" when there is nothing remembered.
    enum Settle {
        case slowTest(tool: String)
        case lookIn(app: String)

        var advice: String {
            switch self {
            case .slowTest(let tool): return "run `make test-slow TOOL=\(tool)`, which creates an item and reads it back"
            case .lookIn(let app): return "open \(app) and see whether it shows any; nothing can be planted there to test with"
            }
        }
    }

    enum Outcome: Equatable {
        case ok(found: Int, of: Int)
        case nothingToCheck(String)
        case lost(String)
    }

    static let pathVar = "APPLE_TOOLS_LIVE_TARGETS"
    static let refreshVar = "APPLE_TOOLS_LIVE_REFRESH"
    static let keep = 5

    let file: URL
    let refresh: Bool
    let stamp: String

    /// Machine state, not repo state: lives outside the checkout so every worktree shares it.
    static var standard: LiveTargets {
        let env = ProcessInfo.processInfo.environment
        let file = env[pathVar].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/apple-tools/live-targets.json")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return LiveTargets(file: file, refresh: env[refreshVar] == "1", stamp: "\(day), macOS \(os)")
    }

    private struct Entry: Codable {
        var values: [String]
        var recorded: String
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
    }

    /// `discover` lists candidate items; `find` says whether one can still be found.
    func evaluate(_ key: String, settle: Settle,
                  discover: () throws -> [String],
                  find: (String) throws -> Bool) throws -> Outcome {
        var all = load()
        var firstRun = false
        if refresh || all[key] == nil {
            let found = Array(try discover().filter { !$0.isEmpty }.prefix(Self.keep))
            guard !found.isEmpty else {
                // Keep the old memory on a refresh that finds nothing: that is the collapse.
                if let old = all[key] {
                    return .lost("\(key): found \(old.values.count) item(s) on \(old.recorded), and none now.")
                }
                return .nothingToCheck("\(key): nothing found, so either this Mac has none or the lookup is broken. To settle it: \(settle.advice).")
            }
            all[key] = Entry(values: found, recorded: stamp)
            try save(all)
            firstRun = true
        }
        let entry = all[key]!
        let hits = try entry.values.filter(find).count
        if hits > 0 { return .ok(found: hits, of: entry.values.count) }
        if firstRun {
            return .lost("\(key): listed \(entry.values.count) item(s) but could not find any of them again.")
        }
        return .lost("\(key): found \(entry.values.count) item(s) on \(entry.recorded), and none of them now. "
            + "If you removed them yourself, re-run with `make test-refresh`; otherwise the store has likely moved.")
    }

    /// Test-facing wrapper: skips when there is nothing to check, fails on a loss.
    static func check(_ key: String, settle: Settle,
                      discover: () throws -> [String],
                      find: (String) throws -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        switch try standard.evaluate(key, settle: settle, discover: discover, find: find) {
        case .ok: return
        case .nothingToCheck(let why): throw XCTSkip(why)
        case .lost(let why): XCTFail(why, file: file, line: line)
        }
    }
}
