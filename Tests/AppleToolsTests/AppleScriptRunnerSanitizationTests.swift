import XCTest
@testable import AppleToolsLib

/// Tests for `AppleScriptRunner.sanitizeEnvironment` — the
/// last-line-of-defense layer that callers don't see but that prevents
/// POSIX-level surprises at `execve` time.
///
/// Background: POSIX env values are C strings; embedded `\0`
/// silently truncates at execve, and total argv+envp size is bounded by
/// `ARG_MAX`. Sanitizing here gives a clear contract instead of cryptic
/// kernel errors.
final class AppleScriptRunnerSanitizationTests: XCTestCase {

    func testNULBytesAreStripped() {
        let env = ["KEY": "before\u{0000}after"]
        guard case .ok(let cleaned) = AppleScriptRunner.sanitizeEnvironment(env, tool: "test") else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(cleaned["KEY"], "beforeafter",
            "NUL bytes must be stripped — POSIX env can't carry \\0")
    }

    func testMultipleNULsAcrossKeys() {
        let env = [
            "A": "x\u{0000}y\u{0000}z",
            "B": "no nuls here",
            "C": "\u{0000}leading",
        ]
        guard case .ok(let cleaned) = AppleScriptRunner.sanitizeEnvironment(env, tool: "test") else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(cleaned["A"], "xyz")
        XCTAssertEqual(cleaned["B"], "no nuls here")
        XCTAssertEqual(cleaned["C"], "leading")
    }

    func testValuesWithoutNULsPassThroughUnchanged() {
        let env = [
            "PLAIN": "hello world",
            "NEWLINES": "alpha\nbeta\n\ngamma",
            "EMOJI": "hi 👨‍👩‍👧‍👦",
            "QUOTES": #"she said "x""#,
        ]
        guard case .ok(let cleaned) = AppleScriptRunner.sanitizeEnvironment(env, tool: "test") else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(cleaned, env)
    }

    func testSizeCapAccepts100KB() {
        let env = ["BODY": String(repeating: "A", count: 100_000)]
        guard case .ok = AppleScriptRunner.sanitizeEnvironment(env, tool: "test") else {
            return XCTFail("100KB is well within the cap; expected .ok")
        }
    }

    func testSizeCapRejectsOversizedPayload() {
        // Cap is 512KB. One value at 600KB must trip it.
        let env = ["BODY": String(repeating: "A", count: 600_000)]
        guard case .tooLarge(let bytes) = AppleScriptRunner.sanitizeEnvironment(env, tool: "test") else {
            return XCTFail("expected .tooLarge")
        }
        XCTAssertEqual(bytes, 600_000)
    }

    func testSizeCapSumsAcrossKeys() {
        // No single value over the cap, but their sum is. Mirrors a real
        // payload that spreads body+subject+attachments across multiple
        // env keys.
        let chunk = String(repeating: "A", count: 300_000)
        let env = ["A": chunk, "B": chunk]
        guard case .tooLarge(let bytes) = AppleScriptRunner.sanitizeEnvironment(env, tool: "test") else {
            return XCTFail("expected .tooLarge — summed payload exceeds cap")
        }
        XCTAssertEqual(bytes, 600_000)
    }

    func testEmptyEnvIsOK() {
        guard case .ok(let cleaned) = AppleScriptRunner.sanitizeEnvironment([:], tool: "test") else {
            return XCTFail("expected .ok")
        }
        XCTAssertTrue(cleaned.isEmpty)
    }

    // MARK: - End-to-end UTF-8 round-trip

    /// Actually spawn osascript and round-trip a UTF-8 payload through
    /// the env. Unit tests with stubbed `runAppleScript` can't catch
    /// encoding bugs in the AppleScript-side fetch — only a real
    /// osascript exec does.
    ///
    /// Regression for: env values read via `system attribute` were
    /// decoded as MacRoman, mangling em-dash, emoji, and non-Latin text
    /// when delivered through iMessage / Mail / Notes. Switched to
    /// `do shell script "printenv X"` which returns UTF-8.
    func testRunRoundTripsUTF8Payload() {
        let payload = "em-dash — emoji 👋 RTL مرحبا"
        let script = """
        set theValue to do shell script "printenv APPLE_TOOLS_TEST_PAYLOAD"
        return theValue
        """
        let result = AppleScriptRunner.run(
            source: script,
            tool: "test-utf8",
            environment: ["APPLE_TOOLS_TEST_PAYLOAD": payload]
        )
        XCTAssertEqual(result.outcome, .success, "osascript should succeed: stderr=\(result.stderr)")
        // osascript appends a trailing newline; trim it.
        let echoed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(echoed, payload,
            "UTF-8 payload must round-trip unchanged through env + printenv")
    }
}
