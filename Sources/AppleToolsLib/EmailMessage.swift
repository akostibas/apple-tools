import Foundation

/// Parses Apple Mail `.emlx` files into structured messages, and derives
/// on-disk paths from Envelope Index rows. See docs/reference/macos-internals/mail-data.md for the
/// shape of `.emlx` files and the directory layout.
enum EmailMessage {

    struct Attachment {
        let filename: String
        let mimeType: String
        let size: Int
    }

    /// A MIME attachment part with its decoded bytes — for `fetch_attachment`.
    struct LoadedAttachment {
        let filename: String
        let mimeType: String
        let data: Data
    }

    struct Parsed {
        let subject: String
        let from: String        // raw "Name <addr>" or just "addr"
        let to: String          // comma-joined
        let cc: String?
        let dateHeader: String  // raw Date: header value
        let body: String        // decoded text body; empty if only HTML was available
        let bodyIsHTMLOnly: Bool // true if we had to fall back to HTML (and stripped tags)
        let attachments: [Attachment]
    }

    enum ParseError: Error, CustomStringConvertible {
        case invalidEmlxHeader
        case emptyMessage

        var description: String {
            switch self {
            case .invalidEmlxHeader: return "invalid .emlx byte-count header"
            case .emptyMessage: return "empty message body"
            }
        }
    }

    /// Errors from `loadAttachment`. `.ambiguous` / `.notFound` carry the
    /// candidate filename list so the caller can surface it for disambiguation.
    enum LoadError: Error, CustomStringConvertible {
        case noAttachments
        case notFound(candidates: [String])
        case ambiguous(candidates: [String])

        var description: String {
            switch self {
            case .noAttachments: return "message has no attachments"
            case .notFound(let c): return "attachment not found (available: \(c.joined(separator: ", ")))"
            case .ambiguous(let c): return "multiple attachments; filename required (available: \(c.joined(separator: ", ")))"
            }
        }
    }

    // MARK: - .emlx path derivation

