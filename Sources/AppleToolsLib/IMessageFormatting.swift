import Foundation
import AppleToolsObjC

/// Inbound iMessage formatting -> Markdown.
///
/// macOS 15 / iOS 18 added bold/italic/etc. text formatting to Messages. On the
/// wire it rides in the message's `attributedBody` typedstream as attribute runs
/// keyed by IMCore names (`__kIMTextBoldAttributeName`, …). The probe's plain
/// decoder throws those attributes away; this converts them to Markdown so the
/// agent sees the emphasis the user actually applied — the inbound mirror of the
/// outbound `IMessageMarkdown` flattening.
///
/// Decoding goes through `AppleToolsSafeUnarchiveAttributedString` (an ObjC shim
/// over the deprecated `NSUnarchiver`, the only reader for this format) which
/// returns nil rather than throwing on a corrupt blob.
public enum IMessageFormatting {

    // IMCore attribute keys. Bold/italic are verified against a real macOS 26
    // attributedBody fixture (see IMessageFormattingTests). Strikethrough's key
    // follows the same naming and is best-effort: if the real name differs it
    // simply won't match, leaving that run as plain text (no regression).
    static let boldKey = "__kIMTextBoldAttributeName"
    static let italicKey = "__kIMTextItalicAttributeName"
    static let strikeKey = "__kIMTextStrikethroughAttributeName"

    /// Convert a hex-encoded `attributedBody` blob to Markdown, or nil.
    public static func attributedBodyToMarkdown(hex: String) -> String? {
        guard let bytes = IMessageIntegration.dataFromHex(hex) else { return nil }
        return attributedBodyToMarkdown(data: Data(bytes))
    }

    /// Best-effort body text from a hex-encoded `attributedBody` blob: Markdown
    /// when the message carries formatting, otherwise the plain byte-scan decode.
    ///
    /// This is the single decode policy for every chat.db reader — the inbound
    /// hook and the read tool both route through it — so no reader can silently
    /// skip formatting recovery (the bug that shipped when only the hook was
    /// wired). Returns nil only when both decoders fail; callers add `?? ""`.
    public static func bodyText(hex: String) -> String? {
        return attributedBodyToMarkdown(hex: hex) ?? IMessageIntegration.decodeAttributedBody(hex: hex)
    }

    /// Convert an `attributedBody` blob to Markdown.
    ///
    /// Returns nil when the blob can't be decoded OR carries no text formatting.
    /// A nil result tells the caller to fall back to the existing plain-text
    /// decoder, so every non-formatted message keeps its current behavior and
    /// only genuinely-formatted messages take this new path.
    public static func attributedBodyToMarkdown(data: Data) -> String? {
        guard let attr = AppleToolsSafeUnarchiveAttributedString(data) else { return nil }
        return runsToMarkdown(attr)
    }

    static func runsToMarkdown(_ attr: NSAttributedString) -> String? {
        let full = attr.string as NSString
        var out = ""
        var sawFormatting = false

        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length), options: []) { attrs, range, _ in
            var text = full.substring(with: range)
            // Drop attachment placeholders; their runs carry no useful text.
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            if text.isEmpty { return }

            let bold = attrs[NSAttributedString.Key(rawValue: boldKey)] != nil
            let italic = attrs[NSAttributedString.Key(rawValue: italicKey)] != nil
            let strike = attrs[NSAttributedString.Key(rawValue: strikeKey)] != nil

            if bold || italic || strike {
                sawFormatting = true
                out += wrap(text, bold: bold, italic: italic, strike: strike)
            } else {
                out += text
            }
        }

        return sawFormatting ? out : nil
    }

    /// Wrap a run's text in Markdown markers, keeping any leading/trailing
    /// whitespace outside the markers so the emphasis is well-formed
    /// (`**bold** ` not `**bold **`).
    private static func wrap(_ text: String, bold: Bool, italic: Bool, strike: Bool) -> String {
        let chars = Array(text)
        var lead = 0
        while lead < chars.count, chars[lead].isWhitespace { lead += 1 }
        if lead == chars.count { return text } // all whitespace
        var trail = chars.count
        while trail > lead, chars[trail - 1].isWhitespace { trail -= 1 }

        let leading = String(chars[0..<lead])
        let core = String(chars[lead..<trail])
        let trailing = String(chars[trail..<chars.count])

        var marker = ""
        if bold { marker += "**" }
        if italic { marker += "*" }
        var wrapped = marker + core + marker
        if strike { wrapped = "~~" + wrapped + "~~" }

        return leading + wrapped + trailing
    }
}
