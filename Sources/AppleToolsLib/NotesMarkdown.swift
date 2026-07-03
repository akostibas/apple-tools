import Foundation

/// Markdown <-> Apple Notes HTML translation.
///
/// The `notes` tool speaks Markdown on the LLM side; Apple Notes stores an
/// HTML `body`. These converters bridge the two. Fidelity is bounded by what
/// the AppleScript `body` API actually round-trips (validated empirically on
/// macOS 15 — see docs/reference/macos-internals/apple-notes-applescript.md):
///
///  - Headings: Notes has no heading tags; H1/H2 are bold + a font-size span
///    (24px / 18px). We emit `<h1>`/`<h2>` (Notes normalizes them to the span
///    form) and read both shapes back.
///  - Bold / italic / strikethrough / monospaced: round-trip via
///    `<b>`/`<i>`/`<strike>`/`<tt>`.
///  - Bulleted and numbered lists: round-trip via `<ul>`/`<ol>`.
///  - Links: Notes strips `href` on write, so we render `[text](url)` as
///    `text (url)` plain text on write; on read we still parse `<a href>` in
///    case a note carries one.
///  - Checklists: Notes strips checklist markup on write, so they can't be
///    created (rendered as plain bullets). Checked/unchecked *state* is read
///    separately from the protobuf store — see NotesChecklistStore.
public enum NotesMarkdown {

    // MARK: - Markdown -> Notes HTML (write path)

    public static func markdownToNotesHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html = ""
        var i = 0

