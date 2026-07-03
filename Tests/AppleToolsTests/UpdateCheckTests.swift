import XCTest
@testable import AppleToolsLib

final class UpdateCheckTests: XCTestCase {

    // A unique, throwaway cache file per test so runs never collide.
    private func tempCacheFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tools-updatecheck-\(UUID().uuidString)")
            .appendingPathComponent("last-update-check")
    }

    override func tearDown() {
        // Nothing global is mutated (all seams are per-call params), but clean
        // up any stray temp dirs this test class created.
        super.tearDown()
    }

    // MARK: - Version comparison

    func testIsBehindComparesSemverAcrossVersionShapes() {
        XCTAssertTrue(UpdateCheck.isBehind(installed: "apple-tools/0.7.1", latest: "v0.8.0"))
        XCTAssertTrue(UpdateCheck.isBehind(installed: "apple-tools/0.7.1", latest: "v0.7.2"))
        XCTAssertTrue(UpdateCheck.isBehind(installed: "apple-tools/0.9.9", latest: "v1.0.0"))
    }

    func testIsNotBehindWhenEqualOrAhead() {
        XCTAssertFalse(UpdateCheck.isBehind(installed: "apple-tools/0.7.1", latest: "v0.7.1"))
        XCTAssertFalse(UpdateCheck.isBehind(installed: "apple-tools/0.8.0", latest: "v0.7.9"))
        XCTAssertFalse(UpdateCheck.isBehind(installed: "apple-tools/1.0.0", latest: "v0.9.9"))
    }

    func testUnparseableVersionNeverNudges() {
        XCTAssertFalse(UpdateCheck.isBehind(installed: "apple-tools/0.7.1", latest: "garbage"))
        XCTAssertFalse(UpdateCheck.isBehind(installed: "nonsense", latest: "v0.8.0"))
    }

    func testSemverIgnoresGitDescribeSuffix() {
        // e.g. a `git describe` tag on a consumer's checkout.
        XCTAssertFalse(UpdateCheck.isBehind(installed: "apple-tools/0.8.0", latest: "v0.8.0-2-gabc123"))
        XCTAssertTrue(UpdateCheck.isBehind(installed: "apple-tools/0.7.1", latest: "v0.8.0-rc1"))
    }

    // MARK: - Nudge formatting

    func testNudgeLineContainsBothVersionsAndReadmeURL() {
        let line = UpdateCheck.nudgeLine(installed: "apple-tools/0.7.1", latest: "v0.8.0")
        XCTAssertTrue(line.contains("v0.7.1 installed"), line)
        XCTAssertTrue(line.contains("v0.8.0 available"), line)
        XCTAssertTrue(line.contains(UpdateCheck.readmeURL), line)
    }

    // MARK: - Tags-API parsing (max semver, not first)

    private func tagsJSON(_ names: [String]) -> Data {
        let arr = names.map { ["name": $0] }
        return try! JSONSerialization.data(withJSONObject: arr)
    }

    func testHighestSemverTagPicksMaxNotFirst() {
        // GitHub's tags API does not guarantee semver order.
        let data = tagsJSON(["v0.7.0", "v0.10.0", "v0.7.1", "v0.9.9"])
        XCTAssertEqual(UpdateCheck.highestSemverTag(fromTagsJSON: data), "v0.10.0")
    }

    func testHighestSemverTagIgnoresNonSemverTags() {
        let data = tagsJSON(["nightly", "latest", "v0.8.0", "release-candidate"])
        XCTAssertEqual(UpdateCheck.highestSemverTag(fromTagsJSON: data), "v0.8.0")
    }

    func testHighestSemverTagNilWhenNoSemverTags() {
        XCTAssertNil(UpdateCheck.highestSemverTag(fromTagsJSON: tagsJSON(["nightly", "latest"])))
        XCTAssertNil(UpdateCheck.highestSemverTag(fromTagsJSON: tagsJSON([])))
    }

    func testHighestSemverTagNilOnMalformedJSON() {
        XCTAssertNil(UpdateCheck.highestSemverTag(fromTagsJSON: Data("not json".utf8)))
        // Wrong shape: releases/latest returns an object, not an array.
        XCTAssertNil(UpdateCheck.highestSemverTag(fromTagsJSON: Data(#"{"tag_name":"v0.8.0"}"#.utf8)))
    }

    // MARK: - Orchestration: acceptance criteria

    /// Behind → exactly one fetch, one nudge on stderr.
    func testBehindEmitsNudgeAndFetchesOnce() {
        let cache = tempCacheFile()
        var fetchCount = 0
        var emitted: [String] = []

        UpdateCheck.maybeNudge(
            installedVersion: "apple-tools/0.7.1",
            environment: [:],
            cacheFile: cache,
            now: Date(),
            fetch: { fetchCount += 1; return "v0.8.0" },
            emit: { emitted.append($0) }
        )

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted[0].contains("v0.8.0 available"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "timestamp written")
    }

    /// Up to date → fetch happens but no nudge.
    func testUpToDateEmitsNothing() {
        let cache = tempCacheFile()
        var emitted: [String] = []

        UpdateCheck.maybeNudge(
            installedVersion: "apple-tools/0.8.0",
            environment: [:],
            cacheFile: cache,
            now: Date(),
            fetch: { "v0.8.0" },
            emit: { emitted.append($0) }
        )

        XCTAssertTrue(emitted.isEmpty)
    }

    /// Within the weekly window → no fetch, no nudge.
    func testWithinWindowMakesNoNetworkCall() {
        let cache = tempCacheFile()
        let now = Date()
        // Seed a recent check (1 hour ago).
        UpdateCheck.writeCheck(cacheFile: cache, now: now.addingTimeInterval(-3600))

        var fetchCount = 0
        UpdateCheck.maybeNudge(
            installedVersion: "apple-tools/0.7.1",
            environment: [:],
            cacheFile: cache,
            now: now,
            fetch: { fetchCount += 1; return "v0.8.0" },
            emit: { _ in }
        )

        XCTAssertEqual(fetchCount, 0, "no network call within the weekly window")
    }

    /// Past the weekly window → fetch happens again.
    func testPastWindowChecksAgain() {
        let cache = tempCacheFile()
        let now = Date()
        // Seed a check 8 days ago.
        UpdateCheck.writeCheck(cacheFile: cache, now: now.addingTimeInterval(-8 * 24 * 3600))

        var fetchCount = 0
        UpdateCheck.maybeNudge(
            installedVersion: "apple-tools/0.7.1",
            environment: [:],
            cacheFile: cache,
            now: now,
            fetch: { fetchCount += 1; return "v0.8.0" },
            emit: { _ in }
        )

        XCTAssertEqual(fetchCount, 1)
    }

    /// Offline / fetch failure → no output, and the window is still opened so a
    /// blip can't cause a per-invocation retry storm.
    func testFetchFailureIsSilentAndOpensWindow() {
        let cache = tempCacheFile()
        var emitted: [String] = []

        UpdateCheck.maybeNudge(
            installedVersion: "apple-tools/0.7.1",
            environment: [:],
            cacheFile: cache,
            now: Date(),
            fetch: { nil },              // simulate offline
            emit: { emitted.append($0) }
        )

        XCTAssertTrue(emitted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path),
                      "timestamp written even on fetch failure")
    }

    /// Opt-out env var fully disables the check (no fetch, no nudge, no write).
    func testOptOutDisablesEverything() {
        let cache = tempCacheFile()
        var fetchCount = 0
        var emitted: [String] = []

        UpdateCheck.maybeNudge(
            installedVersion: "apple-tools/0.7.1",
            environment: [UpdateCheck.optOutEnvVar: "1"],
            cacheFile: cache,
            now: Date(),
            fetch: { fetchCount += 1; return "v0.8.0" },
            emit: { emitted.append($0) }
        )

        XCTAssertEqual(fetchCount, 0)
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}
