import Foundation

/// Best-effort "you're behind" nudge for the **CLI-on-`$PATH`** consumer only.
///
/// apple-tools installs by symlinking `~/bin/apple-tools` into a live source
/// checkout, so merging to `main` or cutting a release tag does nothing to the
/// installed binary until a human re-runs `bin/install-skill`. This check gives
/// an agent (or human) a signal that a newer version exists.
///
/// ## CLI-only by construction
///
/// Nothing here runs unless something calls `maybeNudge()`, and the **only**
/// caller is `Sources/apple-tools/main.swift`. Library/API hosts that embed
/// `AppleToolsLib` (e.g. Shannon's `probe-macos`) never invoke it, so they see
/// no stderr output and make no network call — they already move forward via
/// `swift package update` on release tags, a path this check deliberately
/// ignores (see issue).
///
/// ## Design
///
/// - **Weekly gate.** `main.swift` is a one-shot dispatcher, so "on startup"
///   fires on every invocation. A timestamp cache file
///   (`~/.claude/apple-tools/last-update-check`) bounds the network call to at
///   most once per week; 99% of invocations do zero network work.
/// - **Live check only.** When a fresh fetch shows the compiled-in version is
///   behind the latest GitHub release tag, one line goes to **stderr** (never
///   stdout — stdout is the JSON tool contract). No cached-tag fallback: an
///   offline week goes silent.
/// - **Fail silent & fast.** Offline, rate-limited, or slow API → no output, no
///   error, no delay beyond a bounded ~2s timeout. The timestamp is written
///   *before* the fetch, so a single offline blip can't cause a per-invocation
///   retry storm across an agent's many calls.
/// - **Opt-out.** `APPLE_TOOLS_NO_UPDATE_CHECK=1` disables it entirely.
public enum UpdateCheck {

    /// GitHub repo the release tag is read from.
    static let repoSlug = "akostibas/apple-tools"

    /// Link the nudge points at for the real upgrade path.
    static let readmeURL = "https://github.com/akostibas/apple-tools#upgrading"

    /// Env var that fully disables the check.
    static let optOutEnvVar = "APPLE_TOOLS_NO_UPDATE_CHECK"

    /// At most one network check per week.
    static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Bounded network deadline. The command must never stall on a slow API.
    static let fetchTimeout: TimeInterval = 2.0

    // MARK: - Orchestration

    /// Best-effort nudge to stderr when the installed CLI is behind the latest
    /// release. All collaborators are injectable so the whole flow is unit
    /// testable without touching the network, clock, filesystem, or real stderr.
    ///
    /// - Parameters kept as defaults for the production call site in `main.swift`.
    public static func maybeNudge(
        installedVersion: String = AppleToolsVersion.versionString,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cacheFile: URL = defaultCacheFile(),
        now: Date = Date(),
        fetch: () -> String? = { defaultFetchLatestTag() },
        emit: (String) -> Void = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    ) {
        // Opt-out wins over everything.
        if environment[optOutEnvVar] == "1" { return }

        // Weekly gate: within the window, do zero network work.
        if let last = lastCheck(cacheFile: cacheFile),
           now.timeIntervalSince(last) < checkInterval {
            return
        }

        // Open the window *before* the fetch so at most one attempt happens per
        // week regardless of the outcome — an offline blip can't make every
        // subsequent invocation re-hit the network.
        writeCheck(cacheFile: cacheFile, now: now)

        guard let latest = fetch() else { return }               // offline / slow / rate-limited
        guard isBehind(installed: installedVersion, latest: latest) else { return }
        emit(nudgeLine(installed: installedVersion, latest: latest))
    }

    // MARK: - Version comparison (pure)

    /// Format the nudge line, e.g.
    /// `apple-tools: v0.7.1 installed, v0.8.0 available — upgrade instructions: <url>`
    static func nudgeLine(installed: String, latest: String) -> String {
        "apple-tools: \(display(installed)) installed, \(display(latest)) available"
            + " — upgrade instructions: \(readmeURL)"
    }

    /// True iff `latest` is a strictly newer semver than `installed`. Unparseable
    /// input on either side returns false — we never nudge on a version we can't
    /// reason about.
    static func isBehind(installed: String, latest: String) -> Bool {
        guard let a = parseSemver(installed), let b = parseSemver(latest) else { return false }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return y > x }
        }
        return false
    }

    /// Parse `[major, minor, patch]` from any of `apple-tools/0.7.1`, `v0.8.0`,
    /// or `0.8.0-2-gabc`. Returns nil if no numeric core is present.
    static func parseSemver(_ raw: String) -> [Int]? {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasPrefix("v") { s.removeFirst() }
        // Drop any pre-release / git-describe suffix (`-2-gabc`, `-rc1`).
        let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// Normalize either version shape to a `vX.Y.Z` display string.
    static func display(_ raw: String) -> String {
        guard let parts = parseSemver(raw) else { return raw }
        return "v" + parts.map(String.init).joined(separator: ".")
    }

    // MARK: - Cache file (timestamp only — live-check-only, no cached tag)

    /// `~/.claude/apple-tools/last-update-check`.
    public static func defaultCacheFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/apple-tools/last-update-check")
    }

    static func lastCheck(cacheFile: URL) -> Date? {
        guard let s = try? String(contentsOf: cacheFile, encoding: .utf8),
              let secs = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: secs)
    }

    static func writeCheck(cacheFile: URL, now: Date) {
        try? FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? String(now.timeIntervalSince1970).write(to: cacheFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Network (default fetcher; swapped out in tests)

    /// Synchronously fetch the latest release version with a bounded timeout.
    /// Returns nil on any failure (offline, non-200, rate-limited, malformed) —
    /// the caller treats nil as "no signal, stay quiet".
    ///
    /// Reads the **tags** API, not `releases/latest`: `bin/release` publishes
    /// git tags (`vX.Y.Z`), not GitHub Releases, so `releases/latest` 404s. The
    /// tags endpoint returns tags in no guaranteed semver order, so we parse
    /// every tag and return the highest — never assume the first is newest.
    public static func defaultFetchLatestTag() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoSlug)/tags?per_page=100") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: fetchTimeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("apple-tools-cli", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let data = data,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            body = data
        }
        task.resume()
        // Hard wall slightly past the request timeout in case the callback is late.
        if sem.wait(timeout: .now() + fetchTimeout + 0.5) == .timedOut {
            task.cancel()
            return nil
        }
        guard let data = body else { return nil }
        return highestSemverTag(fromTagsJSON: data)
    }

    /// Pick the highest semver tag name from a GitHub tags-API JSON payload
    /// (`[{"name": "v0.8.0", ...}, ...]`). Returns nil if the payload is
    /// unparseable or contains no semver-shaped tags. Split out from the network
    /// call so the max-picking logic is unit-testable without a live API.
    static func highestSemverTag(fromTagsJSON data: Data) -> String? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let names = arr.compactMap { $0["name"] as? String }
        // Keep only parseable tags, then pick the max by semver (isBehind is the
        // single source of truth for ordering).
        return names
            .filter { parseSemver($0) != nil }
            .max { a, b in isBehind(installed: a, latest: b) }
    }
}
