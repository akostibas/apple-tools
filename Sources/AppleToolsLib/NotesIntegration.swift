import Foundation

/// Shared Apple Notes integration. All AppleScript-driven Notes access lives
/// here.
///
/// Consumers: NotesTool (LLM tool wrapper) and any future Notes integration
/// point.
///
/// Design: stateless enum with static methods. AppleScript snippets and
/// parsing are encapsulated; callers receive typed values.
public enum NotesIntegration {

    // MARK: - Types

    public enum NotesError: Error, CustomStringConvertible {
        case scriptFailed(String)
        case notFound
        case parseFailure(String)

        public var description: String {
            switch self {
            case .scriptFailed(let msg): return msg
            case .notFound: return "note not found"
            case .parseFailure(let msg): return msg
            }
        }
    }

    public struct Folder {
        public let id: String
        public let name: String
        public let noteCount: Int?
        public let parentID: String?
        public let path: String?
    }

    public struct NoteSummary {
        public let id: String
        public let title: String
        public let modified: String
        public let snippet: String
    }

    public struct Note {
        public let id: String
        public let title: String
        public let folder: String
        public let modified: String
        public let created: String
        public let content: String
    }

    public struct CreatedNote {
        public let id: String
        public let title: String
    }

    public struct AppendResult {
        public let id: String
        public let title: String
        public let totalLength: Int?
    }

    // MARK: - Preflight

    public static func preflight() -> (ok: Bool, message: String) {
        let script = """
        tell application "Notes"
            count of folders
        end tell
        """
        let (_, err) = runAppleScript(script, [:], nil)
        if let err = err {
            return (false, "notes access denied: \(err)")
        }
        return (true, "notes access granted")
    }

    // MARK: - Folders

    public static func listFolders() throws -> [Folder] {
        let script = """
        tell application "Notes"
            set output to ""
            -- First, emit all folders with their note counts
            repeat with f in (every folder)
                set fName to name of f
                set fID to id of f
                set nCount to count of notes of f
                set output to output & "F" & "\\t" & fID & "\\t" & fName & "\\t" & (nCount as string) & linefeed
            end repeat
            -- Then, emit parent->child edges
            repeat with f in (every folder)
                set fID to id of f
                set subs to every folder of f
                repeat with s in subs
                    set output to output & "E" & "\\t" & fID & "\\t" & (id of s) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """

        let (out, err) = runAppleScript(script, [:], nil)
        if let err = err { throw NotesError.scriptFailed(err) }

        var folderMeta: [String: (name: String, count: Int?)] = [:]
        var folderOrder: [String] = []
        var childToParent: [String: String] = [:]

        for line in out.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            if parts[0] == "F" && parts.count >= 4 {
                let id = parts[1]
                folderMeta[id] = (name: parts[2], count: Int(parts[3]))
                folderOrder.append(id)
            } else if parts[0] == "E" && parts.count >= 3 {
                childToParent[parts[2]] = parts[1]
            }
        }

