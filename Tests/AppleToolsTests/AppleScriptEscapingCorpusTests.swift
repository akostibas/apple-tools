import XCTest
@testable import AppleToolsLib

/// Shared corpus that pins the env-passing invariant for every probe
/// integration that drives AppleScript.
///
/// For each (integration, payload) pair the test asserts:
/// 1. The payload substring does not appear in the AppleScript source.
/// 2. The env dict carries the payload verbatim (modulo POSIX NUL
///    truncation, which `AppleScriptRunner.sanitizeEnvironment` strips
///    deliberately).
/// 3. The script references the env key via `system attribute "<key>"`.
///
/// Adding a new AppleScript-using integration is the explicit step that
/// gates passing this suite: a new conformer of `AppleScriptIntegration`
/// must be registered in `integrations` for the corpus to exercise it.
///
/// Background: (single LF eaten by `send "..."` literal) and
/// (rollout to Email/Notes/UserConfirmation + AppleScriptRunner
/// hardening).
final class AppleScriptEscapingCorpusTests: XCTestCase {

    // MARK: - Protocol

    /// Adapter that lets each integration plug into the corpus without
    /// exposing internal call shapes. The closure runs the integration's
    /// public entry point with `payload` placed into a payload-shaped
    /// field, and reports back what the integration would have sent to
    /// AppleScriptRunner.
    struct AppleScriptIntegration {
        let name: String
        let envKey: String
        /// Drive the integration with the payload. Implementations should
        /// swap the integration's `runAppleScript` test seam, call the
        /// public entry point with `payload` in its most payload-like
        /// field, and return the intercepted (script, env). The closure
        /// is responsible for restoring the seam on exit.
        let execute: (_ payload: String) -> (script: String, env: [String: String])
    }

    // MARK: - Corpus

