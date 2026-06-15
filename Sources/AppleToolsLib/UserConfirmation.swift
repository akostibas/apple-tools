import Foundation

/// Shared helper for showing an osascript confirmation dialog to the user.
public enum UserConfirmation {
    /// Test seam: swappable runner so tests can intercept the script/env
    /// without spawning osascript. See AppleScriptEscapingCorpusTests.
    static var runAppleScript: (_ source: String, _ environment: [String: String]) -> (stdout: String, ok: Bool) = defaultRunAppleScript

    static func defaultRunAppleScript(_ source: String, _ environment: [String: String]) -> (stdout: String, ok: Bool) {
        // Dialog `giving up after` is the user-facing timeout; the runner
        // deadline is a hard backstop, so give it generous headroom over the
        // dialog timeout (which is embedded in `source`).
        let result = AppleScriptRunner.run(source: source, tool: "user-confirmation", deadline: 300, environment: environment)
        return (result.stdout, result.outcome == .success)
    }

    /// Show a dialog with Allow/Deny buttons. Returns true if the user clicks Allow.
    /// Times out after `timeout` seconds (default 30), which counts as denial.
    /// Opt-in gate. Confirmation dialogs are OFF by default so the CLI runs
    /// non-interactively under an agent (the gate there is the agent's own
    /// per-invocation approval). Set `APPLE_TOOLS_CONFIRM=1` (the `--confirm`
    /// flag sets it) to require an interactive Allow/Deny dialog for sensitive
    /// actions like screenshots and opening URIs.
    public static var isEnabled: Bool {
        let v = ProcessInfo.processInfo.environment["APPLE_TOOLS_CONFIRM"]
        return v == "1" || v == "true" || v == "yes"
    }

    public static func requestConfirmation(title: String, message: String, timeout: Int = 30) -> Bool {
        // Opt-in: when disabled, proceed without a (blocking) GUI dialog.
        guard isEnabled else { return true }
        // Payload (title + message) flows through env, not the script source.
        // `do shell script "printenv X"` returns the value as UTF-8 (var name
        // is a compile-time literal, so no shell-injection surface)..
        let env = [
            "APPLE_TOOLS_CONFIRM_MESSAGE": message,
            "APPLE_TOOLS_CONFIRM_TITLE": title,
        ]
        let script = """
        set theMessage to do shell script "printenv APPLE_TOOLS_CONFIRM_MESSAGE"
        set theTitle to do shell script "printenv APPLE_TOOLS_CONFIRM_TITLE"
        display dialog theMessage \
            buttons {"Deny", "Allow"} default button "Allow" \
            with title theTitle \
            with icon caution \
            giving up after \(timeout)
        """

        let (output, ok) = runAppleScript(script, env)
        guard ok else { return false }
        if output.contains("gave up:true") { return false }
        return output.contains("Allow")
    }
}
