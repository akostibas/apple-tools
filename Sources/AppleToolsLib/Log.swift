import Foundation
import os

/// Shared logger for the probe. Uses OSLog so output is visible under launchd
/// via `log stream --predicate 'subsystem == "com.apple-tools"'` or Console.app.
///
/// When `verbose` is true, messages are also printed to stderr for interactive use.
///
/// `info()` uses `.log` (OSLog "default" level) instead of `.info` because macOS
/// does not persist `.info`-level messages to disk — they only exist in the live
/// ring buffer and vanish within minutes. `.log` is persisted automatically,
/// giving us a forensic trail without any per-machine `log config` setup.
/// See for the incident that motivated this.
public enum Log {
    static let logger = Logger(subsystem: "com.apple-tools", category: "probe")

    /// Set to true via --verbose to echo log messages to stderr.
    public static var verbose = false

    public static func info(_ message: String) {
        logger.log("\(message, privacy: .public)")
        if verbose { fputs(message + "\n", stderr) }
    }

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        if verbose { fputs(message + "\n", stderr) }
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if verbose { fputs(message + "\n", stderr) }
    }
}