    /// Tricky strings drawn from real-world failure modes:
    /// - `\n`, `\r`, `\r\n`, `\n \n` — the regression and friends
    /// - quote / escape characters
    /// - AppleScript reserved words on their own line (script-injection
    ///   shape that would corrupt a string-interpolated build)
    /// - multi-codepoint emoji + RTL
    /// - large payload (≈ 100KB) so we know `ARG_MAX` headroom is real
    ///
    /// NUL bytes are deliberately *not* in this corpus — they're sanitized
    /// by `AppleScriptRunner.sanitizeEnvironment` after this boundary, and
    /// `AppleScriptRunnerTests` covers that separately. The integration
    /// boundary's contract is identity: whatever the caller passes shows
    /// up in env verbatim, before the runner gets a chance to mutate it.
    static let corpus: [(name: String, payload: String)] = {
        let large = String(repeating: "A", count: 100_000)
        return [
            ("single LF",            "alpha\nbeta"),
            ("CR",                   "alpha\rbeta"),
            ("CRLF",                 "alpha\r\nbeta"),
            ("blank-line-with-space","sentence one.\n \nsentence two."),
            ("triple LF",            "para1\n\n\npara2"),
            ("double quote",         #"she said "danger""#),
            ("trailing backslash",   #"path\"#),
            ("reserved-word phrase", "before\nend tell\nafter"),
            ("multi-codepoint emoji","family 👨‍👩‍👧‍👦 here"),
            ("RTL text",             "hello مرحبا world"),
            ("large 100KB",          large),
        ]
    }()

    // MARK: - Integrations under test

    /// Add a new conformer when you add a new AppleScript-using
    /// integration. Forgetting to do so is the only failure mode this
    /// suite cannot catch directly.
    static let integrations: [AppleScriptIntegration] = [
        iMessageSenderIntegration(),
        notesCreateIntegration(),
        emailCreateDraftIntegration(),
        userConfirmationIntegration(),
    ]

    // MARK: - The shared test

    func testCorpusInvariantAcrossAllIntegrations() {
        for integration in Self.integrations {
            for entry in Self.corpus {
                let label = "\(integration.name) / \(entry.name)"
                let (script, env) = integration.execute(entry.payload)

                XCTAssertEqual(env[integration.envKey], entry.payload,
                    "\(label): env[\(integration.envKey)] should equal payload verbatim")

                // The script must reference the env key, not the payload.
                XCTAssertTrue(script.contains("printenv \(integration.envKey)"),
                    "\(label): script must fetch payload via `do shell script \"printenv \(integration.envKey)\"`")

                // The payload chars must not appear in the script source.
                // Use a substring sampling strategy: pick a 24-char window
                // from the middle of the payload to avoid spurious matches
                // on short common fragments.
                let needle = needleFor(entry.payload)
                if !needle.isEmpty {
                    XCTAssertFalse(script.contains(needle),
                        "\(label): script source must not contain payload substring '\(needle.prefix(40))…'")
                }
            }
        }
    }

    /// Pick a substring of the payload long enough to be distinctive but
    /// short enough to fit any payload. Returns empty if the payload is
    /// too short to sample meaningfully — those entries skip the script
    /// substring check (env equality is still asserted).
    private func needleFor(_ payload: String) -> String {
        let s = Array(payload)
        guard s.count >= 8 else { return "" }
        let start = s.count / 2 - 4
        let end = min(start + 24, s.count)
        return String(s[start..<end])
    }
}

// MARK: - Integration adapters

private func iMessageSenderIntegration() -> AppleScriptEscapingCorpusTests.AppleScriptIntegration {
    return .init(
        name: "IMessageSender.send",
        envKey: "APPLE_TOOLS_IMSG_TEXT",
        execute: { payload in
            var captured: (script: String, env: [String: String]) = ("", [:])
            let saved = IMessageSender.runAppleScript
            let savedLookup = IMessageSender.lookupOutgoingStatus
            let savedROWID = IMessageSender.currentMaxROWID
            let savedDeadline = IMessageSender.deliveryDeadline
            let savedPollInterval = IMessageSender.deliveryPollInterval
            defer {
                IMessageSender.runAppleScript = saved
                IMessageSender.lookupOutgoingStatus = savedLookup
                IMessageSender.currentMaxROWID = savedROWID
                IMessageSender.deliveryDeadline = savedDeadline
                IMessageSender.deliveryPollInterval = savedPollInterval
            }
            IMessageSender.runAppleScript = { script, env, _ in
                captured = (script, env)
                return ("", nil)
            }
            // Bypass the chat.db post-send poll so a fake-send returns
            // promptly from the harness rather than scanning a real db.
            IMessageSender.currentMaxROWID = { 0 }
            IMessageSender.lookupOutgoingStatus = { _, _ in
                IMessageIntegration.OutgoingStatus(state: .sent, rowID: 1, error: 0, isSent: true, isDelivered: true)
            }
            IMessageSender.deliveryDeadline = 0.5
            IMessageSender.deliveryPollInterval = 0.02

            _ = IMessageSender.send(to: "+15551234567", text: payload)
            return captured
        }
    )
}

private func notesCreateIntegration() -> AppleScriptEscapingCorpusTests.AppleScriptIntegration {
    return .init(
        name: "NotesIntegration.createNote(body)",
        envKey: "APPLE_TOOLS_NOTES_BODY",
        execute: { payload in
            var captured: (script: String, env: [String: String]) = ("", [:])
            let saved = NotesIntegration.runAppleScript
            defer { NotesIntegration.runAppleScript = saved }
            NotesIntegration.runAppleScript = { script, env, _ in
                captured = (script, env)
                // createNote parses the stdout — return a well-formed
                // fake response so it doesn't throw.
                return ("note-id-x\tfake-title", nil)
            }
            // Title stays constant so the env-equality assertion only
            // varies on the body key. Folder nil so the simpler atClause
            // shape is exercised.
            _ = try? NotesIntegration.createNote(title: "fixed-title", body: payload, folder: nil)
            // NotesIntegration converts body via markdownToNotesHTML before
            // placing it in env. The corpus's expected value is the raw
            // payload, but env carries the HTML form. Translate back so
            // the assertion logic stays uniform.
            if let html = captured.env["APPLE_TOOLS_NOTES_BODY"] {
                captured.env["APPLE_TOOLS_NOTES_BODY"] = htmlToPayload(html)
            }
            return captured
        }
    )
}

private func emailCreateDraftIntegration() -> AppleScriptEscapingCorpusTests.AppleScriptIntegration {
    return .init(
        name: "EmailIntegration.createDraft(body)",
        envKey: "APPLE_TOOLS_EMAIL_BODY",
        execute: { payload in
            var captured: (script: String, env: [String: String]) = ("", [:])
            let saved = EmailIntegration.runAppleScript
            defer { EmailIntegration.runAppleScript = saved }
            EmailIntegration.runAppleScript = { script, env, _ in
                captured = (script, env)
                return ("draft-id-x", nil)
            }
            try? EmailIntegration.createDraft(
                to: "test@example.com",
                subject: "fixed-subject",
                body: payload,
                cc: nil,
                attachments: []
            )
            return captured
        }
    )
}

private func userConfirmationIntegration() -> AppleScriptEscapingCorpusTests.AppleScriptIntegration {
    return .init(
        name: "UserConfirmation.requestConfirmation(message)",
        envKey: "APPLE_TOOLS_CONFIRM_MESSAGE",
        execute: { payload in
            var captured: (script: String, env: [String: String]) = ("", [:])
            let saved = UserConfirmation.runAppleScript
            // Confirmation dialogs are opt-in (off by default); enable the
            // gate so the AppleScript path actually runs and we can pin its
            // escaping invariant.
            setenv("APPLE_TOOLS_CONFIRM", "1", 1)
            defer {
                UserConfirmation.runAppleScript = saved
                unsetenv("APPLE_TOOLS_CONFIRM")
            }
            UserConfirmation.runAppleScript = { script, env in
                captured = (script, env)
                return ("button returned:Deny", true)
            }
            _ = UserConfirmation.requestConfirmation(title: "fixed-title", message: payload)
            return captured
        }
    )
}

// MARK: - Helpers

/// Reverse of `NotesMarkdown.markdownToNotesHTML` for plain-text payloads
/// (no Markdown markers, as in this corpus). Each `<div>…</div>` is
/// one line; `<div><br></div>` is an empty line; HTML entities decode
/// back to their source characters.
///
/// Used so the corpus can assert against the *original* payload even
/// though Notes stores it as HTML on the env side.
private func htmlToPayload(_ html: String) -> String {
    var lines: [String] = []
    var rest = html[...]
    while let start = rest.range(of: "<div>") {
        let after = start.upperBound
        guard let end = rest.range(of: "</div>", range: after..<rest.endIndex) else { break }
        let inner = rest[after..<end.lowerBound]
        if inner == "<br>" {
            lines.append("")
        } else {
            lines.append(decodeHTMLEntities(String(inner)))
        }
        rest = rest[end.upperBound...]
    }
    return lines.joined(separator: "\n")
}

private func decodeHTMLEntities(_ s: String) -> String {
    return s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
}
