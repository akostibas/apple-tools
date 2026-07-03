import Foundation

/// Runs AppleScript via a subprocess (`/usr/bin/osascript`) instead of the
/// in-process `NSAppleScript` API. This gives us:
///
/// - A real PID we can `SIGKILL` if the script hangs (e.g. Mail.app blocked).
/// - Streaming stderr, so AppleScript `log` statements are observable in real
///   time and end up in the probe's unified-log stream for forensic debugging.
/// - Per-invocation deadlines, so a single hung tool call cannot block the
///   probe indefinitely (see / incident).
///
/// ## PHASE marker convention
///
/// Scripts may emit lifecycle markers on stderr via `log "PHASE: <name>"`.
/// The runner tracks the last-seen phase. Reserved phases:
///
/// - `prepare`     — gathering inputs, no side effects yet
/// - `pre-commit`  — about to mutate user-visible state
/// - `committed id=<x>` — mutation finished, identity returned
///
/// On timeout the runner classifies the outcome based on the last phase seen,
/// distinguishing safe-to-retry failures from ambiguous ones. Scripts that
/// emit no markers behave as legacy: timeouts are classified as `.failed` if
/// no phase was observed.
public enum AppleScriptRunner {

    /// Process-wide SIGPIPE suppression, applied exactly once.
    ///
    /// Writing the script source into osascript's stdin is a raw `write(2)`.
    /// If osascript dies before draining stdin (crash at launch, an external
    /// SIGKILL, or our own deadline kill racing the write), the kernel raises
    /// SIGPIPE on the writer — whose default disposition terminates the
    /// process. Embedded in a long-lived library consumer (probe-macos) a
    /// single bad spawn would take down the whole daemon (exit 141).
    ///
    /// Ignoring SIGPIPE process-wide turns that into an `EPIPE` errno the
    /// throwing write path can catch. This is the standard disposition for
    /// any process that talks to pipes/sockets it doesn't control; POSIX
    /// per-thread signal masks can't cover it because SIGPIPE is delivered to
    /// the thread doing the write, not maskable per-call. The `static let` is
    /// initialized lazily and atomically by the runtime, so it runs once no
    /// matter how many threads enter `run()` first.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Active-subprocess registry for external cancellation.
    ///
    /// `run()` registers its pid under the caller-supplied invocation ID for
    /// the lifetime of the subprocess. External callers — typically the probe
    /// read loop, on a different queue than `toolQueue` — can then SIGKILL
    /// the subprocess via `cancel(invocationID:)`. The cancelled flag survives
    /// the kill so the post-wait classification in `run()` knows that
    /// non-zero termination came from us, not from a script error.
    private final class ActiveInvocation {
        let pid: pid_t
        var cancelled: Bool = false
        init(pid: pid_t) { self.pid = pid }
    }
    private static var activeInvocations: [String: ActiveInvocation] = [:]
    private static let activeLock = NSLock()

    /// SIGKILL the subprocess associated with `invocationID`, if any.
    /// Returns true if a matching subprocess was found and signaled.
    ///
    /// Safe to call concurrently with `run()`. The cancelled flag is set
    /// before the signal so `run()` always observes it post-wait.
    @discardableResult
    public static func cancel(invocationID: String) -> Bool {
        activeLock.lock()
        guard let entry = activeInvocations[invocationID] else {
            activeLock.unlock()
            return false
        }
        entry.cancelled = true
        let pid = entry.pid
        activeLock.unlock()
        Log.info("applescript: external cancel id=\(invocationID) pid=\(pid)")
        kill(pid, SIGKILL)
        return true
    }