        var folders: [Folder] = []
        for id in folderOrder {
            guard let meta = folderMeta[id] else { continue }
            let parentID = childToParent[id]
            var path: String? = nil
            if parentID != nil {
                var pathParts: [String] = []
                var current = id
                while let pid = childToParent[current], let parent = folderMeta[pid] {
                    pathParts.insert(parent.name, at: 0)
                    current = pid
                }
                if !pathParts.isEmpty {
                    pathParts.append(meta.name)
                    path = pathParts.joined(separator: "/")
                }
            }
            folders.append(Folder(id: id, name: meta.name, noteCount: meta.count, parentID: parentID, path: path))
        }
        return folders
    }

    // MARK: - Search

    public static func searchNotes(query: String, folder: String?, offset: Int, limit: Int) throws -> (total: Int, notes: [NoteSummary]) {
        var env = ["APPLE_TOOLS_NOTES_QUERY": query]
        let folderBinding: String
        let folderClause: String
        if let folder = folder {
            env["APPLE_TOOLS_NOTES_FOLDER"] = folder
            folderBinding = """
            set theFolder to do shell script "printenv APPLE_TOOLS_NOTES_FOLDER"
            """
            folderClause = "every note of folder theFolder whose name contains theQuery or plaintext contains theQuery"
        } else {
            folderBinding = ""
            folderClause = "every note whose name contains theQuery or plaintext contains theQuery"
        }

        let script = """
        set theQuery to do shell script "printenv APPLE_TOOLS_NOTES_QUERY"
        \(folderBinding)
        tell application "Notes"
            set matchingNotes to \(folderClause)
            set totalCount to count of matchingNotes
            set output to (totalCount as string) & linefeed
            set startIdx to \(offset + 1)
            set endIdx to \(offset + limit)
            if endIdx > totalCount then set endIdx to totalCount
            if startIdx > totalCount then return (totalCount as string) & linefeed
            repeat with i from startIdx to endIdx
                set n to item i of matchingNotes
                set nName to name of n
                set nID to id of n
                set nDate to modification date of n
                set nPlain to plaintext of n
                -- Skip first line (title) and leading whitespace for snippet
                set firstLF to offset of linefeed in nPlain
                if firstLF > 0 and firstLF < (length of nPlain) then
                    set nPlain to text (firstLF + 1) thru -1 of nPlain
                    -- Trim leading whitespace/newlines
                    repeat while nPlain starts with linefeed or nPlain starts with " "
                        if length of nPlain > 1 then
                            set nPlain to text 2 thru -1 of nPlain
                        else
                            set nPlain to ""
                            exit repeat
                        end if
                    end repeat
                else
                    set nPlain to ""
                end if
                if length of nPlain > 200 then
                    set nPlain to text 1 thru 200 of nPlain
                end if
                set output to output & nID & "\\t" & nName & "\\t" & nDate & "\\t" & nPlain & linefeed
            end repeat
            return output
        end tell
        """

        let (out, err) = runAppleScript(script, env, nil)
        if let err = err { throw NotesError.scriptFailed(err) }

        let lines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let firstLine = lines.first, let totalCount = Int(firstLine.trimmingCharacters(in: .whitespaces)) else {
            throw NotesError.parseFailure("failed to parse search results")
        }

        var notes: [NoteSummary] = []
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { continue }
            notes.append(NoteSummary(
                id: parts[0],
                title: parts[1],
                modified: parts[2],
                snippet: parts[3...].joined(separator: "\t")
            ))
        }
        return (totalCount, notes)
    }

    // MARK: - Read

    public static func readNote(id: String?, title: String?) throws -> Note {
        let whereClause: String
        var env: [String: String] = [:]
        if let id = id {
            env["APPLE_TOOLS_NOTES_ID_OR_TITLE"] = id
            whereClause = "first note whose id is theKey"
        } else if let title = title {
            env["APPLE_TOOLS_NOTES_ID_OR_TITLE"] = title
            whereClause = "first note whose name is theKey"
        } else {
            throw NotesError.parseFailure("read requires id or title")
        }

        let script = """
        set theKey to do shell script "printenv APPLE_TOOLS_NOTES_ID_OR_TITLE"
        tell application "Notes"
            set theNote to \(whereClause)
            set nID to id of theNote
            set nName to name of theNote
            set nFolder to "unknown"
            repeat with f in (every folder)
                if (id of every note of f) contains nID then
                    set nFolder to name of f
                    exit repeat
                end if
            end repeat
            set nDate to modification date of theNote
            set nCreated to creation date of theNote
            set nHTML to body of theNote
            return nID & "\\t" & nName & "\\t" & nFolder & "\\t" & nDate & "\\t" & nCreated & "\\t" & nHTML
        end tell
        """

        let (out, err) = runAppleScript(script, env, nil)
        if let err = err {
            if err.contains("-1728") { throw NotesError.notFound }
            throw NotesError.scriptFailed(err)
        }

        let parts = out.components(separatedBy: "\t")
        guard parts.count >= 6 else {
            throw NotesError.parseFailure("failed to parse note data")
        }
        let noteTitle = parts[1]
        let htmlBody = parts[5...].joined(separator: "\t")
        // AppleScript flattens checklists; recover checked state from the
        // protobuf store (best-effort, possibly stale — see NotesChecklistStore).
        let checklist = checklistLookup(noteTitle).map { (text: $0.text, done: $0.done) }
        // AppleScript drops link hrefs; recover URLs from the protobuf store and
        // splice them onto matching display text (best-effort, possibly stale).
        let links = linkLookup(noteTitle).map { (text: $0.text, url: $0.url) }
        let converted = NotesMarkdown.notesHTMLToMarkdown(htmlBody, title: noteTitle, checklist: checklist)
        let markdown = NotesMarkdown.overlayLinks(converted, links: links)
        return Note(
            id: parts[0],
            title: noteTitle,
            folder: parts[2],
            modified: parts[3],
            created: parts[4],
            content: markdown
        )
    }

    /// Test seam: checklist-state lookup by note title. Defaults to the
    /// protobuf store; swappable in tests so readNote stays offline.
    public static var checklistLookup: (_ title: String) -> [NotesChecklistStore.Item] = NotesChecklistStore.checklistItems(forTitle:)

    /// Test seam: link-URL lookup by note title. Defaults to the protobuf
    /// store; swappable in tests so readNote stays offline.
    public static var linkLookup: (_ title: String) -> [NotesChecklistStore.Link] = NotesChecklistStore.linkItems(forTitle:)

    // MARK: - Create

    public static func createNote(title: String, body: String, folder: String?) throws -> CreatedNote {
        let htmlBody = body.isEmpty ? "" : NotesMarkdown.markdownToNotesHTML(body)
        var env = [
            "APPLE_TOOLS_NOTES_TITLE": title,
            "APPLE_TOOLS_NOTES_BODY": htmlBody,
        ]

        let folderBinding: String
        let atClause: String
        if let folder = folder {
            env["APPLE_TOOLS_NOTES_FOLDER"] = folder
            folderBinding = """
            set theFolder to do shell script "printenv APPLE_TOOLS_NOTES_FOLDER"
            """
            atClause = """
            if not (exists folder theFolder) then
                        make new folder with properties {name:theFolder}
                    end if
                    set newNote to make new note at folder theFolder with properties {name:theTitle, body:theBody}
            """
        } else {
            folderBinding = ""
            atClause = """
            set newNote to make new note with properties {name:theTitle, body:theBody}
            """
        }

        let script = """
        set theTitle to do shell script "printenv APPLE_TOOLS_NOTES_TITLE"
        set theBody to do shell script "printenv APPLE_TOOLS_NOTES_BODY"
        \(folderBinding)
        log "PHASE: prepare"
        tell application "Notes"
            log "PHASE: pre-commit"
            \(atClause)
            set noteID to id of newNote as string
            log "PHASE: committed id=" & noteID
            return noteID & "\\t" & (name of newNote)
        end tell
        """

        // Post-verify hook (ADR-032 /): snapshot before AppleScript so
        // a SIGKILL-during-pre-commit can be disambiguated by polling the
        // Notes store for a row with matching title modified after the
        // snapshot. Only ever upgrades outcome_unknown → success.
        let cutoff = NotesVerifier.snapshotCutoff()
        let verifyHook = NotesVerifier.makeVerifyHook(title: title, sinceCutoff: cutoff)
        let (out, err) = runAppleScript(script, env, verifyHook)
        if let err = err { throw NotesError.scriptFailed(err) }

        let parts = out.components(separatedBy: "\t")
        guard parts.count >= 2 else {
            throw NotesError.parseFailure("note created but failed to parse response")
        }
        return CreatedNote(id: parts[0], title: parts[1])
    }

    // MARK: - Append

    public static func appendToNote(id: String?, title: String?, text: String) throws -> AppendResult {
        let whereClause: String
        var env: [String: String] = [:]
        if let id = id {
            env["APPLE_TOOLS_NOTES_ID_OR_TITLE"] = id
            whereClause = "first note whose id is theKey"
        } else if let title = title {
            env["APPLE_TOOLS_NOTES_ID_OR_TITLE"] = title
            whereClause = "first note whose name is theKey"
        } else {
            throw NotesError.parseFailure("append requires id or title")
        }

        env["APPLE_TOOLS_NOTES_CONTENT"] = "<div><br></div>" + NotesMarkdown.markdownToNotesHTML(text)

        let script = """
        set theKey to do shell script "printenv APPLE_TOOLS_NOTES_ID_OR_TITLE"
        set theContent to do shell script "printenv APPLE_TOOLS_NOTES_CONTENT"
        log "PHASE: prepare"
        tell application "Notes"
            set theNote to \(whereClause)
            set existingBody to body of theNote
            log "PHASE: pre-commit"
            set body of theNote to existingBody & theContent
            set noteID to id of theNote as string
            log "PHASE: committed id=" & noteID
            set nPlain to plaintext of theNote
            set charCount to length of nPlain
            return noteID & "\\t" & (name of theNote) & "\\t" & charCount
        end tell
        """

        // Post-verify hook (ADR-032 /). For appendToNote, the verifier
        // can only fire when matching by title (a fresh ZMODIFICATIONDATE on
        // a known title is the confirmable signal). When the caller located
        // the note by id alone we lack the title — skip the hook in that case.
        let cutoff = NotesVerifier.snapshotCutoff()
        let verifyHook: (() -> AppleScriptRunner.VerifyResult)? = title.map { t in
            NotesVerifier.makeVerifyHook(title: t, sinceCutoff: cutoff)
        }
        let (out, err) = runAppleScript(script, env, verifyHook)
        if let err = err {
            if err.contains("-1728") { throw NotesError.notFound }
            throw NotesError.scriptFailed(err)
        }

        let parts = out.components(separatedBy: "\t")
        guard parts.count >= 3 else {
            throw NotesError.parseFailure("content appended but failed to parse response")
        }
        return AppendResult(id: parts[0], title: parts[1], totalLength: Int(parts[2]))
    }

    // MARK: - AppleScript runner & escape helpers

    /// Test seam: swappable runner that accepts an env dict for payload values.
    /// Default routes through `AppleScriptRunner.runLegacy` with tool="notes".
    public static var runAppleScript: (_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) = defaultRunAppleScript

    public static func defaultRunAppleScript(_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) {
        return AppleScriptRunner.runLegacy(source: source, tool: "notes", environment: environment, onOutcomeUnknown: verifyHook)
    }

    public static func escapeHTML(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