    /// Given an Envelope Index ROWID and the `mailboxes.url`, return the
    /// expected on-disk `.emlx` path, or nil if the account layout
    /// can't be resolved (e.g. `local://` schemes we don't handle yet).
    ///
    /// Example inputs:
    ///   rowid:  192210
    ///   url:    imap://abc-uuid/%5BGmail%5D/All%20Mail
    /// Resolves to:
    ///   ~/Library/Mail/V10/abc-uuid/[Gmail].mbox/All Mail.mbox/<subdir-uuid>/Data/2/9/1/Messages/192210.emlx
    static func emlxPath(rowID: Int64, mailboxURL: String) -> String? {
        guard let components = URLComponents(string: mailboxURL),
              components.scheme == "imap",
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let mailRoot = "\(home)/Library/Mail/V10"
        let accountRoot = "\(mailRoot)/\(host)"

        // Build the mailbox directory: each path segment becomes `<segment>.mbox`.
        let rawPath = (components.path.removingPercentEncoding ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawPath.isEmpty else { return nil }
        let segments = rawPath.components(separatedBy: "/")
        let mailboxDir = accountRoot + "/" + segments.map { "\($0).mbox" }.joined(separator: "/")

        // Find the per-account subdir UUID by listing the mailbox directory.
        // It's typically a single UUID-named directory. Pick the first.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: mailboxDir) else {
            return nil
        }
        // Prefer entries that look like UUIDs (8-4-4-4-12 hex). Fall back to any dir.
        let uuidLike = entries.first { $0.count == 36 && $0.contains("-") } ?? entries.first { entry in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(mailboxDir)/\(entry)", isDirectory: &isDir) && isDir.boolValue
        }
        guard let subdir = uuidLike else { return nil }

        // Split floor(rowid/1000) into digit directories, right-to-left.
        // e.g. 192210 → 192 → "2/9/1"; 99000 → 99 → "9/9"; 123 → 0 → "0".
        let thousands = rowID / 1000
        let digitDirs: String = {
            if thousands == 0 { return "0" }
            let s = String(thousands)
            // Right-to-left split: reverse the string, separate every digit.
            return String(s.reversed()).map(String.init).joined(separator: "/")
        }()

        let messagesDir = "\(mailboxDir)/\(subdir)/Data/\(digitDirs)/Messages"

        // Try both .emlx and .partial.emlx — .partial is a sync-state marker,
        // not a content truncation flag.
        for suffix in [".emlx", ".partial.emlx"] {
            let candidate = "\(messagesDir)/\(rowID)\(suffix)"
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - On-disk attachment lookup

    /// Look for a pre-downloaded attachment file in Mail's Attachments/ directory.
    /// IMAP-synced messages often have empty bodies in the .emlx (stubs) but
    /// Mail.app stores downloaded attachment files alongside the Messages/ dir
    /// at `…/Data/<digits>/Attachments/<rowID>/<partIndex>/<filename>`.
    /// Returns the file data, or nil if not found on disk.
    static func loadAttachmentFromDisk(emlxPath: String, rowID: Int64, filename: String) -> Data? {
        // emlxPath is like …/Data/2/9/1/Messages/192326.partial.emlx
        // We want         …/Data/2/9/1/Attachments/192326/
        let messagesDir = (emlxPath as NSString).deletingLastPathComponent
        let dataDir = (messagesDir as NSString).deletingLastPathComponent
        let attachmentsDir = (dataDir as NSString).appendingPathComponent("Attachments/\(rowID)")

        let fm = FileManager.default
        guard fm.fileExists(atPath: attachmentsDir) else { return nil }

        // Walk the subdirectories (numbered by MIME part index) looking for
        // a file whose name matches the requested filename.
        guard let enumerator = fm.enumerator(atPath: attachmentsDir) else { return nil }
        while let relative = enumerator.nextObject() as? String {
            let fullPath = (attachmentsDir as NSString).appendingPathComponent(relative)
            let name = (relative as NSString).lastPathComponent
            if name == filename {
                return fm.contents(atPath: fullPath)
            }
        }
        return nil
    }

    // MARK: - .emlx file parsing

    /// Read an .emlx file, strip the byte-count header and trailing metadata plist,
    /// and parse the embedded RFC 822 message.
    static func parseEmlx(atPath path: String) throws -> Parsed {
        let rfc822 = try readEmlxRFC822(atPath: path)
        return try parseRFC822(rfc822)
    }

    /// Load a single attachment's decoded bytes from an .emlx file.
    /// If `filename` is nil and there's exactly one attachment, returns it.
    /// Throws `.ambiguous` / `.notFound` / `.noAttachments` otherwise.
    static func loadAttachment(atPath path: String, filename: String?) throws -> LoadedAttachment {
        let rfc822 = try readEmlxRFC822(atPath: path)
        let (headers, body) = splitHeadersAndBody(rfc822)
        let h = HeaderMap(headers)
        let rootCT = parseContentType(h.first("content-type") ?? "text/plain")
        let rootEnc = h.first("content-transfer-encoding")?.lowercased().trimmingCharacters(in: .whitespaces)

        var attachments: [LoadedAttachment] = []
        collectAttachments(
            body: body,
            contentType: rootCT,
            transferEncoding: rootEnc,
            topLevelHeaders: h,
            disposition: nil,
            into: &attachments
        )

        if attachments.isEmpty { throw LoadError.noAttachments }

        if let filename = filename {
            if let match = attachments.first(where: { $0.filename == filename }) {
                return match
            }
            throw LoadError.notFound(candidates: attachments.map(\.filename))
        }
        if attachments.count == 1 { return attachments[0] }
        throw LoadError.ambiguous(candidates: attachments.map(\.filename))
    }

    /// Read an .emlx file, strip the leading ASCII byte count and the trailing
    /// Apple-Mail metadata plist, and return just the embedded RFC 822 bytes.
    private static func readEmlxRFC822(atPath path: String) throws -> Data {
        let all = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !all.isEmpty else { throw ParseError.emptyMessage }

        // First line is an ASCII byte count. Find the first whitespace (space, \n, \t).
        var i = 0
        while i < all.count {
            let b = all[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { break }
            i += 1
        }
        guard i > 0, let header = String(data: all.prefix(i), encoding: .ascii),
              let count = Int(header.trimmingCharacters(in: .whitespaces))
        else {
            throw ParseError.invalidEmlxHeader
        }
        // Skip whitespace after the count.
        while i < all.count, (all[i] == 0x20 || all[i] == 0x09 || all[i] == 0x0A || all[i] == 0x0D) {
            i += 1
        }
        let end = min(i + count, all.count)
        return all.subdata(in: i..<end)
    }

    // MARK: - RFC 822 / MIME

    /// Parse headers + body from an RFC 822 blob. Handles MIME bodies
    /// (multipart/*, base64, quoted-printable, RFC 2047 headers).
    static func parseRFC822(_ data: Data) throws -> Parsed {
        let (headers, body) = splitHeadersAndBody(data)
        let h = HeaderMap(headers)

        let subject = decodeRFC2047(h.first("subject") ?? "")
        let from = decodeRFC2047(h.first("from") ?? "")
        let to = decodeRFC2047(h.first("to") ?? "")
        let cc = h.first("cc").map { decodeRFC2047($0) }
        let dateHeader = h.first("date") ?? ""

        let rootCT = parseContentType(h.first("content-type") ?? "text/plain")
        let rootEnc = h.first("content-transfer-encoding")?.lowercased().trimmingCharacters(in: .whitespaces)

        // Walk MIME tree.
        var textParts: [String] = []
        var htmlParts: [String] = []
        var attachments: [Attachment] = []
        walkMIME(
            body: body,
            contentType: rootCT,
            transferEncoding: rootEnc,
            disposition: nil,
            topLevelHeaders: h,
            textAccum: &textParts,
            htmlAccum: &htmlParts,
            attachAccum: &attachments
        )

        let preferredText = textParts.first(where: { !$0.isEmpty }) ?? ""
        let bodyText: String
        let htmlOnly: Bool
        if !preferredText.isEmpty {
            bodyText = preferredText
            htmlOnly = false
        } else if let html = htmlParts.first(where: { !$0.isEmpty }) {
            bodyText = stripHTML(html)
            htmlOnly = true
        } else {
            bodyText = ""
            htmlOnly = false
        }

        return Parsed(
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            dateHeader: dateHeader,
            body: bodyText,
            bodyIsHTMLOnly: htmlOnly,
            attachments: attachments
        )
    }

    /// Split an RFC 822 blob at the first blank line (CRLF CRLF or LF LF).
    static func splitHeadersAndBody(_ data: Data) -> (headers: String, body: Data) {
        // Look for \r\n\r\n or \n\n.
        let len = data.count
        var i = 0
        while i < len {
            if i + 1 < len, data[i] == 0x0A, data[i + 1] == 0x0A {
                let headers = String(data: data.prefix(i), encoding: .utf8)
                    ?? String(data: data.prefix(i), encoding: .isoLatin1) ?? ""
                return (headers, data.subdata(in: (i + 2)..<len))
            }
            if i + 3 < len, data[i] == 0x0D, data[i + 1] == 0x0A, data[i + 2] == 0x0D, data[i + 3] == 0x0A {
                let headers = String(data: data.prefix(i), encoding: .utf8)
                    ?? String(data: data.prefix(i), encoding: .isoLatin1) ?? ""
                return (headers, data.subdata(in: (i + 4)..<len))
            }
            i += 1
        }
        // No blank line — treat everything as headers.
        let headers = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return (headers, Data())
    }

    /// Parse headers preserving order. Continuation lines (starting with whitespace)
    /// fold into the previous header value. Names are lowercased for lookup.
    struct HeaderMap {
        private let pairs: [(name: String, value: String)]
        init(_ raw: String) {
            var out: [(String, String)] = []
            for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                if line.isEmpty { continue }
                if line.first == " " || line.first == "\t" {
                    // Continuation: append to previous value (with a space).
                    if !out.isEmpty {
                        let last = out.removeLast()
                        out.append((last.0, last.1 + " " + line.trimmingCharacters(in: .whitespaces)))
                    }
                    continue
                }
                if let colon = line.firstIndex(of: ":") {
                    let name = String(line[line.startIndex..<colon]).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    out.append((name, value))
                }
            }
            pairs = out
        }
        func first(_ name: String) -> String? {
            pairs.first(where: { $0.name == name })?.value
        }
    }

    struct ContentType {
        let mime: String                  // e.g. "text/plain"
        let params: [String: String]      // keys lowercased
        var charset: String? { params["charset"] }
        var boundary: String? { params["boundary"] }
        var name: String? { params["name"] }
    }

    static func parseContentType(_ raw: String) -> ContentType {
        // Format: mime/type; k1=v1; k2="v2"; ...
        let parts = raw.components(separatedBy: ";")
        let mime = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let kv = part.components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            var v = kv.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            params[k] = v
        }
        return ContentType(mime: mime, params: params)
    }

    /// Parse Content-Disposition: returns disposition ("attachment"/"inline") and filename.
    ///
    /// Handles both filename encodings and their precedence:
    ///   - `filename` — a plain (optionally quoted) value, possibly carrying
    ///     RFC 2047 encoded-words (`=?UTF-8?B?…?=`).
    ///   - `filename*` — RFC 2231 extended syntax (`charset'lang'pct-encoded`),
    ///     which is percent-decoding, NOT RFC 2047. Running decodeRFC2047 on it
    ///     leaves the raw `UTF-8''na%C3%AFve.pdf` garbage (issue #27).
    /// Per RFC 6266, `filename*` wins over `filename` when both are present —
    /// but only after each is decoded with the correct scheme.
    static func parseDisposition(_ raw: String?) -> (disposition: String?, filename: String?) {
        guard let raw = raw, !raw.isEmpty else { return (nil, nil) }
        let parts = raw.components(separatedBy: ";")
        let dispo = parts.first?.trimmingCharacters(in: .whitespaces).lowercased()
        var plainFilename: String?
        var extFilename: String?
        for part in parts.dropFirst() {
            let kv = part.components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            var v = kv.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            if k == "filename*" {
                extFilename = decodeRFC2231Value(v)
            } else if k == "filename" {
                plainFilename = decodeRFC2047(v)
            }
        }
        return (dispo, extFilename ?? plainFilename)
    }

    /// Decode an RFC 2231 extended-parameter value: `charset'lang'pct-encoded`
    /// (the `lang` field is optional and ignored). A bare percent-encoded value
    /// with no `charset'lang'` prefix is also accepted (defaults to UTF-8).
    /// Continuation segments (`filename*0*`, `filename*1*`) are not handled —
    /// rare in practice; such a value falls back to the plain `filename`.
    static func decodeRFC2231Value(_ raw: String) -> String {
        var charset = "utf-8"
        var encoded = raw
        // Extended syntax has exactly two single-quotes delimiting charset and
        // lang. Only treat it as such when both are present.
        if let firstQuote = raw.firstIndex(of: "'") {
            let afterFirst = raw.index(after: firstQuote)
            if let secondQuote = raw[afterFirst...].firstIndex(of: "'") {
                let cs = String(raw[raw.startIndex..<firstQuote])
                if !cs.isEmpty { charset = cs }
                encoded = String(raw[raw.index(after: secondQuote)...])
            }
        }

        // Percent-decode to raw bytes, then interpret with the declared charset.
        let chars = Array(encoded.utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x25 /* % */, i + 2 < chars.count,
               let h1 = hexNibble(chars[i + 1]), let h2 = hexNibble(chars[i + 2]) {
                bytes.append(UInt8(h1 << 4 | h2))
                i += 3
            } else {
                bytes.append(chars[i])
                i += 1
            }
        }
        let data = Data(bytes)
        let enc = encodingFor(charset: charset)
        return String(data: data, encoding: enc)
            ?? String(data: data, encoding: .utf8)
            ?? encoded
    }

    /// Recursive MIME tree walker. Collects decoded text parts, html parts, and attachments.
    private static func walkMIME(
        body: Data,
        contentType: ContentType,
        transferEncoding: String?,
        disposition: String?,
        topLevelHeaders: HeaderMap,
        textAccum: inout [String],
        htmlAccum: inout [String],
        attachAccum: inout [Attachment]
    ) {
        if contentType.mime.hasPrefix("multipart/"), let boundary = contentType.boundary {
            // Split body on boundary.
            for partData in splitMultipart(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeadersAndBody(partData)
                let ph = HeaderMap(partHeaders)
                let ct = parseContentType(ph.first("content-type") ?? "text/plain")
                let enc = ph.first("content-transfer-encoding")?.lowercased().trimmingCharacters(in: .whitespaces)
                let (dispo, _) = parseDisposition(ph.first("content-disposition"))
                walkMIME(
                    body: partBody,
                    contentType: ct,
                    transferEncoding: enc,
                    disposition: dispo,
                    topLevelHeaders: ph,
                    textAccum: &textAccum,
                    htmlAccum: &htmlAccum,
                    attachAccum: &attachAccum
                )
            }
            return
        }

        // Leaf part.
        let decoded = decodeTransferEncoding(body, encoding: transferEncoding)
        let (dispo, dispoFilename) = parseDisposition(topLevelHeaders.first("content-disposition"))
        let effectiveDispo = disposition ?? dispo
        let filename = dispoFilename ?? contentType.name

        let isAttachment = (effectiveDispo == "attachment")
            || (filename != nil && !contentType.mime.hasPrefix("text/") && !contentType.mime.hasPrefix("multipart/"))

        if isAttachment {
            let name = filename ?? "attachment"
            attachAccum.append(Attachment(
                filename: name,
                mimeType: contentType.mime,
                size: decoded.count
            ))
            return
        }

        if contentType.mime == "text/plain" {
            textAccum.append(decodeToString(decoded, charset: contentType.charset))
        } else if contentType.mime == "text/html" {
            htmlAccum.append(decodeToString(decoded, charset: contentType.charset))
        }
        // Other leaf MIME types are ignored for body purposes.
    }

    /// Recursive MIME walker that collects attachments with their decoded
    /// bytes. Used by `loadAttachment`. Mirrors the attachment-detection rules
    /// in `walkMIME`, but keeps the decoded body rather than a size.
    private static func collectAttachments(
        body: Data,
        contentType: ContentType,
        transferEncoding: String?,
        topLevelHeaders: HeaderMap,
        disposition: String?,
        into accum: inout [LoadedAttachment]
    ) {
        if contentType.mime.hasPrefix("multipart/"), let boundary = contentType.boundary {
            for partData in splitMultipart(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeadersAndBody(partData)
                let ph = HeaderMap(partHeaders)
                let ct = parseContentType(ph.first("content-type") ?? "text/plain")
                let enc = ph.first("content-transfer-encoding")?.lowercased().trimmingCharacters(in: .whitespaces)
                let (dispo, _) = parseDisposition(ph.first("content-disposition"))
                collectAttachments(
                    body: partBody,
                    contentType: ct,
                    transferEncoding: enc,
                    topLevelHeaders: ph,
                    disposition: dispo,
                    into: &accum
                )
            }
            return
        }

        let (dispo, dispoFilename) = parseDisposition(topLevelHeaders.first("content-disposition"))
        let effectiveDispo = disposition ?? dispo
        let filename = dispoFilename ?? contentType.name

        let isAttachment = (effectiveDispo == "attachment")
            || (filename != nil && !contentType.mime.hasPrefix("text/") && !contentType.mime.hasPrefix("multipart/"))
        guard isAttachment else { return }

        let decoded = decodeTransferEncoding(body, encoding: transferEncoding)
        accum.append(LoadedAttachment(
            filename: filename ?? "attachment",
            mimeType: contentType.mime,
            data: decoded
        ))
    }

    /// Split a multipart body on its boundary. Returns the inner part data
    /// for each part (without the boundary lines themselves).
    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        guard let bdata = ("--" + boundary).data(using: .ascii) else { return [] }
        var parts: [Data] = []
        var searchStart = 0
        let len = data.count
        var partStart: Int?
        var sawClose = false

        while searchStart < len {
            guard let range = data.range(of: bdata, in: searchStart..<len) else { break }
            let hit = range.lowerBound
            // A real boundary delimiter occupies its own line: it must sit at
            // the very start of the body or be immediately preceded by a LF
            // (CRLF ends in LF too). A bare `--boundary` mid-line — e.g. a text
            // part QUOTING a previous MIME message — is not a delimiter; skip
            // it and let it stay part of the current part's body (issue #36).
            if hit != 0 && data[hit - 1] != 0x0A {
                searchStart = range.upperBound
                continue
            }
            if let ps = partStart {
                // Part body ends just before `\r\n--boundary` (strip trailing CRLF before boundary).
                var pe = hit
                if pe > ps && data[pe - 1] == 0x0A { pe -= 1 }
                if pe > ps && data[pe - 1] == 0x0D { pe -= 1 }
                if pe >= ps {
                    parts.append(data.subdata(in: ps..<pe))
                }
                partStart = nil
            }
            // Advance past the boundary line. Check for closing "--" marker.
            var next = range.upperBound
            if next + 1 < len, data[next] == 0x2D, data[next + 1] == 0x2D {
                // "--boundary--" end marker. Stop.
                sawClose = true
                break
            }
            // Skip to end of line.
            while next < len, data[next] != 0x0A { next += 1 }
            if next < len { next += 1 }
            partStart = next
            searchStart = next
        }

        // Truncated message: the closing `--boundary--` never arrived, but a
        // final part is still open. Parse it to EOF rather than dropping it
        // (issue #36) — a truncated multipart otherwise loses its last part.
        if !sawClose, let ps = partStart, ps < len {
            var pe = len
            if pe > ps && data[pe - 1] == 0x0A { pe -= 1 }
            if pe > ps && data[pe - 1] == 0x0D { pe -= 1 }
            if pe > ps {
                parts.append(data.subdata(in: ps..<pe))
            }
        }
        return parts
    }

