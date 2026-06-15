import Foundation

/// Post-verify hook for `Notes.app` note creation and append. ADR-032
/// reference implementation #3.
///
/// ## Why this verifier uses AppleScript, not SQLite
///
/// `MailDraftVerifier` (sibling reference impl) reads Mail's Envelope Index
/// directly — Mail flushes it in real time, so a draft is visible within
/// single-digit milliseconds of `make new outgoing message`. Notes is
/// different: `NoteStore.sqlite` is written on Notes.app's own cadence
/// (idle, iCloud sync, app close), and the post-verify-live-check
/// diagnostic measured **>180s** between `make new note` and a row landing
/// in the on-disk store on a quiescent system. SQLite-based polling never
/// fires within the 5s verifier deadline.
///
/// Instead, this verifier issues a *readonly* AppleScript query against
/// `Notes` itself — `every note whose name is ...`. Notes' in-process
/// state is current, so a freshly-created note is visible immediately.
/// The risk ADR-032 calls out (the verifier deadlocking against the same
/// unresponsive app that just got us SIGKILLed) is bounded by a tight
/// 2s deadline on the readonly script: if Notes is stuck, the readonly
/// query SIGKILLs at 2s and we return `.inconclusive` — same outcome as
/// any other verifier failure path.
///
/// ## Conservative direction
///
/// Like `MailDraftVerifier`, this verifier never returns `.absent`. The
/// `every note whose name is ...` query could return zero matches because
/// the note really doesn't exist *or* because the AppleScript query
/// itself raced ahead of Notes' internal commit. Treating absence as
/// "definitely failed" would risk duplicate notes on retry.
public enum NotesVerifier {

    public static let defaultPollInterval: TimeInterval = 0.25

    /// Hard deadline on each readonly AppleScript query. Notes responds in
    /// <100ms for a healthy machine; 2s bounds the cost of one stuck query
    /// without exhausting the outer verifier deadline.
    public static var readonlyDeadline: TimeInterval = 2.0

    /// Injectable for tests. Returns the note's identifier if a note with
    /// `title` was modified at or after `sinceCutoff` (UNIX epoch seconds).
    /// Production calls `defaultFindRecentNote` which dispatches a bounded
    /// readonly AppleScript.
    public static var findRecentNote: (_ title: String, _ sinceCutoff: TimeInterval) -> String? = defaultFindRecentNote

    /// Snapshot the current wall-clock time as a UNIX epoch second value,
    /// backdated 1s for clock skew between the probe process and Notes.app's
    /// commit timestamp.
    public static func snapshotCutoff(now: Date = Date()) -> TimeInterval {
        return now.timeIntervalSince1970 - 1.0
    }

    public static func makeVerifyHook(
        title: String,
        sinceCutoff: TimeInterval,
        deadline: TimeInterval = 5.0
    ) -> () -> AppleScriptRunner.VerifyResult {
        return {
            return verify(title: title, sinceCutoff: sinceCutoff, deadline: deadline)
        }
    }

    public static func verify(
        title: String,
        sinceCutoff: TimeInterval,
        deadline: TimeInterval = 5.0,
        pollInterval: TimeInterval = defaultPollInterval
    ) -> AppleScriptRunner.VerifyResult {
        let start = Date()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        while Date().timeIntervalSince(start) < deadline {
            if let id = findRecentNote(normalizedTitle, sinceCutoff) {
                return .confirmed(id: id)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return .inconclusive
    }

    // MARK: - Default readonly AppleScript lookup

    /// applescript-runner: read-only — issues a `count`/`id of` query against
    /// Notes.app to confirm a recently-modified note with matching title
    /// exists. No mutation primitives; no PHASE markers needed.
    static func defaultFindRecentNote(title: String, sinceCutoff: TimeInterval) -> String? {
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
        // AppleScript's `current date` returns a date object; we compute
        // cutoff inside the script as (current date) - <seconds since now>.
        // This avoids passing a date literal and dealing with locale parsing.
        let nowEpoch = Date().timeIntervalSince1970
        let secondsAgo = max(0, Int(nowEpoch - sinceCutoff))

        let script = """
        tell application "Notes"
            try
                set cutoffDate to (current date) - \(secondsAgo)
                set candidates to (every note whose name is "\(escapedTitle)" and modification date >= cutoffDate)
                if (count of candidates) = 0 then return ""
                return id of (item 1 of candidates) as string
            on error
                return ""
            end try
        end tell
        """
        let result = AppleScriptRunner.run(source: script, tool: "notes-verify", deadline: readonlyDeadline)
        guard result.outcome == .success else { return nil }
        let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
