import Foundation

/// Host services injected into the tools that need them. This is the seam that
/// decouples the shared tool implementations from any particular host:
///
/// - `fileSink`  — where file-producing tools deliver their output (local disk
///   in the CLI; an upload endpoint in a server-backed probe).
/// - `confirmer` — how the host gates sensitive actions (no prompt, a blocking
///   AppleScript dialog, a server round-trip, …).
/// - `appName`   — the user-facing identity shown in confirmation dialogs
///   (e.g. "apple-tools" or "Shannon").
///
/// Pure read-only tools (Calendar, Contacts, Reminders, Notes) don't need a
/// host and keep their no-argument initializers.
public struct ToolHost {
    public let fileSink: FileSink
    public let confirmer: Confirmer
    public let appName: String

    public init(fileSink: FileSink, confirmer: Confirmer, appName: String) {
        self.fileSink = fileSink
        self.confirmer = confirmer
        self.appName = appName
    }
}

/// Gates a sensitive action (screenshot, open-URI) behind host-defined policy.
public protocol Confirmer {
    /// Ask the user to allow/deny. Return true to proceed.
    func confirm(title: String, message: String) -> Bool
}

/// Never prompts; always proceeds. The CLI's default, so it runs
/// non-interactively under an agent whose own per-invocation approval is the
/// real gate. Opt back into prompting by injecting `AppleScriptConfirmer`.
public struct AllowAllConfirmer: Confirmer {
    public init() {}
    public func confirm(title: String, message: String) -> Bool { true }
}

/// Shows a blocking AppleScript Allow/Deny dialog (used by the probe always,
/// and by the CLI when the user opts in).
public struct AppleScriptConfirmer: Confirmer {
    public let timeout: Int

    public init(timeout: Int = 30) {
        self.timeout = timeout
    }

    public func confirm(title: String, message: String) -> Bool {
        UserConfirmation.presentDialog(title: title, message: message, timeout: timeout)
    }
}
