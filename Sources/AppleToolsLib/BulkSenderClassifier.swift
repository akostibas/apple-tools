import Foundation

/// Heuristic classifier for "likely automated / bulk sender" messages —
/// postmaster bots, no-reply mailers, marketing blasts, list traffic, etc.
///
/// Kept deliberately small and dependency-free with a clean input
/// (`address` + optional `name` + optional `Headers`) → `Bool` / score, so
/// the same logic can be reused beyond email. This is the integration point
/// with issue #9's iMessage half: an iMessage "bulk/automated sender" lane
/// (shortcode senders, no-reply SMS gateways) should call into this same
/// type rather than reimplementing the heuristic. The `Headers` input is
/// optional so callers that only have an address (search results, iMessage
/// handles) can still classify, while callers that have parsed MIME headers
/// (the email `read` path) can pass `List-Unsubscribe` / `Precedence` for a
/// stronger signal.
public enum BulkSenderClassifier {

    /// Optional message headers that strengthen the signal when available.
    /// All fields optional — pass what you have.
    public struct Headers {
        /// Value of the `List-Unsubscribe` header, if present (its mere
        /// presence is a strong bulk signal — RFC 2369 list mail).
        public var listUnsubscribe: String?
        /// Value of the `Precedence` header, if present (`bulk`, `list`,
        /// `junk` all indicate non-personal mail).
        public var precedence: String?
        /// Value of `Auto-Submitted`, if present (`auto-generated`,
        /// `auto-replied` → machine-sent).
        public var autoSubmitted: String?

        public init(listUnsubscribe: String? = nil, precedence: String? = nil, autoSubmitted: String? = nil) {
            self.listUnsubscribe = listUnsubscribe
            self.precedence = precedence
            self.autoSubmitted = autoSubmitted
        }
    }

    /// Distinctive local-part tokens that mark an address as a non-human /
    /// automated sender. Long/specific enough to match as bare SUBSTRINGS
    /// without colliding with human names (role addresses like `no-reply+123@`
    /// and `bounce-foo@` append suffixes, so substring matching is intended).
    static let bulkSubstringNeedles: [String] = [
        "postmaster", "mailer-daemon", "mailerdaemon",
        "noreply", "no-reply", "no_reply", "no.reply",
        "donotreply", "do-not-reply", "do_not_reply",
        "bounces", "notification", "notifications",
        "newsletter", "marketing", "auto-confirm", "automailer",
    ]

    /// SHORT / ambiguous local-part tokens that are substrings of common human
    /// surnames (`bot` in `talbot`/`abbot`, `mailer` in a name, `bounce`).
    /// Matched only as bounded tokens — the character on each side must be the
    /// string edge or a non-letter (a separator or digit), so `bounce-123@` and
    /// `weekly-bot@` still trip while `talbot@` no longer does (issue #36).
    /// The deliberate cost: a letter-concatenated form like `pinbot@` won't
    /// match on `bot` alone — precision over recall, since `--humans-only`
    /// hiding real people was the reported harm.
    static let bulkBoundaryNeedles: [String] = [
        "bot", "mailer", "bounce", "notify",
    ]

    /// Display-name tokens that signal automated / list mail. Kept to strings
    /// that don't appear in ordinary personal names; ` via ` catches the
    /// ESP "Sender via Mailchimp" shape (RFC 5322 on-behalf-of).
    static let bulkNameNeedles: [String] = [
        "no-reply", "noreply", "no reply", "do not reply", "donotreply",
        "newsletter", "notification", "notifications", " via ", "automated",
    ]

