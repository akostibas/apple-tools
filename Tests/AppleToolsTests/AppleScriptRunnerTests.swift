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

    // MARK: - Classification (pure: a real deadline kill can't pin which phase was reached, #54)

    private func classify(
        cleanExit: Bool = false, cancelled: Bool = false, killed: Bool = false,
        phase: String? = nil, exit: Int32 = 9
    ) -> AppleScriptRunner.Outcome {
        AppleScriptRunner.classify(
            cleanExit: cleanExit, externallyCancelled: cancelled,
            killed: killed, phase: phase, exitStatus: exit)
    }

    func testDeadlineKillClassifiedByPhase() {
        XCTAssertEqual(classify(killed: true), .failed)
        XCTAssertEqual(classify(killed: true, phase: "prepare"), .failed)
        XCTAssertEqual(classify(killed: true, phase: "pre-commit"), .outcomeUnknown)
        XCTAssertEqual(classify(killed: true, phase: "committed"), .success)
        XCTAssertEqual(classify(killed: true, phase: "committed id=x"), .success)
        XCTAssertEqual(classify(killed: true, phase: "uploading"), .outcomeUnknown,
            "custom phase past pre-commit is ambiguous")
    }

    func testExternalCancelClassifiedByPhase() {
        XCTAssertEqual(classify(cancelled: true), .outcomeUnknown)
        XCTAssertEqual(classify(cancelled: true, phase: "prepare"), .outcomeUnknown)
        XCTAssertEqual(classify(cancelled: true, phase: "committed id=x"), .success)
        XCTAssertEqual(classify(cancelled: true, killed: true, phase: "prepare"), .outcomeUnknown,
            "cancel takes precedence over the deadline classification")
    }

    func testCleanExitWinsOverKillOrCancel() {
        XCTAssertEqual(classify(cleanExit: true, killed: true), .success)
        XCTAssertEqual(classify(cleanExit: true, cancelled: true), .success)
    }

    func testUnkilledExitStatus() {
        XCTAssertEqual(classify(exit: 0), .success)
        XCTAssertEqual(classify(phase: "committed", exit: 1), .failed)
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

    // MARK: - Robustness: SIGPIPE, marker-just-before-kill, clean-exit race

    /// #16: osascript that dies before draining stdin must not SIGPIPE-kill the
    /// host. Before the fix the parent took an unhandled SIGPIPE and exited 141
    /// with no result. Here we force a large source (bigger than the pipe
    /// buffer) into a script that exits immediately, so the write races a dead
    /// reader. `run()` must return a RunResult, not crash the test process.
    func testStdinWriteToEarlyExitDoesNotSIGPIPE() {
        // ~256KB of comment text — far larger than the ~64KB pipe buffer, so
        // the write can't complete in one shot and will still be flushing when
        // osascript exits.
        let big = String(repeating: "-- padding line to bloat the source\n", count: 8000)
        let source = big + "return \"quick\""
        let r = AppleScriptRunner.run(source: source, tool: "sigpipe-test", deadline: 20)
        // The key assertion is simply that we got here — no SIGPIPE took down
        // the process. Outcome is success (osascript ran the trailing return).
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "quick")
    }

    /// #18(2): a script that exits cleanly (status 0, full output) just as the
    /// deadline fires must be classified success, not a timeout failure. We set
    /// a deadline right around the script's natural completion and require that
    /// whenever the process exited 0 the outcome is success — never `.failed`
    /// "timed out". Repeat to hit the race window.
    func testCleanExitRacingDeadlineIsSuccessNotTimeout() {
        for _ in 0..<8 {
            let r = AppleScriptRunner.run(
                source: "delay 0.2\nreturn \"done\"",
                tool: "clean-race",
                deadline: 0.2
            )
            if r.exitCode == 0 {
                XCTAssertEqual(r.outcome, .success,
                    "a clean exit-0 must never be reported as a timeout failure")
                XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "done")
            } else {
                // Deadline won the race and killed it — that's a legitimate timeout.
                XCTAssertEqual(r.outcome, .failed)
                XCTAssertTrue(r.killed)
            }
        }
    }

    // MARK: - Post-verify hook (ADR-032; pure, so no subprocess has to land in a phase, #54)

    private func resolve(
        _ outcome: AppleScriptRunner.Outcome, id: String? = nil,
        verifyDeadline: TimeInterval = 5,
        hook: (() -> AppleScriptRunner.VerifyResult)?
    ) -> (AppleScriptRunner.Outcome, String?) {
        AppleScriptRunner.resolveUnknown(
            outcome, committedID: id, hook: hook, verifyDeadline: verifyDeadline, tool: "test")
    }

    /// Verifier runs only when the outcome is outcome_unknown.
    func testVerifyHookNotInvokedOnSuccessOrFailed() {
        var invoked = false
        let hook: () -> AppleScriptRunner.VerifyResult = { invoked = true; return .confirmed(id: "x") }
        XCTAssertEqual(resolve(.success, hook: hook).0, .success)
        XCTAssertEqual(resolve(.failed, hook: hook).0, .failed)
        XCTAssertNil(resolve(.success, hook: hook).1, "committedID must not come from an uninvoked verifier")
        XCTAssertFalse(invoked)
    }

    func testVerifyConfirmedUpgradesToSuccess() {
        let (outcome, id) = resolve(.outcomeUnknown, hook: { .confirmed(id: "draft-abc") })
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(id, "draft-abc")
        XCTAssertEqual(resolve(.outcomeUnknown, id: "kept", hook: { .confirmed(id: nil) }).1, "kept")
    }

    /// .absent → .failed: safe to retry, the side effect definitively did not happen.
    func testVerifyAbsentUpgradesToFailed() {
        XCTAssertEqual(resolve(.outcomeUnknown, hook: { .absent }).0, .failed)
    }

    func testVerifyInconclusiveLeavesOutcomeUnknown() {
        XCTAssertEqual(resolve(.outcomeUnknown, hook: { .inconclusive }).0, .outcomeUnknown)
        XCTAssertEqual(resolve(.outcomeUnknown, hook: nil).0, .outcomeUnknown)
    }

    /// A verifier that never returns is cut off at verifyDeadline → inconclusive.
    func testVerifyHookExceedingDeadlineIsInconclusive() {
        let never = DispatchSemaphore(value: 0)
        defer { never.signal() }
        let start = Date()
        let (outcome, _) = resolve(.outcomeUnknown, verifyDeadline: 0.3, hook: {
            never.wait()
            return .confirmed(id: "too-late")
        })
        XCTAssertEqual(outcome, .outcomeUnknown)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
            "verifier deadline must bound total wall-clock cost")
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
    /// success. Also covers #17: the marker may only arrive in the stderr
    /// drained after the kill, and must still be parsed.
    func testExternalCancelAfterCommittedIsSuccess() {
        let id = "test-cancel-committed-\(UUID().uuidString)"
        let done = DispatchSemaphore(value: 0)
        var result: AppleScriptRunner.RunResult? = nil
        let lock = NSLock()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("committed-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        DispatchQueue.global().async {
            let r = AppleScriptRunner.run(
                source: """
                log "PHASE: prepare"
                log "PHASE: pre-commit"
                log "PHASE: committed id=ok-123"
                do shell script "touch \(marker)"
                delay 30
                """,
                tool: "cancel-test",
                invocationID: id
            )
            lock.lock(); result = r; lock.unlock()
            done.signal()
        }

        // A fixed sleep raced osascript's cold start under load (#54); the file
        // proves the committed line was written before we cancel.
        let deadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: marker) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
            "script should reach the committed phase before we cancel")
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
}
