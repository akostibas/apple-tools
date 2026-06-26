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

    /// Show a dialog with Allow/Deny buttons. Returns true if the user clicks
    /// Allow. Times out after `timeout` seconds (default 30), counting as
    /// denial. Whether to call this at all is the host's policy — see
    /// `Confirmer` / `AppleScriptConfirmer` / `AllowAllConfirmer`.
    public static func presentDialog(title: String, message: String, timeout: Int = 30) -> Bool {
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