        func flushListGroup(ordered: Bool, items: [String]) {
            let tag = ordered ? "ol" : "ul"
            html += "<\(tag)>"
            for item in items { html += "<li>\(inlineToHTML(item))</li>" }
            html += "</\(tag)>"
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Unordered / checklist list group
            if let _ = bulletContent(trimmed) {
                var items: [String] = []
                while i < lines.count,
                      let content = bulletContent(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(content)
                    i += 1
                }
                flushListGroup(ordered: false, items: items)
                continue
            }

            // Ordered list group
            if let _ = orderedContent(trimmed) {
                var items: [String] = []
                while i < lines.count,
                      let content = orderedContent(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(content)
                    i += 1
                }
                flushListGroup(ordered: true, items: items)
                continue
            }

            // Headings
            if trimmed.hasPrefix("### ") {
                html += "<div><h2>\(inlineToHTML(String(trimmed.dropFirst(4))))</h2></div>"
            } else if trimmed.hasPrefix("## ") {
                html += "<div><h2>\(inlineToHTML(String(trimmed.dropFirst(3))))</h2></div>"
            } else if trimmed.hasPrefix("# ") {
                html += "<div><h1>\(inlineToHTML(String(trimmed.dropFirst(2))))</h1></div>"
            } else if line.isEmpty {
                html += "<div><br></div>"
            } else {
                html += "<div>\(inlineToHTML(line))</div>"
            }
            i += 1
        }
        return html
    }

    /// Strip a leading list marker, returning the item content, or nil if the
    /// line isn't a bullet. Checklist markers (`- [ ]`, `- [x]`) are reduced to
    /// their text since Notes can't store real checkboxes.
    private static func bulletContent(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        var content = String(line.dropFirst(2))
        if content.hasPrefix("[ ] ") { content = String(content.dropFirst(4)) }
        else if content.lowercased().hasPrefix("[x] ") { content = String(content.dropFirst(4)) }
        return content
    }

    private static func orderedContent(_ line: String) -> String? {
        // N. content
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let numPart = line[line.startIndex..<dot]
        guard !numPart.isEmpty, numPart.allSatisfy({ $0.isNumber }) else { return nil }
        let after = line[line.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return String(after.dropFirst())
    }

    /// Convert inline Markdown within a single line to Notes HTML.
    static func inlineToHTML(_ line: String) -> String {
        var s = NotesIntegration.escapeHTML(line)
        // Order matters: code first (so its contents aren't reinterpreted),
        // then bold before italic, then strikethrough, then links.
        s = replace(s, #"`([^`]+)`"#, "<tt>$1</tt>")
        s = replace(s, #"\*\*([^*]+)\*\*"#, "<b>$1</b>")
        s = replace(s, #"__([^_]+)__"#, "<b>$1</b>")
        s = replace(s, #"\*([^*]+)\*"#, "<i>$1</i>")
        s = replace(s, #"~~([^~]+)~~"#, "<strike>$1</strike>")
        // Links can't carry href through Notes; render as "text (url)".
        s = replace(s, #"\[([^\]]+)\]\(([^)]+)\)"#, "$1 ($2)")
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    // MARK: - Notes HTML -> Markdown (read path)

    /// Convert a Notes `body` HTML string to Markdown. `title`, if given, is
    /// stripped from the leading line (Notes prepends the note title to body).
    /// `checklist`, if given, maps list-item text to checked state and is
    /// overlaid onto matching bullets as `- [ ]` / `- [x]`.
    public static func notesHTMLToMarkdown(_ html: String,
                                           title: String? = nil,
                                           checklist: [(text: String, done: Bool)] = []) -> String {
        var lines = htmlToLines(html)

        // Drop a leading line that just repeats the title.
        if let title = title, let first = lines.first {
            let bare = first.drop(while: { $0 == "#" || $0 == " " })
            if String(bare) == title { lines.removeFirst() }
        }

        // Overlay checklist state onto matching plain bullets, in order.
        if !checklist.isEmpty {
            var queue = checklist
            lines = lines.map { line in
                guard line.hasPrefix("- "), !line.hasPrefix("- [") else { return line }
                let text = String(line.dropFirst(2))
                if let idx = queue.firstIndex(where: { $0.text == text }) {
                    let done = queue[idx].done
                    queue.remove(at: idx)
                    return "- [\(done ? "x" : " ")] \(text)"
                }
                return line
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Splice link URLs recovered from the protobuf store onto matching display
    /// text in already-converted Markdown. Apple Notes drops `href` from the
    /// AppleScript body, so the canonical URLs come from NotesChecklistStore;
    /// this is the read-side overlay (mirrors the checklist overlay).
    ///
    /// Best-effort and order-preserving: links are applied left-to-right with a
    /// forward cursor so repeated display text ("here", "example") maps to the
    /// right URL as long as Markdown order tracks the note's text order.
    ///  - Bare links (display text == URL) are left as the plain URL — no
    ///    `[url](url)` noise.
    ///  - A span already rendered as `[text](url)` (the in-body href echo) is
    ///    skipped so it isn't double-wrapped.
    public static func overlayLinks(_ markdown: String,
                                    links: [(text: String, url: String)]) -> String {
        guard !links.isEmpty else { return markdown }
        var result = markdown
        var cursor = result.startIndex
        for link in links where !link.text.isEmpty {
            // Already linked from the in-body href echo — advance past, no rewrap.
            if result.range(of: "](\(link.url))") != nil {
                if let r = result.range(of: link.text, range: cursor..<result.endIndex) {
                    cursor = r.upperBound
                }
                continue
            }
            guard let r = result.range(of: link.text, range: cursor..<result.endIndex) else {
                continue
            }
            // Bare link: the URL already is its own visible text. Skip wrapping.
            if link.text == link.url {
                cursor = r.upperBound
                continue
            }
            let replacement = "[\(link.text)](\(link.url))"
            let lowerOffset = result.distance(from: result.startIndex, to: r.lowerBound)
            result.replaceSubrange(r, with: replacement)
            cursor = result.index(result.startIndex, offsetBy: lowerOffset + replacement.count)
        }
        return result
    }

    /// Tokenizer: walk the Notes HTML and emit Markdown lines.
    private static func htmlToLines(_ html: String) -> [String] {
        // Notes formats the HTML with literal newlines around block tags; they
        // carry no content, so drop them.
        let cleaned = html.replacingOccurrences(of: "\n", with: "")
                          .replacingOccurrences(of: "\r", with: "")
        let chars = Array(cleaned)
        var i = 0

        var lines: [String] = []
        var line = ""
        var prefix = ""              // heading / list marker for the current line
        var orderedCounters: [Int] = []
        var listOrdered: [Bool] = []
        var linkHref: String? = nil
        var linkOpenLen = 0              // line length when the current <a> opened
        var pendingHeadingClose = false  // swallow the heading span's </span></b>
        var justFlushed = false          // coalesce a trailing <br> before </div>
        var fontMonoStack: [Bool] = []   // track <font face="Courier"> = monospaced

        func flush() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty || !prefix.isEmpty {
                lines.append(prefix + trimmed)
            } else {
                lines.append("")
            }
            line = ""
            prefix = ""
            justFlushed = true
        }

        // Flush at a block boundary, but skip if a <br> just flushed an empty
        // line (so <div><br></div> yields one blank line, not two).
        func flushBlock() {
            if justFlushed && line.isEmpty && prefix.isEmpty { return }
            flush()
        }

        func readTag() -> String {
            var tag = ""
            i += 1 // skip '<'
            while i < chars.count, chars[i] != ">" {
                tag.append(chars[i]); i += 1
            }
            if i < chars.count { i += 1 } // skip '>'
            return tag
        }

        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                // Heading detection: <b><span style="font-size: 24px"> ...
                if matchesAhead(chars, i, "<b><span style=\"font-size: 24px\">") {
                    prefix = "# "
                    pendingHeadingClose = true
                    i += "<b><span style=\"font-size: 24px\">".count
                    continue
                }
                if matchesAhead(chars, i, "<b><span style=\"font-size: 18px\">") {
                    prefix = "## "
                    pendingHeadingClose = true
                    i += "<b><span style=\"font-size: 18px\">".count
                    continue
                }
                let raw = readTag()          // original case (URLs are case-sensitive)
                let tag = raw.lowercased()
                switch true {
                case pendingHeadingClose && tag == "/span":
                    break // swallow; the </b> closes the heading next
                case pendingHeadingClose && tag == "/b":
                    pendingHeadingClose = false
                case tag == "div", tag == "p":
                    break
                case tag == "/div", tag == "/p":
                    flushBlock()
                case tag == "br", tag == "br/":
                    flush()
                case tag == "h1":
                    prefix = "# "
                case tag == "h2", tag == "h3":
                    prefix = (tag == "h3") ? "## " : "## "
                case tag == "/h1", tag == "/h2", tag == "/h3":
                    flushBlock()
                case tag == "b", tag == "strong", tag == "/b", tag == "/strong":
                    line += "**"
                case tag == "i", tag == "em", tag == "/i", tag == "/em":
                    line += "*"
                case tag == "strike", tag == "s", tag == "del",
                     tag == "/strike", tag == "/s", tag == "/del":
                    line += "~~"
                case tag == "code", tag == "/code":
                    line += "`"
                case tag == "tt", tag == "/tt":
                    break // Notes wraps monospaced in <font face="Courier">; tt is redundant
                case tag.hasPrefix("font"):
                    let isMono = (attribute("face", in: raw) ?? "").lowercased().contains("courier")
                    fontMonoStack.append(isMono)
                    if isMono { line += "`" }
                case tag == "/font":
                    let wasMono = fontMonoStack.popLast() ?? false
                    if wasMono { line += "`" }
                case tag == "ul":
                    listOrdered.append(false); orderedCounters.append(0)
                case tag == "ol":
                    listOrdered.append(true); orderedCounters.append(0)
                case tag == "/ul", tag == "/ol":
                    if !listOrdered.isEmpty { listOrdered.removeLast() }
                    if !orderedCounters.isEmpty { orderedCounters.removeLast() }
                case tag == "li":
                    if listOrdered.last == true {
                        orderedCounters[orderedCounters.count - 1] += 1
                        prefix = "\(orderedCounters.last!). "
                    } else {
                        prefix = "- "
                    }
                case tag == "/li":
                    flushBlock()
                case tag.hasPrefix("a "), tag == "a":
                    linkHref = attribute("href", in: raw)
                    linkOpenLen = line.count
                case tag == "/a":
                    if let href = linkHref {
                        let anchor = String(line.dropFirst(linkOpenLen))
                        if anchor.isEmpty { line += href }            // no label → show URL
                        else if anchor != href { line += " (\(href))" } // label → "label (url)"
                        // else label already is the URL → leave as-is
                    }
                    linkHref = nil
                default:
                    break // span, font, u, and anything else: swallow tag
                }
            } else {
                // text content: collect until next '<', decode entities
                var text = ""
                while i < chars.count, chars[i] != "<" {
                    text.append(chars[i]); i += 1
                }
                line += decodeEntities(text)
            }
        }
        if !line.isEmpty || !prefix.isEmpty { flush() }
        return lines
    }

    private static func matchesAhead(_ chars: [Character], _ i: Int, _ s: String) -> Bool {
        let needle = Array(s)
        guard i + needle.count <= chars.count else { return false }
        for k in 0..<needle.count where chars[i + k] != needle[k] { return false }
        return true
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        // Notes emits both quoted (href="x") and unquoted (href=x) attributes.
        let pattern = "\(name)=(?:\"([^\"]*)\"|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let m = re.firstMatch(in: tag, range: range) else { return nil }
        for g in [1, 2] {
            if let r = Range(m.range(at: g), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        // Fixed, explicit order — never rely on Dictionary iteration order.
        // `&amp;` MUST decode last: doing it first turns a doubly-escaped
        // entity like `&amp;lt;` (visible text `&lt;`) into `<`, corrupting
        // write->read round-trips of any text containing `&`, `<`, `>`
        // (issue #29). Decode named/numeric entities first, `&amp;` -> `&` last.
        let ordered: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&amp;", "&"),
        ]
        for (k, v) in ordered { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
