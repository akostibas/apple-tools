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

    /// Decode the basic entity set, `&amp;` last (see type doc).
    static func decodeBasic(_ s: String) -> String {
        var out = s
        for (k, v) in ordered { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
