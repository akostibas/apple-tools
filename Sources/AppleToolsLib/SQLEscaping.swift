import Foundation

/// SQLite `LIKE`-pattern escaping shared across every tool that builds a
/// `LIKE` query from user-supplied text (iMessage/Notes/Photos search, Mail
/// draft verification).
///
/// SQLite treats `%` and `_` as wildcards inside `LIKE`, so an unescaped user
/// query such as `100%` or `is_a` matches far more than intended. Escaping
/// them (and the escape character itself) and pairing the pattern with an
/// `ESCAPE '\'` clause makes the query match the literal text.
///
/// This is the single source of truth: call sites use
/// `SQLEscaping.escapeLIKE(_:)` rather than keeping private per-type copies.
enum SQLEscaping {
    /// Escape `\`, `%`, and `_` for use in a `LIKE ? ESCAPE '\'` pattern.
    /// Order matters: the backslash must be doubled first so the escapes added
    /// for `%`/`_` are not themselves re-escaped.
    static func escapeLIKE(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
    }
}
