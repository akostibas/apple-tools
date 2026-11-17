import XCTest
@testable import AppleToolsLib

/// Every action a tool declares must be named by a live test (`LiveTest.reads`,
/// `.writes` or `.attended`) or listed in `LiveExemptions` with a reason. Runs in the
/// unit group, so a new action cannot be committed untested by accident.
final class LiveCoverageTests: XCTestCase {

    /// "tool.action", or just "tool" for a tool with no sub-actions.
    static func declaredActions() -> [String: AccessMode] {
        var out: [String: AccessMode] = [:]
        for tool in allAppleTools(host: .test()) {
            let name = tool.definition.name
            switch tool.accessPolicy {
            case .whole(let mode): out[name] = mode
            case .perAction(let map): for (action, mode) in map { out["\(name).\(action)"] = mode }
            }
        }
        return out
    }

    /// Scans the test sources for `LiveTest.reads("tool", "action", ...)` claims.
    static func claims(in source: String) -> (reads: Set<String>, writes: Set<String>) {
        let pattern = #"LiveTest\.(reads|writes|attended)\(\s*((?:"[^"]+"\s*,?\s*)+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var reads = Set<String>(), writes = Set<String>()
        let ns = source as NSString
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let names = ns.substring(with: m.range(at: 2))
                .components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            guard let tool = names.first else { continue }
            let keys = names.count == 1 ? [tool] : names.dropFirst().map { "\(tool).\($0)" }
            if ns.substring(with: m.range(at: 1)) == "reads" { reads.formUnion(keys) } else { writes.formUnion(keys) }
        }
        return (reads, writes)
    }

    static func problems(declared: [String: AccessMode], reads: Set<String>, writes: Set<String>,
                         exempt: [String: String], owed: [String: String]) -> [String] {
        var out: [String] = []
        let covered = reads.union(writes)
        for key in covered.subtracting(declared.keys).sorted() {
            out.append("\(key): a live test names it, but no tool declares it")
        }
        for key in reads.sorted() where declared[key] == .readWrite {
            out.append("\(key): changes data, so it belongs in LiveTest.writes, not the read-only group")
        }
        for (key, why) in exempt.merging(owed, uniquingKeysWith: { a, _ in a }).sorted(by: { $0.key < $1.key }) {
            if declared[key] == nil { out.append("\(key): listed in LiveExemptions, but no tool declares it") }
            if covered.contains(key) { out.append("\(key): has a live test now; remove it from LiveExemptions") }
            if why.trimmingCharacters(in: .whitespaces).isEmpty { out.append("\(key): exemption needs a reason") }
        }
        for key in declared.keys.sorted()
        where !covered.contains(key) && exempt[key] == nil && owed[key] == nil {
            out.append("\(key): no live test. Add one that starts with LiveTest.reads/writes/attended, or list it in LiveExemptions with a reason")
        }
        return out
    }

    func testEveryActionHasALiveTestOrAnExemption() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "LiveCoverageTests.swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let (reads, writes) = Self.claims(in: sources)
        let found = Self.problems(declared: Self.declaredActions(), reads: reads, writes: writes,
                                  exempt: LiveExemptions.exempt, owed: LiveExemptions.owed)
        XCTAssertTrue(found.isEmpty, "\n" + found.joined(separator: "\n"))
    }

    /// Tools named under "What a run leaves behind" in Tests/README.md.
    static func toolsWithLeftoversDocumented(in readme: String) -> Set<String> {
        guard let start = readme.range(of: "## What a run leaves behind") else { return [] }
        let rest = readme[start.upperBound...]
        let section = rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest
        let regex = try! NSRegularExpression(pattern: #"(?m)^- \*\*([a-z_]+):\*\* \S"#)
        let ns = String(section) as NSString
        return Set(regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })
    }

    func testEveryToolWithAWriteTestSaysWhatItLeavesBehind() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "LiveCoverageTests.swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let writers = Set(Self.claims(in: sources).writes.map { $0.components(separatedBy: ".")[0] })
        let readme = try String(contentsOf: dir.deletingLastPathComponent().appendingPathComponent("README.md"), encoding: .utf8)
        let missing = writers.subtracting(Self.toolsWithLeftoversDocumented(in: readme)).sorted()
        XCTAssertTrue(missing.isEmpty, """
            These tools have a write or attended test but no line under "What a run leaves behind" \
            in Tests/README.md: \(missing.joined(separator: ", ")). Add "- **tool:** ..." (say "nothing" if so).
            """)
    }

    func testLeftoverListIsReadFromTheReadme() {
        let found = Self.toolsWithLeftoversDocumented(in: """
            ## What a run leaves behind
            - **notes:** folders.
            - **open_uri:** a window.
            - **blank:**
            ## Adding an action
            - **later:** not in the section.
            """)
        XCTAssertEqual(found, ["notes", "open_uri"])
    }

    func testClaimsAreReadFromSource() {
        let (reads, writes) = Self.claims(in: """
            try LiveTest.reads("notes", "list", "search")
            try LiveTest.writes("screenshot")
            try LiveTest.writes(
                "notes", "create")
            """)
        XCTAssertEqual(reads, ["notes.list", "notes.search"])
        XCTAssertEqual(writes, ["screenshot", "notes.create"])
    }

    func testRuleCatchesEachKindOfGap() {
        let declared: [String: AccessMode] = ["t.read": .read, "t.write": .readWrite, "t.new": .read, "t.owed": .read]
        let found = Self.problems(declared: declared, reads: ["t.read", "t.write", "t.gone", "t.owed"], writes: [],
                                  exempt: ["t.stale": "x"], owed: ["t.owed": "#1"])
        XCTAssertEqual(found.map { $0.components(separatedBy: ":")[0] }.sorted(),
                       ["t.gone", "t.new", "t.owed", "t.stale", "t.write"])
        XCTAssertTrue(Self.problems(declared: declared, reads: ["t.read"], writes: ["t.write"],
                                    exempt: ["t.new": "cannot"], owed: ["t.owed": "#1"]).isEmpty)
    }
}
