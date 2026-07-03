import Foundation

/// Decodes the small set of HTML entities that appear in Notes and Mail body
/// text. Shared so the ordering rule lives in exactly one place.
///
/// The decode order is load-bearing: `&amp;` MUST be decoded LAST. Decoding it
/// first turns a doubly-escaped sequence like `&amp;lt;` (whose visible text is
/// `&lt;`) into `<`, corrupting write->read round-trips of any text containing
/// `&`, `<`, or `>` (issue #29). Named/numeric entities are decoded first;
/// `&amp;` -> `&` is the final step. Never rely on Dictionary iteration order
/// for this.
enum HTMLEntities {
    private static let ordered: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ("&amp;", "&"),
    ]

    /// Legacy semicolon-LESS forms. Apple Notes' AppleScript `body` serializes
    /// entities without a trailing `;` (`&amp`, `&lt`), so a note containing
    /// `&`, `<`, or `>` reads back corrupted unless these are decoded too
    /// (issue #39). `&amp` stays last, preserving the same invariant as the
    /// semicolon set.
    ///
    /// Only applied when `legacy: true` — i.e. for Notes body text. It is NOT
    /// safe for general HTML (email): a bare `&lt` would mangle literal text
    /// like a `?a=1&ltd=2` URL. Within Notes output it is safe in practice,
    /// because Notes serializes every literal `&` as `&amp`, so any residual
    /// `&lt` genuinely came from a `<`.
    private static let legacyOrdered: [(String, String)] = [
        ("&lt", "<"), ("&gt", ">"), ("&quot", "\""), ("&nbsp", " "),
        ("&amp", "&"),
    ]

    /// Decode the basic entity set, `&amp;` last (see type doc). Pass
    /// `legacy: true` for Apple Notes body text to also decode the
    /// semicolon-less forms (issue #39).
    static func decodeBasic(_ s: String, legacy: Bool = false) -> String {
        var out = s
        for (k, v) in ordered { out = out.replacingOccurrences(of: k, with: v) }
        if legacy {
            // Decode a bare form ONLY when it is not followed by `;`. A trailing
            // `;` means either the semicolon pass above already consumed it, or
            // it is an intentionally-escaped literal like `&lt;` that must be
            // preserved (the #29 invariant — otherwise `&amp;lt;` -> `&lt;`
            // would then wrongly become `<;`). `&amp` stays last.
            for (k, v) in legacyOrdered {
                out = out.replacingOccurrences(
                    of: "\(NSRegularExpression.escapedPattern(for: k))(?!;)",
                    with: v,
                    options: .regularExpression
                )
            }
        }
        return out
    }
}