    // MARK: - Transfer-encoding decode

    static func decodeTransferEncoding(_ data: Data, encoding: String?) -> Data {
        switch (encoding ?? "7bit").lowercased() {
        case "base64":
            // Strip whitespace; Base64 in MIME is line-wrapped.
            let stripped = data.filter { !(_0x09_0x0A_0x0D_space($0)) }
            if let d = Data(base64Encoded: stripped, options: [.ignoreUnknownCharacters]) {
                return d
            }
            return Data()
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            // 7bit, 8bit, binary, or unknown — return as-is.
            return data
        }
    }

    private static func _0x09_0x0A_0x0D_space(_ b: UInt8) -> Bool {
        return b == 0x09 || b == 0x0A || b == 0x0D || b == 0x20
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = 0
        let len = data.count
        while i < len {
            let b = data[i]
            if b == 0x3D /* = */ {
                // Soft line break: "=\r\n" or "=\n" → emit nothing.
                if i + 1 < len, data[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < len, data[i + 1] == 0x0D, data[i + 2] == 0x0A { i += 3; continue }
                // Hex escape: =XX
                if i + 2 < len, let h1 = hexNibble(data[i + 1]), let h2 = hexNibble(data[i + 2]) {
                    out.append(UInt8(h1 << 4 | h2))
                    i += 3
                    continue
                }
                // Malformed — emit '='.
                out.append(b)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30              // 0-9
        case 0x41...0x46: return b - 0x41 + 10         // A-F
        case 0x61...0x66: return b - 0x61 + 10         // a-f
        default: return nil
        }
    }

    // MARK: - Charset → String

    static func decodeToString(_ data: Data, charset: String?) -> String {
        let encoding = encodingFor(charset: charset)
        if let s = String(data: data, encoding: encoding) { return s }
        // Fall back: try UTF-8, then Latin-1 (which always succeeds).
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func encodingFor(charset: String?) -> String.Encoding {
        guard let cs = charset?.lowercased() else { return .utf8 }
        switch cs {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "iso-8859-2": return .isoLatin2
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1251", "cp1251": return .windowsCP1251
        case "utf-16": return .utf16
        default: return .utf8
        }
    }

    // MARK: - RFC 2047 "encoded-word" decoder

    /// Decode =?charset?encoding?text?= sequences in header values.
    /// Encoding is B (base64) or Q (quoted-printable).
    static func decodeRFC2047(_ s: String) -> String {
        // Regex matches =?charset?B?...?= and =?charset?Q?...?=
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }

        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            if full.location > cursor {
                let between = ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
                // Between two encoded-words separated only by whitespace: drop the whitespace (RFC 2047).
                if !out.isEmpty, between.trimmingCharacters(in: .whitespaces).isEmpty {
                    // skip
                } else {
                    out += between
                }
            }
            let charset = ns.substring(with: m.range(at: 1))
            let encoding = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let decoded = decodeRFC2047Word(charset: charset, encoding: encoding, text: text)
            out += decoded
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func decodeRFC2047Word(charset: String, encoding: String, text: String) -> String {
        let bytes: Data
        switch encoding {
        case "B":
            bytes = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) ?? Data()
        case "Q":
            // Q-encoding is like QP but '_' means space.
            let mapped = text.replacingOccurrences(of: "_", with: " ")
            bytes = decodeQuotedPrintable(mapped.data(using: .ascii) ?? Data())
        default:
            return text
        }
        let enc = encodingFor(charset: charset)
        return String(data: bytes, encoding: enc) ?? String(data: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - HTML → text (best effort)

    /// Strip tags and decode a minimal set of entities. Not a real HTML
    /// parser, but adequate for dropping into an LLM context.
    static func stripHTML(_ html: String) -> String {
        // Remove <script>…</script> and <style>…</style> wholesale.
        var s = html
        for tag in ["script", "style"] {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            }
        }
        // Replace <br>, <p>, <li> with newlines for readability.
        for (pat, repl) in [("<br\\s*/?>", "\n"), ("</p>", "\n"), ("</li>", "\n")] {
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: repl)
            }
        }
        // Drop remaining tags.
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        // Decode the basic entity set (shared helper; `&amp;` decoded last,
        // see HTMLEntities). Doing `&amp;` first would double-decode an
        // already-escaped sequence like `&amp;lt;` into `<` (issue #29).
        s = HTMLEntities.decodeBasic(s)
        // Collapse runs of blank lines.
        if let re = try? NSRegularExpression(pattern: "\n{3,}", options: []) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
