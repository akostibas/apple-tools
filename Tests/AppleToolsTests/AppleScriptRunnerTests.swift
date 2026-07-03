import XCTest
@testable import AppleToolsLib

final class AppleScriptRunnerTests: XCTestCase {

    func testTrivialSuccess() {
        let r = AppleScriptRunner.run(source: "return \"hello\"", tool: "test")
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.killed)
        XCTAssertNil(r.lastPhase)
        XCTAssertNil(r.committedID)
    }

    func testLargeStdoutDoesNotDeadlock() {
        // A result larger than the 64KB pipe buffer must not deadlock
        // waitUntilExit() (osascript blocks writing until someone reads).
        // 16 chars doubled 13 times = 131,072 chars.
        let source = """
        set s to "0123456789abcdef"
        repeat 13 times
            set s to s & s
        end repeat
        return s
        """
        let r = AppleScriptRunner.run(source: source, tool: "test", deadline: 20)
        XCTAssertEqual(r.outcome, .success)
        XCTAssertFalse(r.killed, "large output must complete, not hit the deadline")
        XCTAssertGreaterThanOrEqual(
            r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count, 131_072,
            "stdout must be complete, not truncated at the pipe buffer"
        )
    }

    func testNonZeroExitIsFailed() {
        // `error number -2700` causes osascript to exit non-zero.
        let r = AppleScriptRunner.run(source: "error \"boom\" number -2700", tool: "test")
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertFalse(r.killed)
        XCTAssertNotNil(r.errorDetail)
    }

    func testPhaseMarkersTracked() {
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        log "PHASE: committed id=abc-123"
        return "done"
        """
        let r = AppleScriptRunner.run(source: script, tool: "test")
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.lastPhase, "committed id=abc-123")
        XCTAssertEqual(r.committedID, "abc-123")
    }

    func testTimeoutBeforePhaseIsFailed() {
        let r = AppleScriptRunner.run(source: "delay 10\nreturn \"never\"", tool: "test", deadline: 0.5)
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertTrue(r.killed)
        XCTAssertNil(r.lastPhase)
    }

    func testTimeoutInPreCommitIsOutcomeUnknown() {
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        delay 10
        log "PHASE: committed id=never"
        """
        let r = AppleScriptRunner.run(source: script, tool: "test", deadline: 0.8)
        XCTAssertEqual(r.outcome, .outcomeUnknown)
        XCTAssertTrue(r.killed)
        XCTAssertEqual(r.lastPhase, "pre-commit")
    }

    func testCommittedWithoutIdStillSuccessIfKilledLate() {
        // A script that emits committed and then would have exited cleanly,
        // but is killed during the brief window after commit. Side effect
        // already happened — should classify as success, not outcome_unknown.
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        log "PHASE: committed"
        delay 10
        """
        let r = AppleScriptRunner.run(source: script, tool: "test", deadline: 0.5)
        XCTAssertEqual(r.outcome, .success)
        XCTAssertTrue(r.killed)
        XCTAssertEqual(r.lastPhase, "committed")
    }

    func testTimeoutInPrepareIsFailed() {
        let script = """
        log "PHASE: prepare"
        delay 10
        log "PHASE: pre-commit"
        """
        let r = AppleScriptRunner.run(source: script, tool: "test", deadline: 0.5)
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertTrue(r.killed)
        XCTAssertEqual(r.lastPhase, "prepare")
    }

    func testLegacyAdapterSuccess() {
        let (out, err) = AppleScriptRunner.runLegacy(source: "return \"ok\"", tool: "test")
        XCTAssertEqual(out, "ok")
        XCTAssertNil(err)
    }

    func testLegacyAdapterError() {
        let (out, err) = AppleScriptRunner.runLegacy(source: "error \"boom\" number -2700", tool: "test")
        XCTAssertEqual(out, "")
        XCTAssertNotNil(err)
    }

    func testStderrCaptured() {
        let script = """
        log "warning: something noisy"
        return "ok"
        """
        let r = AppleScriptRunner.run(source: script, tool: "test")
        XCTAssertEqual(r.outcome, .success)
        XCTAssertTrue(r.stderr.contains("warning: something noisy"), "stderr should contain log line; got: \(r.stderr)")
    }

    // MARK: - Post-verify hook ( / ADR-032)

    /// Verifier is NOT invoked when outcome is .success — no ambiguity to resolve.
    func testVerifyHookNotInvokedOnSuccess() {
        var invoked = false
        let r = AppleScriptRunner.run(
            source: "return \"ok\"",
            tool: "test",
            onOutcomeUnknown: {
                invoked = true
                return .confirmed(id: "should-not-appear")
            }
        )
        XCTAssertEqual(r.outcome, .success)
        XCTAssertFalse(invoked, "verifier must only run when outcome is outcome_unknown")
        XCTAssertNil(r.committedID, "committedID must not be set from verifier when not invoked")
    }

    /// Verifier is NOT invoked when outcome is .failed (timeout before pre-commit).
    func testVerifyHookNotInvokedOnFailed() {
        var invoked = false
        let r = AppleScriptRunner.run(
            source: "delay 10",
            tool: "test",
            deadline: 0.3,
            onOutcomeUnknown: {
                invoked = true
                return .confirmed(id: nil)
            }
        )
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertFalse(invoked)
    }

    /// SIGKILL during pre-commit + verifier returns .confirmed(id) → outcome
    /// upgrades to .success and committedID picks up the verifier-supplied id.
    func testVerifyConfirmedUpgradesToSuccess() {
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        delay 10
        """
        let r = AppleScriptRunner.run(
            source: script,
            tool: "test",
            deadline: 0.5,
            onOutcomeUnknown: { .confirmed(id: "draft-abc") }
        )
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.committedID, "draft-abc")
        XCTAssertTrue(r.killed)
    }

    /// SIGKILL during pre-commit + verifier returns .absent → outcome upgrades
    /// to .failed (safe to retry — the side effect definitively did not happen).
    func testVerifyAbsentUpgradesToFailed() {
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        delay 10
        """
        let r = AppleScriptRunner.run(
            source: script,
            tool: "test",
            deadline: 0.5,
            onOutcomeUnknown: { .absent }
        )
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertTrue(r.killed)
    }

    /// Verifier returns .inconclusive → outcome stays .outcomeUnknown.
    func testVerifyInconclusiveLeavesOutcomeUnknown() {
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        delay 10
        """
        let r = AppleScriptRunner.run(
            source: script,
            tool: "test",
            deadline: 0.5,
            onOutcomeUnknown: { .inconclusive }
        )
        XCTAssertEqual(r.outcome, .outcomeUnknown)
    }

    // MARK: - External cancel registry

    /// External cancel SIGKILLs a running subprocess within ~1s and classifies
    /// the outcome as outcome_unknown (no committed marker observed).
    func testExternalCancelKillsAndClassifiesUnknown() {
        let id = "test-cancel-\(UUID().uuidString)"
        let resultLock = NSLock()
        var result: AppleScriptRunner.RunResult? = nil

        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // PHASE: pre-commit is reached before the delay, so cancel arrives
            // while the script is "mid-mutation."
            let r = AppleScriptRunner.run(
                source: """
                log "PHASE: prepare"
                log "PHASE: pre-commit"
                delay 30
                """,
                tool: "cancel-test",
                invocationID: id
            )
            resultLock.lock(); result = r; resultLock.unlock()
            started.signal()
        }

        // Wait for the subprocess to actually register (read loop sees the
        // pre-commit phase emitted to stderr — registry write happens before
        // the script starts, so polling isActive is enough).
        let deadline = Date().addingTimeInterval(3.0)
        while !AppleScriptRunner.isActive(invocationID: id) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(AppleScriptRunner.isActive(invocationID: id),
            "subprocess should register before we cancel")

        let cancelStart = Date()
        XCTAssertTrue(AppleScriptRunner.cancel(invocationID: id))

        XCTAssertEqual(started.wait(timeout: .now() + 2.0), .success,
            "cancel must land within 1s, run() must return within 2s of cancel")
        let killElapsed = Date().timeIntervalSince(cancelStart)
        XCTAssertLessThan(killElapsed, 1.0,
            "SIGKILL → run() return should be under 1s (was \(killElapsed)s)")

        resultLock.lock(); let r = result; resultLock.unlock()
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.outcome, .outcomeUnknown,
            "external cancel mid-script classifies as outcome_unknown")
        XCTAssertTrue(r?.killed ?? false)
        XCTAssertFalse(AppleScriptRunner.isActive(invocationID: id),
            "registry must be cleaned up after run() returns")
    }

    /// Cancelling after `PHASE: committed` was emitted still classifies as
    /// success — the side effect already landed.
    func testExternalCancelAfterCommittedIsSuccess() {
        let id = "test-cancel-committed-\(UUID().uuidString)"
        let done = DispatchSemaphore(value: 0)
        var result: AppleScriptRunner.RunResult? = nil
        let lock = NSLock()

        DispatchQueue.global().async {
            let r = AppleScriptRunner.run(
                source: """
                log "PHASE: prepare"
                log "PHASE: pre-commit"
                log "PHASE: committed id=ok-123"
                delay 30
                """,
                tool: "cancel-test",
                invocationID: id
            )
            lock.lock(); result = r; lock.unlock()
            done.signal()
        }

        // Give the script time to emit the committed marker.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(AppleScriptRunner.cancel(invocationID: id))
        XCTAssertEqual(done.wait(timeout: .now() + 2.0), .success)

        lock.lock(); let r = result; lock.unlock()
        XCTAssertEqual(r?.outcome, .success)
        XCTAssertEqual(r?.committedID, "ok-123")
        XCTAssertTrue(r?.killed ?? false)
    }

    /// Cancel for an unknown id is a safe no-op.
    func testExternalCancelUnknownIDIsNoop() {
        XCTAssertFalse(AppleScriptRunner.cancel(invocationID: "no-such-invocation"))
    }

    /// Ambient invocation ID: when `run()` is called without an
    /// explicit invocationID inside a `$ambientInvocationID.withValue` scope,
    /// it falls back to the ambient value and registers for external cancel.
    /// This is what lets the idempotency cache bind the ID once per
    /// invocation without each tool integration plumbing it through.
    func testAmbientInvocationIDIsHonored() async {
        let id = "ambient-\(UUID().uuidString)"

        let runTask = Task.detached {
            return AppleScriptRunner.$ambientInvocationID.withValue(id) {
                return AppleScriptRunner.run(
                    source: """
                    log "PHASE: prepare"
                    log "PHASE: pre-commit"
                    delay 30
                    """,
                    tool: "ambient-test"
                    // no explicit invocationID — should pick up the ambient
                )
            }
        }

        let deadline = Date().addingTimeInterval(3.0)
        while !AppleScriptRunner.isActive(invocationID: id) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(AppleScriptRunner.isActive(invocationID: id),
            "subprocess should register under the ambient ID")

        XCTAssertTrue(AppleScriptRunner.cancel(invocationID: id),
            "external cancel via the ambient ID should hit the registered subprocess")

        let r = await runTask.value
        XCTAssertEqual(r.outcome, .outcomeUnknown)
        XCTAssertTrue(r.killed)
    }

    /// Without an ambient binding AND without an explicit ID, the runner
    /// stays unregistered — cancel can't target it. Confirms the opt-in
    /// behavior is preserved when nothing's set up.
    func testNoAmbientNoExplicitIsNotCancellable() {
        // Run a short script; verify the registry stays empty for an
        // arbitrary unrelated id.
        let r = AppleScriptRunner.run(source: "return \"hi\"", tool: "test")
        XCTAssertEqual(r.outcome, .success)
        XCTAssertFalse(AppleScriptRunner.cancel(invocationID: "anything"))
    }

    /// External cancel + post-verify .confirmed upgrades outcome_unknown to
    /// success — the dedup path's "kill then verify" wiring works end-to-end.
    func testExternalCancelWithVerifyConfirmedUpgrades() {
        let id = "test-cancel-verify-\(UUID().uuidString)"
        let done = DispatchSemaphore(value: 0)
        var result: AppleScriptRunner.RunResult? = nil
        let lock = NSLock()

        DispatchQueue.global().async {
            let r = AppleScriptRunner.run(
                source: """
                log "PHASE: prepare"
                log "PHASE: pre-commit"
                delay 30
                """,
                tool: "cancel-test",
                invocationID: id,
                onOutcomeUnknown: { .confirmed(id: "verified-xyz") }
            )
            lock.lock(); result = r; lock.unlock()
            done.signal()
        }

        let waitDeadline = Date().addingTimeInterval(3.0)
        while !AppleScriptRunner.isActive(invocationID: id) && Date() < waitDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(AppleScriptRunner.cancel(invocationID: id))
        XCTAssertEqual(done.wait(timeout: .now() + 3.0), .success)

        lock.lock(); let r = result; lock.unlock()
        XCTAssertEqual(r?.outcome, .success, "verify .confirmed must upgrade outcome_unknown")
        XCTAssertEqual(r?.committedID, "verified-xyz")
    }

    /// Verifier itself exceeds its deadline → treated as .inconclusive, outcome
    /// stays .outcomeUnknown, total wall-clock cost bounded by verifyDeadline.
    func testVerifyHookExceedingDeadlineIsInconclusive() {
        let script = """
        log "PHASE: prepare"
        log "PHASE: pre-commit"
        delay 10
        """
        let start = Date()
        let r = AppleScriptRunner.run(
            source: script,
            tool: "test",
            deadline: 0.3,
            verifyDeadline: 0.3,
            onOutcomeUnknown: {
                Thread.sleep(forTimeInterval: 5.0)
                return .confirmed(id: "too-late")
            }
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.outcome, .outcomeUnknown,
            "verifier slept past its deadline — outcome must stay outcome_unknown")
        XCTAssertLessThan(elapsed, 2.0,
            "verifier deadline must bound total wall-clock cost (was \(elapsed)s)")
    }
}
