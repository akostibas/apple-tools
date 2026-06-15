import Foundation

/// Markdown -> plain text for outbound iMessage bodies.
///
/// The assistant speaks Markdown, but Messages.app renders it as raw syntax: there
/// is no scripting API to send attributed text through the `send` verb (the
/// native bold/italic in macOS 15 / iOS 18 is GUI-only). Rather than ship
/// `**bold**` noise to the recipient, we strip emphasis markers while keeping
/// the structure that still reads well in a plain bubble — bullet and numbered
/// lists, line breaks, and link URLs (which Messages makes tappable).
///
/// The rule of thumb is "drop markers that don't help, keep structure that
/// does": `**Title**` becomes `Title`, but a bullet list stays a bullet list.
public enum IMessageMarkdown {

    /// Convert a Markdown body to the plain text we actually send.
    public static func toPlainText(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks: drop the ``` lines, emit content verbatim so
            // we don't mangle code with the inline stripper.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(line)
                continue
            }

            // Horizontal rules (---, ***, ___) carry no text — drop them.
            if isHorizontalRule(trimmed) {
                continue
            }

            // Headings: drop the leading #s, keep (and inline-strip) the text.
            if let heading = headingText(trimmed) {
                out.append(stripInline(heading))
                continue
            }

            // Blockquote: drop the leading "> ", keep the quoted text.
            if trimmed.hasPrefix(">") {
                let quoted = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                out.append(stripInline(quoted))
                continue
            }

            // Bullets (-, *, +, and - [ ] / - [x] checklists): normalize the
            // marker to "• " and preserve indentation so nested lists still
            // read as nested.
            if let (indent, content) = bulletItem(line) {
                out.append("\(indent)• \(stripInline(content))")
                continue
            }

            // Numbered lists: keep the "N. " marker as-is.
            if let (indent, marker, content) = orderedItem(line) {
                out.append("\(indent)\(marker) \(stripInline(content))")
                continue
            }

            out.append(stripInline(line))
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Block helpers

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed.replacingOccurrences(of: " ", with: ""))
        return chars == ["-"] || chars == ["*"] || chars == ["_"]
    }

    /// Return the heading text (everything after the leading `#`s) or nil.
    private static func headingText(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("#") else { return nil }
        var hashes = 0
        for c in trimmed {
            if c == "#" { hashes += 1 } else { break }
        }
        guard hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // ATX headings require a space after the #s ("# x"); "#tag" is not one.
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// Split a bullet line into (leading indentation, item content), or nil.
    private static func bulletItem(_ line: String) -> (indent: String, content: String)? {
        let indent = leadingWhitespace(line)
        let body = line.dropFirst(indent.count)
        guard body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") else {
            return nil
        }
        var content = String(body.dropFirst(2))
        // Checklist markers reduce to their text — Messages has no checkboxes.
        if content.hasPrefix("[ ] ") { content = String(content.dropFirst(4)) }
        else if content.lowercased().hasPrefix("[x] ") { content = String(content.dropFirst(4)) }
        return (indent, content)
    }

    /// Split a numbered line into (indent, "N.", content), or nil.
    private static func orderedItem(_ line: String) -> (indent: String, marker: String, content: String)? {
        let indent = leadingWhitespace(line)
        let body = line.dropFirst(indent.count)
        guard let dot = body.firstIndex(of: ".") else { return nil }
        let numPart = body[body.startIndex..<dot]
        guard !numPart.isEmpty, numPart.allSatisfy({ $0.isNumber }) else { return nil }
        let after = body[body.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return (indent, "\(numPart).", String(after.dropFirst()))
    }

    private static func leadingWhitespace(_ line: String) -> String {
        return String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    // MARK: - Inline stripping

    /// Characters that Markdown lets you backslash-escape. We swap an escaped
    /// occurrence for a private-use sentinel before stripping so the emphasis
    /// regexes can't mistake a literal `\*` for an emphasis marker, then map the
    /// sentinel back to the bare character at the end.
    private static let escapable: [Character] = ["*", "_", "`", "#", "~", "[", "]", "(", ")", "-", ">", "\\"]
    private static let sentinelBase: UInt32 = 0xE000  // Unicode private-use area

    /// Remove inline emphasis markers from a single line, keeping the text.
    ///
    /// Spans whose contents must NOT be touched by the emphasis pass (inline
    /// code, and link/image URLs) are pulled out into placeholders first, then
    /// restored at the end. This is what keeps `snake_case` identifiers and
    /// `https://x.com/a_b_c` URLs intact — otherwise the `_..._` rule would eat
    /// their underscores.
    static func stripInline(_ line: String) -> String {
        var store: [String] = []
        var s = protectEscapes(line)
        s = protectCodeSpans(s, &store)
        s = transformLinks(s, &store)
        s = stripEmphasis(s)
        s = restorePlaceholders(s, store)
        s = restoreEscapes(s)
        return s
    }

    private static func protectEscapes(_ s: String) -> String {
        var out = s
        for (i, ch) in escapable.enumerated() {
            let sentinel = String(UnicodeScalar(sentinelBase + UInt32(i))!)
            out = out.replacingOccurrences(of: "\\\(ch)", with: sentinel)
        }
        return out
    }

    private static func restoreEscapes(_ s: String) -> String {
        var out = s
        for (i, ch) in escapable.enumerated() {
            let sentinel = String(UnicodeScalar(sentinelBase + UInt32(i))!)
            out = out.replacingOccurrences(of: sentinel, with: String(ch))
        }
        return out
    }

    // MARK: Placeholder store
    //
    // Protected spans are replaced with `\u{E100}<index>\u{E101}` tokens. The
    // index is plain ASCII digits, which the emphasis regexes pass through
    // untouched; restorePlaceholders swaps each token back for its text.

    private static let placeholderOpen = "\u{E100}"
    private static let placeholderClose = "\u{E101}"

    private static func stash(_ text: String, _ store: inout [String]) -> String {
        store.append(text)
        return "\(placeholderOpen)\(store.count - 1)\(placeholderClose)"
    }

    private static func restorePlaceholders(_ s: String, _ store: [String]) -> String {
        var out = s
        for (i, text) in store.enumerated() {
            out = out.replacingOccurrences(of: "\(placeholderOpen)\(i)\(placeholderClose)", with: text)
        }
        return out
    }

    /// Strip the backticks from inline code and stash the inner text so the
    /// emphasis pass can't reinterpret characters inside it.
    private static func protectCodeSpans(_ s: String, _ store: inout [String]) -> String {
        return replaceMatches(s, #"`([^`]+)`"#) { groups in
            stash(groups[1], &store)
        }
    }

    /// `![alt](url)` -> url, `[text](url)` -> "text (url)" (bare/empty -> url).
    /// The URL is stashed so its underscores/asterisks survive the emphasis pass.
    private static func transformLinks(_ s: String, _ store: inout [String]) -> String {
        var result = replaceMatches(s, #"!\[[^\]]*\]\(([^)]+)\)"#) { groups in
            stash(groups[1], &store)
        }
        result = replaceMatches(result, #"\[([^\]]*)\]\(([^)]+)\)"#) { groups in
            let text = groups[1]
            let url = groups[2]
            if text.isEmpty || text == url {
                return stash(url, &store)
            }
            return "\(text) (\(stash(url, &store)))"
        }
        return result
    }

    /// Remove emphasis markers. Flanking guards (`(?=\S)` / `(?<=\S)`) keep
    /// space-padded markers like "a * b * c" from matching, and the word-edge
    /// guards on `_` keep intra-word underscores (snake_case) from matching —
    /// both mirror CommonMark's flanking rules closely enough for plain output.
    private static func stripEmphasis(_ s: String) -> String {
        var out = s
        // Strikethrough and asterisk emphasis: triple before double before single.
        out = replace(out, #"~~(?=\S)(.+?)(?<=\S)~~"#, "$1")
        out = replace(out, #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, "$1")
        out = replace(out, #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "$1")
        out = replace(out, #"\*(?=\S)([^*]+?)(?<=\S)\*"#, "$1")
        // Underscore emphasis: only when both markers sit on a word edge.
        out = replace(out, #"(?<![A-Za-z0-9])___(?=\S)(.+?)(?<=\S)___(?![A-Za-z0-9])"#, "$1")
        out = replace(out, #"(?<![A-Za-z0-9])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9])"#, "$1")
        out = replace(out, #"(?<![A-Za-z0-9])_(?=\S)([^_]+?)(?<=\S)_(?![A-Za-z0-9])"#, "$1")
        return out
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    /// Replace every match of `pattern`, computing each replacement from its
    /// capture groups (group 0 is the whole match). Walks matches in reverse so
    /// earlier ranges stay valid as we mutate the string.
    private static func replaceMatches(_ s: String, _ pattern: String,
                                       _ build: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        let matches = re.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for m in matches.reversed() {
            guard let full = Range(m.range, in: result) else { continue }
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                if let r = Range(m.range(at: g), in: result) {
                    groups.append(String(result[r]))
                } else {
                    groups.append("")
                }
            }
            result.replaceSubrange(full, with: build(groups))
        }
        return result
    }
}