    /// True if `needle` occurs in `haystack` bounded on both sides by the
    /// string edge or a non-letter character. Both are assumed lowercased.
    static func containsBoundedNeedle(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let h = Array(haystack)
        let n = Array(needle)
        guard h.count >= n.count else { return false }
        var i = 0
        while i <= h.count - n.count {
            if Array(h[i..<(i + n.count)]) == n {
                let beforeOK = (i == 0) || !h[i - 1].isLetter
                let afterIdx = i + n.count
                let afterOK = (afterIdx == h.count) || !h[afterIdx].isLetter
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    /// ESP / bulk-mail infrastructure domains. Matched as substrings of the
    /// domain — these tokens are specific enough not to collide with normal
    /// domains.
    static let bulkDomainNeedles: [String] = [
        "mailchimp", "sendgrid", "mailgun", "sparkpostmail", "amazonses",
        "mandrillapp", "sendinblue", "constantcontact", "exacttarget",
        "mcsv.net", "mcdlv.net", "rsgsv.net", "list-manage",
    ]

    /// Leading subdomain LABELS that signal a marketing / transactional send
    /// (e.g. `email.brand.com`, `engage.canva.com`). Matched only as the FIRST
    /// label of a domain that actually HAS a subdomain, so `gmail.com` (label
    /// `gmail`, no subdomain) is never flagged.
    static let bulkSubdomainLabels: Set<String> = [
        "email", "mail", "e", "em", "news", "newsletter", "mktg", "marketing",
        "engage", "reply", "bounce", "bounces", "mailer", "info", "notify",
    ]

    /// True if the sender looks like an automated / bulk sender.
    ///
    /// - Parameters:
    ///   - address: full email address (or an iMessage handle / shortcode).
    ///   - name: optional display name.
    ///   - headers: optional message headers (stronger signal when present).
    public static func isLikelyBulk(address: String, name: String? = nil, headers: Headers? = nil) -> Bool {
        return score(address: address, name: name, headers: headers) > 0
    }

    /// A small integer confidence score (0 = looks human). Each independent
    /// signal adds 1+. Exposed so callers can threshold differently later
    /// (and so the iMessage lane can reuse the same scoring).
    public static func score(address: String, name: String? = nil, headers: Headers? = nil) -> Int {
        var score = 0
        let addr = address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let local: String
        let domain: String
        if let at = addr.firstIndex(of: "@") {
            local = String(addr[addr.startIndex..<at])
            domain = String(addr[addr.index(after: at)...])
        } else {
            local = addr
            domain = ""
        }

        // Local-part signals: distinctive tokens match as substrings; short,
        // name-colliding tokens (`bot`, `mailer`, …) only as bounded tokens.
        let localHit = bulkSubstringNeedles.contains { local.contains($0) }
            || bulkBoundaryNeedles.contains { containsBoundedNeedle(local, $0) }
        if localHit { score += 2 }

        // Display-name signals (the documented `name` parameter — previously
        // accepted but never read). A "… via Mailchimp" or "No Reply" display
        // name is a bulk signal even when the address looks innocuous.
        if let nm = name?.lowercased(), bulkNameNeedles.contains(where: { nm.contains($0) }) {
            score += 1
        }

        // Domain-shape signals (ESP infra / marketing subdomains).
        if !domain.isEmpty {
            for needle in bulkDomainNeedles where domain.contains(needle) {
                score += 1
                break
            }
            // Marketing/transactional leading subdomain label, e.g.
            // `email.brand.com` or `engage.canva.com`. Requires an actual
            // subdomain (>= 3 labels) so apex domains like `gmail.com` are safe.
            let labels = domain.split(separator: ".").map(String.init)
            if labels.count >= 3, let first = labels.first, bulkSubdomainLabels.contains(first) {
                score += 1
            }
        }

        // Header signals (only present on the read path).
        if let h = headers {
            if let lu = h.listUnsubscribe, !lu.trimmingCharacters(in: .whitespaces).isEmpty {
                score += 2
            }
            if let p = h.precedence?.lowercased(),
               p.contains("bulk") || p.contains("list") || p.contains("junk") {
                score += 2
            }
            if let a = h.autoSubmitted?.lowercased(), a.contains("auto") {
                score += 1
            }
        }

        return score
    }

    // MARK: - iMessage / SMS lane (issue #9)
    //
    // The phone analogue of a bulk email sender is a marketing SHORT CODE or a
    // sender the system's SMS filtering has bucketed as promotional /
    // transactional. Messages records the latter by appending an UNDOCUMENTED
    // suffix to the chat identifier (and handle id):
    //   `(smsfp)` — SMS Filtered Promotional
    //   `(smsft)` — SMS Filtered Transactional
    // These are not in any Apple doc, so without this helper a caller would
    // have to know the magic suffix to filter noise. Exposing it here keeps a
    // single shared "likely automated/bulk sender" classification across the
    // email and iMessage tools.

    /// SMS-filtering suffixes Messages appends to a chat/handle identifier when
    /// the system has bucketed the sender as filtered promotional/transactional.
    /// Their mere presence is a strong bulk/automated signal.
    public static let smsFilterSuffixes: [String] = ["(smsfp)", "(smsft)"]

    /// True if the identifier carries a trailing SMS-filtering suffix.
    public static func hasSMSFilterSuffix(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        return smsFilterSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Return the bare handle with any trailing SMS-filtering suffix removed.
    /// The raw identifier is preserved by callers; this is only for shape
    /// analysis / contact matching.
    public static func stripSMSFilterSuffix(_ identifier: String) -> String {
        var s = identifier
        let lower = s.lowercased()
        for suffix in smsFilterSuffixes where lower.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// True if a phone-style identifier is a marketing/automation SHORT CODE:
    /// a bare 5-6 digit number with no `+` country prefix and no `@` (so real
    /// 10/11-digit phone numbers and email handles are never flagged). Any
    /// trailing SMS-filtering suffix is stripped before the check.
    public static func isShortcode(_ identifier: String) -> Bool {
        let bare = stripSMSFilterSuffix(identifier)
        guard !bare.isEmpty, !bare.contains("@"), !bare.hasPrefix("+") else { return false }
        // Must be ALL digits (a shortcode has no separators/letters).
        guard bare.allSatisfy({ $0.isNumber }) else { return false }
        return (5...6).contains(bare.count)
    }

    /// Unified "likely automated/bulk sender" check for an iMessage/SMS handle.
    /// The phone-side mirror of `isLikelyBulk(address:)`. Signals (any one trips it):
    ///   - a `(smsfp)`/`(smsft)` SMS-filtering suffix on the identifier,
    ///   - a 5-6 digit short-code number shape,
    ///   - email-handle bulk markers (e.g. no-reply SMS gateways) via `score`.
    /// A handle that cleanly resolves to a Contacts name is a real person and is
    /// NEVER flagged — `hasContactName` short-circuits to `false`.
    public static func isLikelyBulkMessage(chatID: String, hasContactName: Bool = false) -> Bool {
        if hasContactName { return false }
        if hasSMSFilterSuffix(chatID) { return true }
        let bare = stripSMSFilterSuffix(chatID)
        if isShortcode(bare) { return true }
        // Reuse the email heuristic for letter-bearing handles (e.g. an SMS
        // gateway address like `noreply@txt.example.com`). Pure phone numbers
        // score 0 here, so this never false-flags a normal number.
        return score(address: bare) > 0
    }
}
