import Foundation

/// Posts a macOS Notification Center banner so a CLI invocation has a visible
/// effect. Uses `osascript display notification` (no app bundle / entitlements
/// required). Title and body flow through the environment — never the script
/// source — so arbitrary summary text can't break or inject into the script
/// (same pattern as `UserConfirmation`).
public enum Notifier {

    /// Test seam: swappable runner so tests can intercept without spawning
    /// osascript.
    static var runAppleScript: (_ source: String, _ environment: [String: String]) -> Void = { source, env in
        _ = AppleScriptRunner.run(source: source, tool: "notify", deadline: 10, environment: env)
    }

    public static func notify(title: String, body: String) {
        let env = [
            "APPLE_TOOLS_NOTIFY_TITLE": title,
            "APPLE_TOOLS_NOTIFY_BODY": body,
        ]
        let script = """
        set theTitle to do shell script "printenv APPLE_TOOLS_NOTIFY_TITLE"
        set theBody to do shell script "printenv APPLE_TOOLS_NOTIFY_BODY"
        display notification theBody with title theTitle
        """
        runAppleScript(script, env)
    }
}
