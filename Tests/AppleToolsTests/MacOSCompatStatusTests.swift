import XCTest

/// Exercises `bin/macos-compat-status`, the SessionStart hook that warns when
/// the running macOS build has no row in the compatibility matrix.
///
/// The hook's whole value is its signal-to-noise ratio: it must speak up after
/// an OS upgrade and stay silent otherwise. A version that warns every session
/// gets ignored within a week, so "stays quiet" is tested as carefully as
/// "warns".
final class MacOSCompatStatusTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compat-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Walk up to the package root, mirroring CompatibilityDocTests.
    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        throw NSError(domain: "MacOSCompatStatusTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not locate Package.swift"])
    }

    private func currentBuild() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        proc.arguments = ["-buildVersion"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run the hook against a fixture matrix, returning what it printed.
    private func runHook(matrix: String) throws -> String {
        let docPath = dir.appendingPathComponent("matrix-\(UUID().uuidString).md").path
        try matrix.write(toFile: docPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = try packageRoot().appendingPathComponent("bin/macos-compat-status")
        proc.arguments = [docPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0, "the hook must never exit non-zero at session start")
        return String(decoding: data, as: UTF8.self)
    }

    private func matrix(rows: [String]) -> String {
        ([
            "| Tool | apple-tools | Commit | macOS | Verified | Notes |",
            "|------|-------------|--------|-------|----------|-------|",
        ] + rows).joined(separator: "\n") + "\n"
    }

    func testWarnsWhenRecordedOnADifferentBuild() throws {
        let out = try runHook(matrix: matrix(rows: [
            "| media | 0.26.1 | abc123 | 26.0 (25A354) | 2026-06-01 | fine |",
            "| photos | 0.26.1 | abc123 | 26.0 (25A354) | 2026-06-01 | fine |",
        ]))
        XCTAssertTrue(out.contains("media"), "a tool recorded on an older build must be named")
        XCTAssertTrue(out.contains("photos"))
        XCTAssertTrue(out.contains(currentBuild()), "the warning should state the build actually running")
    }

    func testSilentWhenEveryToolIsRecordedOnThisBuild() throws {
        let out = try runHook(matrix: matrix(rows: [
            "| media | 0.27.0 | abc123 | 27.0 (\(currentBuild())) | 2026-09-15 | verified |",
        ]))
        XCTAssertTrue(out.isEmpty, "steady state must be silent, got: \(out)")
    }

    /// `n/a` means the tool has no OS dependency, so it can never go stale.
    func testToolsMarkedNotApplicableNeverTrigger() throws {
        let out = try runHook(matrix: matrix(rows: [
            "| echo | n/a | n/a | n/a | n/a | no OS interaction |",
        ]))
        XCTAssertTrue(out.isEmpty, "an n/a tool must not warn, got: \(out)")
    }

    /// The alarm-fatigue guard. `open_uri` is deliberately never exercised (it
    /// opens a real URI), so if an unrecorded row could trigger the hook on its
    /// own it would fire every single session and stop being read.
    func testNeverRecordedToolDoesNotTriggerOnItsOwn() throws {
        let out = try runHook(matrix: matrix(rows: [
            "| open_uri | — | — | not recorded | — | side-effecting |",
        ]))
        XCTAssertTrue(out.isEmpty, "'not recorded' alone must stay silent, got: \(out)")
    }

    /// ...but it should be mentioned once something else has already triggered.
    func testNeverRecordedToolIsListedWhenTheHookFiresAnyway() throws {
        let out = try runHook(matrix: matrix(rows: [
            "| media | 0.26.1 | abc123 | 26.0 (25A354) | 2026-06-01 | fine |",
            "| open_uri | — | — | not recorded | — | side-effecting |",
        ]))
        XCTAssertTrue(out.contains("open_uri"), "worth surfacing alongside a real staleness warning")
    }

    func testUnreadableMatrixIsSilentRatherThanNoisy() throws {
        let proc = Process()
        proc.executableURL = try packageRoot().appendingPathComponent("bin/macos-compat-status")
        proc.arguments = ["/nonexistent/matrix.md"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertTrue(data.isEmpty, "a missing matrix must never disrupt session start")
    }
}
