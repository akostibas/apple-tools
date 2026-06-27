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

    /// Local-part tokens that mark an address as a non-human / automated
    /// sender. Matched as whole tokens OR substrings of the local-part
    /// (role addresses like `no-reply+123@` and `bounce-foo@` are common).
    static let bulkLocalPartNeedles: [String] = [
        "postmaster", "mailer-daemon", "mailerdaemon", "mailer",
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
        "bounce", "bounces", "bot", "notification", "notifications", "notify",
        "newsletter", "marketing", "no.reply", "auto-confirm", "automailer",
    ]

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

        // Local-part signals (substring — role addresses append suffixes).
        for needle in bulkLocalPartNeedles where local.contains(needle) {
            score += 2
            break
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
}