    /// Test/diagnostic hook: is an invocation currently registered?
    public static func isActive(invocationID: String) -> Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeInvocations[invocationID] != nil
    }

    /// Ambient invocation ID, scoped via `@TaskLocal`. When `run()` is called
    /// without an explicit `invocationID:`, it falls back to this value. The
    /// idempotency cache binds it once per invocation so individual tool
    /// integrations (IMessageSender, NotesIntegration, etc.) don't have to
    /// thread the ID through every call site. The binding is task-local, so
    /// verifier hooks dispatched onto background queues do NOT inherit it
    /// (and therefore aren't cancellable via the parent's ID, which is the
    /// behavior we want).
    @TaskLocal public static var ambientInvocationID: String?

    public enum Outcome: String, Sendable {
        case success
        case failed
        /// Script was killed at deadline after emitting `PHASE: pre-commit`
        /// but before `committed`. The mutation may or may not have happened
        /// inside the target app — callers should not blindly retry.
        case outcomeUnknown = "outcome_unknown"
    }

    /// Post-verify hook return value. See ADR-032.
    public enum VerifyResult: Sendable {
        /// Artifact found in target app's storage. Outcome upgrades to `.success`,
        /// `committedID` is replaced with the supplied id if non-nil.
        case confirmed(id: String?)
        /// Artifact definitively absent after a bounded poll. Outcome upgrades
        /// to `.failed` — safe to retry.
        case absent
        /// Verifier itself was inconclusive (deadline expired, schema unreadable,
        /// etc.). Outcome stays `.outcomeUnknown`.
        case inconclusive
    }

    public struct RunResult {
        public let outcome: Outcome
        public let lastPhase: String?
        public let committedID: String?
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let elapsed: TimeInterval
        public let killed: Bool

        /// Convenience: error detail for legacy `(String, String?)` callers.
        /// Returns nil iff `outcome == .success`.
        public var errorDetail: String? {
            switch outcome {
            case .success: return nil
            case .failed:
                if killed { return "applescript timed out after \(String(format: "%.1f", elapsed))s" }
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "applescript exited \(exitCode)" : trimmed
            case .outcomeUnknown:
                return "applescript timed out in pre-commit phase after \(String(format: "%.1f", elapsed))s — outcome unknown"
            }
        }
    }

    /// Default per-invocation deadline. Override per call site as appropriate.
    /// 60s is generous for normal usage but bounded — a hung Mail.app cannot
    /// stall the probe for 9 minutes the way the unbounded NSAppleScript API
    /// allowed (incident).
    public static let defaultDeadline: TimeInterval = 60.0

    /// Run `source` via osascript. Logs invocation start, every stderr line,
    /// and final outcome.
    ///
    /// ## Log levels
    ///
    /// Phase transitions and successful completions log at INFO during the
    /// initial validation period for ADR-031. Once we're confident the
    /// subprocess runner behaves correctly across our integrations (target:
    /// after 2026-08-10, ~3 months of production use), step the routine
    /// `phase=...` and `ok elapsed=...` lines down to DEBUG. Error / timeout /
    /// `outcome_unknown` lines stay at ERROR — those are always worth seeing.
    /// Default verifier deadline. Verifiers poll a target app's storage
    /// (chat.db, Mail Envelope Index, Notes store) — 5s is enough for a
    /// terminal state to appear without delaying the user-visible response.
    public static let defaultVerifyDeadline: TimeInterval = 5.0

    public static func run(
        source: String,
        tool: String,
        invocationID: String? = nil,
        deadline: TimeInterval = defaultDeadline,
        verifyDeadline: TimeInterval = defaultVerifyDeadline,
        environment: [String: String] = [:],
        onOutcomeUnknown: (() -> VerifyResult)? = nil
    ) -> RunResult {
        _ = Self.ignoreSIGPIPE // ensure SIGPIPE is neutralized before we write stdin
        let start = Date()
        Log.debug("applescript: tool=\(tool) starting deadline=\(deadline)s")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-"] // read script from stdin
        if !environment.isEmpty {
            // Inherit the current process environment, overlay caller-supplied
            // keys. Callers pass payload text here (fetched in AppleScript via
            // `do shell script "printenv KEY"`, which returns the value as
            // UTF-8 — `system attribute` decodes as MacRoman and mangles
            // multi-byte chars). The text never enters the script source —
            // eliminates the escaping class of bug.
            switch sanitizeEnvironment(environment, tool: tool) {
            case .ok(let cleaned):
                var env = ProcessInfo.processInfo.environment
                for (k, v) in cleaned { env[k] = v }
                proc.environment = env
            case .tooLarge(let bytes):
                Log.error("applescript: tool=\(tool) refusing to spawn — env payload \(bytes) bytes exceeds \(maxEnvBytes)-byte cap")
                return RunResult(
                    outcome: .failed, lastPhase: nil, committedID: nil,
                    stdout: "", stderr: "env payload too large (\(bytes) bytes > \(maxEnvBytes) cap)",
                    exitCode: -1, elapsed: 0, killed: false
                )
            }
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let phaseLock = NSLock()
        var lastPhase: String? = nil
        var committedID: String? = nil
        var stderrBuffer = Data()
        var stderrAccum = Data()

        // Drain stdout concurrently: osascript blocks writing once the 64KB
        // pipe buffer fills, and waitUntilExit() would then deadlock until
        // the deadline SIGKILL.
        let stdoutLock = NSLock()
        var stdoutAccum = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            stdoutLock.lock()
            stdoutAccum.append(data)
            stdoutLock.unlock()
        }

        // Parse a single (newline-stripped) stderr line for a PHASE marker.
        // Caller must hold `phaseLock`; mutates `lastPhase`/`committedID`.
        func parseStderrLine(_ lineData: Data) {
            guard let line = String(data: lineData, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return }
            Log.debug("applescript: tool=\(tool) stderr: \(trimmed)")
            if let range = trimmed.range(of: "PHASE: ") {
                let phase = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                lastPhase = phase
                if phase.hasPrefix("committed"), let idRange = phase.range(of: "id=") {
                    committedID = String(phase[idRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                Log.info("applescript: tool=\(tool) phase=\(phase)")
            }
        }

        // Consume every complete (newline-terminated) line currently buffered.
        // Caller must hold `phaseLock`.
        func drainCompleteStderrLines() {
            while let nl = stderrBuffer.firstIndex(of: 0x0A) {
                let lineData = stderrBuffer.prefix(nl)
                stderrBuffer.removeSubrange(0...nl)
                parseStderrLine(lineData)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            phaseLock.lock()
            stderrBuffer.append(data)
            stderrAccum.append(data)
            drainCompleteStderrLines()
            phaseLock.unlock()
        }

        do {
            try proc.run()
        } catch {
            Log.error("applescript: tool=\(tool) spawn failed: \(error)")
            return RunResult(
                outcome: .failed, lastPhase: nil, committedID: nil,
                stdout: "", stderr: "spawn failed: \(error)",
                exitCode: -1, elapsed: 0, killed: false
            )
        }

        // Register for external cancellation and arm the deadline BEFORE the
        // stdin write. The write is bounded by the OS pipe buffer (~64KB): a
        // script source larger than that fed to a wedged osascript would block
        // the write indefinitely. Arming the deadline/cancel path first means
        // that stall is still bounded — the deadline SIGKILL (or an external
        // cancel) tears down osascript, the pipe breaks, and our SIGPIPE-safe
        // write returns EPIPE instead of hanging `run()` forever.
        let effectiveID: String? = invocationID ?? Self.ambientInvocationID
        var activeEntry: ActiveInvocation? = nil
        if let id = effectiveID {
            let entry = ActiveInvocation(pid: proc.processIdentifier)
            activeLock.lock()
            activeInvocations[id] = entry
            activeLock.unlock()
            activeEntry = entry
        }

        // `killed` is written by the deadline work item (a background queue)
        // and read on this thread after wait — guard it with a lock to avoid
        // a data race (TSan) and torn reads.
        let killLock = NSLock()
        var killed = false
        let deadlineWork = DispatchWorkItem {
            if proc.isRunning {
                killLock.lock()
                killed = true
                killLock.unlock()
                Log.error("applescript: tool=\(tool) deadline hit (\(deadline)s), sending SIGKILL to pid \(proc.processIdentifier)")
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: deadlineWork)

        // SIGPIPE-safe stdin write. SIGPIPE is ignored process-wide (see
        // `ignoreSIGPIPE`), so a dead osascript surfaces here as a thrown
        // EPIPE rather than killing the host. We log and carry on — osascript
        // is already gone, and the post-wait classification handles it.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: source.data(using: .utf8) ?? Data())
        } catch {
            Log.error("applescript: tool=\(tool) stdin write failed (osascript likely already exited): \(error)")
        }
        try? stdinPipe.fileHandleForWriting.close()

        proc.waitUntilExit()
        deadlineWork.cancel()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        // Read the external-cancel flag and unregister. The flag must be read
        // before unregistering so a concurrent cancel() that arrives at
        // exactly this moment is still observed: cancel() sets the flag under
        // the lock before signaling.
        let externallyCancelled: Bool
        if let id = effectiveID, let entry = activeEntry {
            activeLock.lock()
            externallyCancelled = entry.cancelled
            activeInvocations.removeValue(forKey: id)
            activeLock.unlock()
        } else {
            externallyCancelled = false
        }

        stdoutLock.lock()
        var stdoutData = stdoutAccum
        stdoutLock.unlock()
        // Drain any remaining stdout that arrived after the readability handler stopped.
        stdoutData.append((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data())
        // Drain any remaining stderr that arrived after the readability handler
        // stopped, and — critically — scan it for PHASE markers. A script that
        // logs `PHASE: committed` and is SIGKILLed at the deadline before the
        // handler callback fires would otherwise have that definitive marker
        // silently dropped, misclassifying a landed mutation as outcome_unknown.
        // We parse both any newline-terminated lines AND a trailing line with
        // no final newline (osascript killed mid-line).
        let trailingStderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        phaseLock.lock()
        stderrAccum.append(trailingStderr)
        stderrBuffer.append(trailingStderr)
        drainCompleteStderrLines()
        if !stderrBuffer.isEmpty {
            // Final line never got its newline (process killed mid-write).
            parseStderrLine(stderrBuffer)
            stderrBuffer.removeAll()
        }
        let phase = lastPhase
        let id = committedID
        let stderrStr = String(data: stderrAccum, encoding: .utf8) ?? ""
        phaseLock.unlock()

        killLock.lock()
        let didKill = killed
        killLock.unlock()

        let elapsed = Date().timeIntervalSince(start)
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""

        // A process that exited cleanly (status 0, normal exit — not a signal)
        // completed its work in full, even if the deadline fired or an external
        // cancel arrived in the same instant. `killed`/`externallyCancelled`
        // only mean we *sent* a signal; a clean termination status proves the
        // signal lost the race and osascript finished first. Honor that before
        // the kill-based classifications, otherwise a marker-less script that
        // races the deadline is misreported as a timeout `.failed`.
        let cleanExit = (proc.terminationStatus == 0 && proc.terminationReason == .exit)

        let outcome: Outcome
        if cleanExit {
            outcome = .success
        } else if externallyCancelled {
            // External cancel — caller pulled the plug. We don't know
            // what the script did; let the post-verify hook decide.
            // Committed-phase scripts are the one case we can confidently
            // classify as success — the side effect already landed.
            if let p = phase, p.hasPrefix("committed") {
                outcome = .success
            } else {
                outcome = .outcomeUnknown
            }
        } else if didKill {
            switch phase {
            case .none, "prepare":
                outcome = .failed
            case "pre-commit":
                outcome = .outcomeUnknown
            case let p? where p.hasPrefix("committed"):
                // Side effect already happened; kill was racing the natural exit.
                outcome = .success
            default:
                // Custom intermediate phase past pre-commit but before
                // committed — treat conservatively as ambiguous.
                outcome = .outcomeUnknown
            }
        } else if proc.terminationStatus == 0 {
            outcome = .success
        } else {
            outcome = .failed
        }

        // Post-verify: if the bare classification is outcome_unknown and a
        // hook was supplied, query the target app's storage to disambiguate.
        // See ADR-032.
        var finalOutcome = outcome
        var finalID = id
        if outcome == .outcomeUnknown, let hook = onOutcomeUnknown {
            switch runVerifyHook(hook, deadline: verifyDeadline, tool: tool) {
            case .confirmed(let verifiedID):
                Log.info("applescript: tool=\(tool) post-verify confirmed — outcome upgraded to success")
                finalOutcome = .success
                if let v = verifiedID { finalID = v }
            case .absent:
                Log.info("applescript: tool=\(tool) post-verify absent — outcome upgraded to failed")
                finalOutcome = .failed
            case .inconclusive:
                Log.error("applescript: tool=\(tool) post-verify inconclusive — outcome stays outcome_unknown")
            }
        }

        let elapsedMs = Int(elapsed * 1000)
        switch finalOutcome {
        case .success:
            Log.info("applescript: tool=\(tool) ok elapsed=\(elapsedMs)ms phase=\(phase ?? "<none>") exit=\(proc.terminationStatus)")
        case .failed:
            Log.error("applescript: tool=\(tool) failed elapsed=\(elapsedMs)ms phase=\(phase ?? "<none>") exit=\(proc.terminationStatus) killed=\(didKill)")
        case .outcomeUnknown:
            Log.error("applescript: tool=\(tool) outcome_unknown elapsed=\(elapsedMs)ms phase=\(phase ?? "<none>") killed=\(didKill) — side effect may have occurred")
        }

        return RunResult(
            outcome: finalOutcome,
            lastPhase: phase,
            committedID: finalID,
            stdout: stdoutStr,
            stderr: stderrStr,
            exitCode: proc.terminationStatus,
            elapsed: elapsed,
            killed: didKill || externallyCancelled
        )
    }

    /// Max combined env-value bytes accepted before we refuse to spawn
    /// osascript. macOS's `ARG_MAX` (argv + envp combined, ~1MB on modern
    /// kernels) bounds the true limit; refusing well below it gives a
    /// descriptive error instead of a cryptic `E2BIG` from `execve`.
    static let maxEnvBytes = 512 * 1024

    enum EnvSanitizationResult {
        case ok([String: String])
        case tooLarge(bytes: Int)
    }

    /// Sanitize caller-supplied env values before they reach `Process.environment`.
    ///
    /// - **NUL stripping**: POSIX env values are C strings, so embedded `\0`
    ///   silently truncates the value at `execve` time. Strip and warn so the
    ///   AppleScript side sees the rest of the value (closest to caller intent).
    /// - **Size cap**: enforce `maxEnvBytes` on the total UTF-8 byte count of
    ///   values so a runaway payload returns a clear error instead of crashing
    ///   the spawn.
    static func sanitizeEnvironment(_ env: [String: String], tool: String) -> EnvSanitizationResult {
        var cleaned: [String: String] = [:]
        var totalBytes = 0
        for (k, v) in env {
            let stripped: String
            if v.contains("\0") {
                stripped = v.replacingOccurrences(of: "\0", with: "")
                Log.error("applescript: tool=\(tool) env key=\(k) contained NUL bytes (stripped) — POSIX env can't carry \\0")
            } else {
                stripped = v
            }
            totalBytes += stripped.utf8.count
            cleaned[k] = stripped
        }
        if totalBytes > maxEnvBytes {
            return .tooLarge(bytes: totalBytes)
        }
        return .ok(cleaned)
    }

    /// Run the verify hook on a background queue with a hard deadline. The
    /// hook itself can be blocking (poll loops, SQLite reads); we cap the
    /// wall-clock cost so a stuck verifier — e.g., one that re-enters the
    /// same unresponsive app we just SIGKILLed — can't extend the failure
    /// indefinitely. On deadline expiry we return `.inconclusive`; the
    /// background work may continue and is allowed to leak (its result is
    /// just discarded). This is preferable to canceling SQLite mid-read.
    private static func runVerifyHook(
        _ hook: @escaping () -> VerifyResult,
        deadline: TimeInterval,
        tool: String
    ) -> VerifyResult {
        let sem = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: VerifyResult = .inconclusive
        DispatchQueue.global().async {
            let r = hook()
            resultLock.lock()
            result = r
            resultLock.unlock()
            sem.signal()
        }
        if sem.wait(timeout: .now() + deadline) == .timedOut {
            Log.error("applescript: tool=\(tool) post-verify hook exceeded \(deadline)s deadline")
            return .inconclusive
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }

    /// Legacy adapter matching the `(String, String?)` shape used by the
    /// per-integration `runAppleScript` helpers. Returns `(stdout, errorDetail)`
    /// where `errorDetail` is nil on success.
    ///
    /// Accepts an optional post-verify hook (ADR-032). When supplied, an
    /// `outcome_unknown` result from a pre-commit-phase kill is resolved
    /// against the verifier before being collapsed to the legacy
    /// `(stdout, errorDetail)` shape — so a hook-confirmed mutation returns
    /// `(stdout, nil)` instead of an error string.
    public static func runLegacy(
        source: String,
        tool: String,
        invocationID: String? = nil,
        verifyDeadline: TimeInterval = defaultVerifyDeadline,
        environment: [String: String] = [:],
        onOutcomeUnknown: (() -> VerifyResult)? = nil
    ) -> (String, String?) {
        let result = run(
            source: source,
            tool: tool,
            invocationID: invocationID,
            verifyDeadline: verifyDeadline,
            environment: environment,
            onOutcomeUnknown: onOutcomeUnknown
        )
        return (result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), result.errorDetail)
    }
}
