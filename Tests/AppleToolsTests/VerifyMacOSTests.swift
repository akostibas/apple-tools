import XCTest

/// Exercises `bin/verify-macos`'s decision ladder against a stub binary, so the
/// comparison logic is pinned without depending on this machine's real data.
///
/// The ladder is the whole product: it decides whether a count is a genuine
/// answer or evidence that a data store moved under us. Getting it wrong in
/// either direction is costly — a missed collapse is the bug we shipped on
/// macOS 27, and a false alarm on ordinary drift trains everyone to ignore it.
final class VerifyMacOSTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verify-macos-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        throw NSError(domain: "VerifyMacOSTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not locate Package.swift"])
    }

    /// A stand-in for apple-tools that always prints the same count.
    private func makeStub(returning count: Int) throws -> String {
        let path = dir.appendingPathComponent("stub-\(count)").path
        try "#!/bin/sh\necho '{\"count\": \(count)}'\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeConfig(baseline: Int?, minPercent: Int = 50) throws -> String {
        let path = dir.appendingPathComponent("config-\(UUID().uuidString).json").path
        let baselineJSON = baseline.map(String.init) ?? "null"
        try """
        {
          "min_percent": \(minPercent),
          "checks": [
            {"id": "probe", "describe": "stub", "args": ["whatever"],
             "count": ".count", "baseline": \(baselineJSON)}
          ]
        }
        """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    private func run(count: Int, baseline: Int?, minPercent: Int = 50) throws -> (out: String, code: Int32) {
        let proc = Process()
        proc.executableURL = try packageRoot().appendingPathComponent("bin/verify-macos")
        proc.arguments = [
            "--config", try makeConfig(baseline: baseline, minPercent: minPercent),
            "--binary", try makeStub(returning: count),
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), proc.terminationStatus)
    }

    /// The macOS 27 failure in miniature: it used to find things, now it finds
    /// nothing, and the tool still exits 0. This must never pass silently.
    func testCollapseToZeroIsRaised() throws {
        let result = try run(count: 0, baseline: 5)
        XCTAssertTrue(result.out.contains("returned 0, baseline was 5"))
        XCTAssertEqual(result.code, 1, "a collapse must make the suite fail")
    }

    /// Zero is raised however forgiving the tolerance — you cannot configure
    /// your way into ignoring a store that stopped answering.
    func testCollapseToZeroIsRaisedEvenWithATinyThreshold() throws {
        let result = try run(count: 0, baseline: 5, minPercent: 1)
        XCTAssertEqual(result.code, 1)
    }

    func testCountAtOrAboveBaselineIsFine() throws {
        let result = try run(count: 12, baseline: 10)
        XCTAssertTrue(result.out.contains("✓"))
        XCTAssertEqual(result.code, 0)
    }

    /// Ordinary drift — deleted files, people leaving a photo library — must not
    /// fire, or the report becomes noise nobody reads.
    func testSmallDecreaseIsNotRaised() throws {
        let result = try run(count: 95, baseline: 100)
        XCTAssertEqual(result.code, 0, "a 5% dip is normal churn, not a breakage")
    }

    func testDecreasePastTheThresholdIsRaised() throws {
        let result = try run(count: 20, baseline: 100)
        XCTAssertTrue(result.out.contains("under 50%"))
        XCTAssertEqual(result.code, 1)
    }

    /// A tool whose output shape changed is a breakage too, not a zero.
    func testUnreadableCountIsRaisedRatherThanTreatedAsZero() throws {
        let proc = Process()
        proc.executableURL = try packageRoot().appendingPathComponent("bin/verify-macos")
        let cfg = dir.appendingPathComponent("shape.json").path
        try """
        {"checks": [{"id": "probe", "args": ["x"], "count": ".gone", "baseline": 5}]}
        """.write(toFile: cfg, atomically: true, encoding: .utf8)
        proc.arguments = ["--config", cfg, "--binary", try makeStub(returning: 5)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()

        XCTAssertTrue(out.contains("may have changed shape"))
        XCTAssertEqual(proc.terminationStatus, 1)
    }

    /// With no baseline there is nothing to compare against, so it reports the
    /// count and waits for a human rather than inventing a verdict.
    func testMissingBaselineReportsWithoutFailing() throws {
        let result = try run(count: 7, baseline: nil)
        XCTAssertTrue(result.out.contains("no baseline yet"))
        XCTAssertEqual(result.code, 0)
    }
}
