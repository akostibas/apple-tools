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

    // MARK: - Field protocol

    /// Field/record separators for the AppleScript output records that this
    /// module parses. Note titles and folder names can legitimately contain
    /// tabs and linefeeds; a tab-delimited protocol silently shifts the
    /// folder/date fields and truncates the title used for the checklist/link
    /// lookups (issue #37). ASCII Unit Separator (0x1F) and Record Separator
    /// (0x1E) are control codes that cannot occur in Notes titles, folder
    /// names, or bodies, so they delimit unambiguously. The AppleScript side
    /// emits them via `character id 31` / `character id 30`.
    static let fieldSep = "\u{001F}"
    static let recordSep = "\u{001E}"

    // MARK: - Types

    public enum NotesError: Error, CustomStringConvertible {
        case scriptFailed(String)
        case notFound
        case parseFailure(String)
        /// The on-disk store could not be read. Distinct from "nothing matched"
        /// on purpose: a search that answers empty to every query looks healthy.
        case storeUnreadable(String)

        public var description: String {
            switch self {
            case .scriptFailed(let msg): return msg
            case .notFound: return "note not found"
            case .parseFailure(let msg): return msg
            case .storeUnreadable(let msg): return "notes search is unavailable: \(msg)"
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

    /// AppleScript handlers shared by the folder-enumerating scripts.
    ///
    /// `isDeletedFolder` walks a folder's `container` chain and reports whether
    /// it lives under (or is) the "Recently Deleted" system folder — the only
    /// stable discriminator Notes exposes for the trash container. Deleted
    /// folders linger there ~30 days and `exists folder X` still returns true
    /// for them, so a plain name/existence check can't tell them apart (issue
    /// #15). Every coercion is wrapped in `try`: a deleted *parent* becomes a
    /// zombie reference that raises -1700 (errAECoercionFail) on `name`/`class`,
    /// which would otherwise abort the whole enumeration — here it's treated as
    /// deleted so one bad ref can't sink the walk.
    ///
    /// `liveFolderByName` / `liveChildByName` resolve a folder by name to a
    /// *live* match only, returning `missing value` when the sole match is in
    /// the trash — so a create can't land a note in a deleted folder.
    ///
    /// NOTE: "Recently Deleted" is localized by macOS; non-English systems name
    /// the container differently, which this exact-string match won't catch.
    /// That's a known limitation tracked separately.
    static let folderScriptHandlers = """
    on isDeletedFolder(f)
        tell application "Notes"
            set cur to f
            repeat
                try
                    set cls to class of cur
                on error
                    return true
                end try
                if cls is not folder then return false
                try
                    set cname to name of cur
                on error
                    return true
                end try
                if cname is "Recently Deleted" then return true
                try
                    set cur to container of cur
                on error
                    return true
                end try
            end repeat
        end tell
    end isDeletedFolder

    on liveFolderByName(nm)
        tell application "Notes"
            repeat with f in (every folder)
                try
                    if (name of f) is nm and not (my isDeletedFolder(f)) then return f
                end try
            end repeat
        end tell
        return missing value
    end liveFolderByName

    on liveChildByName(parentRef, nm)
        tell application "Notes"
            repeat with s in (every folder of parentRef)
                try
                    if (name of s) is nm and not (my isDeletedFolder(s)) then return s
                end try
            end repeat
        end tell
        return missing value
    end liveChildByName
    """

    public static func listFolders() throws -> [Folder] {
        let script = """
        \(folderScriptHandlers)
        tell application "Notes"
            set fs to (character id 31)
            set rs to (character id 30)
            set output to ""
            -- First, emit every folder with its note count and a deleted flag.
            -- Each coercion is guarded so a zombie folder ref can't abort the
            -- listing; the Swift side filters out flagged (Recently-Deleted)
            -- folders so the decision stays unit-testable.
            repeat with f in (every folder)
                try
                    set isDel to my isDeletedFolder(f)
                    set fName to name of f
                    set fID to id of f
                    set nCount to count of notes of f
                    set delFlag to "0"
                    if isDel then set delFlag to "1"
                    set output to output & "F" & fs & fID & fs & fName & fs & (nCount as string) & fs & delFlag & rs
                end try
            end repeat
            -- Then, emit parent->child edges (guarded against zombie children).
            repeat with f in (every folder)
                try
                    set fID to id of f
                    repeat with s in (every folder of f)
                        try
                            set output to output & "E" & fs & fID & fs & (id of s) & rs
                        end try
                    end repeat
                end try
            end repeat
            return output
        end tell
        """

        let (out, err) = runAppleScript(script, [:], nil)
        if let err = err { throw NotesError.scriptFailed(err) }

        var folderMeta: [String: (name: String, count: Int?)] = [:]
        var folderOrder: [String] = []
        var childToParent: [String: String] = [:]

        for line in out.components(separatedBy: recordSep) where !line.isEmpty {
            let parts = line.components(separatedBy: fieldSep)
            guard parts.count >= 2 else { continue }

            if parts[0] == "F" && parts.count >= 4 {
                // Field 5 (deleted flag) is "1" for Recently-Deleted folders;
                // exclude them so they neither list nor act as path parents.
                // Absent flag (older protocol / partial record) => treat live.
                if parts.count >= 5 && parts[4] == "1" { continue }
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

    /// Search notes by title (default) or title+body (`fullText: true`).
    ///
    /// Served by reading the on-disk store (NotesStoreSearch), not AppleScript.
    /// The AppleScript `whose` filter costs one Apple-event round-trip per
    /// match, so a broad query times out on large stores even title-only
    /// (issue #13) — the backend, not the `plaintext contains` clause, was the
    /// problem. `total` is the full match count; pagination is applied here so
    /// the output schema is unchanged.
    public static func searchNotes(query: String, folder: String?, offset: Int, limit: Int, fullText: Bool = false) throws -> (total: Int, notes: [NoteSummary]) {
        let hits = try searchLookup(query, folder, fullText)
        // Clamp: dropFirst/prefix trap on negative counts, and library callers
        // bypass NotesTool's parameter validation.
        let page = hits.dropFirst(max(0, offset)).prefix(max(0, limit))
        let notes = page.map {
            NoteSummary(id: $0.id, title: $0.title, modified: $0.modified, snippet: $0.snippet)
        }
        return (hits.count, notes)
    }

    /// Test seam: store-backed search lookup. Defaults to the on-disk store
    /// reader; swappable in tests so the search path stays offline.
    public static var searchLookup: (_ query: String, _ folder: String?, _ fullText: Bool) throws -> [NotesStoreSearch.Hit] = NotesStoreSearch.search

    /// Every note in a folder, newest first. `searchNotes` needs a term to
    /// match on, so enumerating a folder — and diffing it for changes — has no
    /// path through search.
    public static func listNotes(folder: String?, offset: Int, limit: Int) throws -> (total: Int, notes: [NoteSummary]) {
        let hits = try listLookup(folder)
        let page = hits.dropFirst(max(0, offset)).prefix(max(0, limit))
        let notes = page.map {
            NoteSummary(id: $0.id, title: $0.title, modified: $0.modified, snippet: $0.snippet)
        }
        return (hits.count, notes)
    }

    /// Test seam, as `searchLookup`.
    public static var listLookup: (_ folder: String?) throws -> [NotesStoreSearch.Hit] = NotesStoreSearch.list

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
        \(DateFormatting.appleScriptComponentsHandler)
        tell application "Notes"
            set fs to (character id 31)
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
            set nDate to my atDateComponents(modification date of theNote)
            set nCreated to my atDateComponents(creation date of theNote)
            set nHTML to body of theNote
            return nID & fs & nName & fs & nFolder & fs & nDate & fs & nCreated & fs & nHTML
        end tell
        """

        let (out, err) = runAppleScript(script, env, nil)
        if let err = err {
            if err.contains("-1728") { throw NotesError.notFound }
            throw NotesError.scriptFailed(err)
        }

        let parts = out.components(separatedBy: fieldSep)
        guard parts.count >= 6 else {
            throw NotesError.parseFailure("failed to parse note data")
        }
        let noteTitle = parts[1]
        let htmlBody = parts[5...].joined(separator: fieldSep)
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
            modified: DateFormatting.isoFromAppleScriptComponents(parts[3]),
            created: DateFormatting.isoFromAppleScriptComponents(parts[4]),
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
        // Apple Notes always prepends the note's `name` property to the body as
        // the first (body-styled) line, and the LLM's Markdown body naturally
        // leads with the title as an H1 — the two collide into a duplicate
        // header (issue: double title line). Instead we DON'T set `name`: we
        // make the title the body's first line as an H1 and let Notes derive
        // the title from it. That yields a single, Title-styled header.
        let composed = composeBodyWithTitle(title: title, body: body)
        let htmlBody = NotesMarkdown.markdownToNotesHTML(composed)
        var env = [
            "APPLE_TOOLS_NOTES_BODY": htmlBody,
        ]

        // A folder of "" or only "/" separators has no usable segments —
        // treat it as no folder at all.
        let usableFolder = (folder?.split(separator: "/").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false) ? folder : nil

        let folderBinding: String
        let atClause: String
        if let folder = usableFolder {
            env["APPLE_TOOLS_NOTES_FOLDER"] = folder
            folderBinding = """
            set theFolder to do shell script "printenv APPLE_TOOLS_NOTES_FOLDER"
            """
            // Resolution order matters (issue: agents pass the `path` string
            // that the `folders` action reports, e.g. "Parent/Sub", and the
            // old code created a literal folder named "Parent/Sub"):
            //   1. exact-name match anywhere in the hierarchy (lookup is
            //      flattened; also covers folder names that contain "/")
            //   2. "/"-separated path walk, creating missing segments nested
            //   3. plain name with no "/": create at top level
            // Resolution uses live-only folder lookups (my liveFolderByName /
            // liveChildByName): `exists folder X` / `folder X` also match
            // Recently-Deleted folders, so a plain lookup could land the note in
            // the trash (issue #15). A name that matches only a deleted folder
            // resolves to missing value and falls through to creating a fresh
            // live folder.
            atClause = """
            set targetFolder to my liveFolderByName(theFolder)
                    if targetFolder is missing value then
                        set AppleScript's text item delimiters to "/"
                        set segs to text items of theFolder
                        set AppleScript's text item delimiters to ""
                        set acct to default account
                        repeat with i from 1 to count of segs
                            set seg to (item i of segs) as string
                            if seg is not "" then
                                if targetFolder is missing value then
                                    set existing to my liveChildByName(acct, seg)
                                    if existing is not missing value then
                                        set targetFolder to existing
                                    else
                                        set targetFolder to (make new folder at acct with properties {name:seg})
                                    end if
                                else
                                    set existing to my liveChildByName(targetFolder, seg)
                                    if existing is not missing value then
                                        set targetFolder to existing
                                    else
                                        set targetFolder to (make new folder at targetFolder with properties {name:seg})
                                    end if
                                end if
                            end if
                        end repeat
                    end if
                    set newNote to make new note at targetFolder with properties {body:theBody}
            """
        } else {
            folderBinding = ""
            atClause = """
            set newNote to make new note with properties {body:theBody}
            """
        }

        // Handlers are only needed when resolving into a folder; the no-folder
        // path never calls them.
        let handlers = usableFolder != nil ? folderScriptHandlers : ""
        let script = """
        \(handlers)
        set theBody to do shell script "printenv APPLE_TOOLS_NOTES_BODY"
        \(folderBinding)
        log "PHASE: prepare"
        tell application "Notes"
            set fs to (character id 31)
            log "PHASE: pre-commit"
            \(atClause)
            set noteID to id of newNote as string
            log "PHASE: committed id=" & noteID
            return noteID & fs & (name of newNote)
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

        let parts = out.components(separatedBy: fieldSep)
        guard parts.count >= 2 else {
            throw NotesError.parseFailure("note created but failed to parse response")
        }
        return CreatedNote(id: parts[0], title: parts[1])
    }

    /// Build the Markdown that becomes a new note's body so its first line is
    /// the title as an H1 — the line Apple Notes promotes to the note title.
    /// A leading heading (or plain line) in `body` that just repeats the title
    /// is dropped so the title isn't emitted twice.
    static func composeBodyWithTitle(title: String, body: String) -> String {
        var rest = body
        var lines = body.components(separatedBy: "\n")
        if let first = lines.first {
            let bare = first.drop(while: { $0 == "#" || $0 == " " })
            if String(bare).trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
                lines.removeFirst()
                // Also swallow a single blank line left under the old title.
                if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    lines.removeFirst()
                }
                rest = lines.joined(separator: "\n")
            }
        }
        let heading = "# \(title)"
        return rest.isEmpty ? heading : "\(heading)\n\n\(rest)"
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
            set fs to (character id 31)
            set theNote to \(whereClause)
            set existingBody to body of theNote
            log "PHASE: pre-commit"
            set body of theNote to existingBody & theContent
            set noteID to id of theNote as string
            log "PHASE: committed id=" & noteID
            set nPlain to plaintext of theNote
            set charCount to length of nPlain
            return noteID & fs & (name of theNote) & fs & charCount
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

        let parts = out.components(separatedBy: fieldSep)
        guard parts.count >= 3 else {
            throw NotesError.parseFailure("content appended but failed to parse response")
        }
        return AppendResult(id: parts[0], title: parts[1], totalLength: Int(parts[2]))
    }

    // MARK: - Move / delete / rename folder

    public struct ChangedNote {
        public let id: String
        public let title: String
        public let folder: String
        public let shared: Bool
    }

    /// App-wide `whose` lookups also match notes and folders in Recently
    /// Deleted, so every resolver here filters through isDeletedFolder.
    static let mutationHandlers = """
    \(folderScriptHandlers)
    on liveNotes(theKey)
        tell application "Notes"
            if theKey starts with "x-coredata:" then
                set ms to every note whose id is theKey
            else
                set ms to every note whose name is theKey
            end if
            set live to {}
            repeat with n in ms
                try
                    if not (my isDeletedFolder(container of n)) then set end of live to contents of n
                end try
            end repeat
        end tell
        return live
    end liveNotes

    on liveFolders(theKey)
        tell application "Notes"
            if theKey starts with "x-coredata:" then
                set ms to every folder whose id is theKey
            else
                set ms to every folder whose name is theKey
            end if
            set live to {}
            repeat with f in ms
                if not (my isDeletedFolder(f)) then set end of live to contents of f
            end repeat
        end tell
        return live
    end liveFolders

    on describeNote(n)
        tell application "Notes"
            set sh to "0"
            if shared of n then set sh to "1"
            -- Notes can't resolve `name of container of n` in one step (-1700).
            set c to container of n
            return (id of n) & (character id 31) & (name of n) & (character id 31) & (name of c) & (character id 31) & sh
        end tell
    end describeNote

    on describeFolder(f)
        tell application "Notes"
            set c to container of f
            return (id of f) & (character id 31) & (name of f) & (character id 31) & (name of c)
        end tell
    end describeFolder

    on listing(tag, things, isNote)
        set out to tag
        repeat with t in things
            if isNote then
                set out to out & (character id 30) & my describeNote(t)
            else
                set out to out & (character id 30) & my describeFolder(t)
            end if
        end repeat
        return out
    end listing
    """

    /// Prefix shared by move/delete: resolves exactly one live, unlocked note
    /// into `theNote`, or returns a NOTE_* status.
    static let resolveOneNote = """
    set theKey to do shell script "printenv APPLE_TOOLS_NOTES_KEY"
    set ms to my liveNotes(theKey)
    if (count of ms) is 0 then return "NOTE_NONE"
    if (count of ms) > 1 then return my listing("NOTE_MANY", ms, true)
    set theNote to item 1 of ms
    tell application "Notes"
        if password protected of theNote then return "NOTE_LOCKED"
    end tell
    """

    static let resolveOneFolder = """
    set folderKey to do shell script "printenv APPLE_TOOLS_NOTES_FOLDER"
    set fms to my liveFolders(folderKey)
    if (count of fms) is 0 then return "FOLDER_NONE"
    if (count of fms) > 1 then return my listing("FOLDER_MANY", fms, false)
    set theFolder to item 1 of fms
    """

    // applescript-runner: no-verifier — move/delete/rename are safe to retry: a
    // repeat lands the same state or reports "not found", never a duplicate.
    public static func moveNote(key: String, folder: String) throws -> ChangedNote {
        let script = """
        \(mutationHandlers)
        \(resolveOneNote)
        \(resolveOneFolder)
        log "PHASE: pre-commit"
        tell application "Notes" to move theNote to theFolder
        log "PHASE: committed"
        return "OK" & (character id 30) & my describeNote(theNote)
        """
        return try changedNote(runMutation(script, ["APPLE_TOOLS_NOTES_KEY": key, "APPLE_TOOLS_NOTES_FOLDER": folder], key: key, folder: folder))
    }

    public static func deleteNote(key: String) throws -> ChangedNote {
        let script = """
        \(mutationHandlers)
        \(resolveOneNote)
        set info to my describeNote(theNote)
        log "PHASE: pre-commit"
        tell application "Notes" to delete theNote
        log "PHASE: committed"
        return "OK" & (character id 30) & info
        """
        return try changedNote(runMutation(script, ["APPLE_TOOLS_NOTES_KEY": key], key: key, folder: nil))
    }

    // applescript-runner: no-verifier — see moveNote.
    public static func renameFolder(folder: String, newName: String) throws -> Folder {
        let script = """
        \(mutationHandlers)
        \(resolveOneFolder)
        set newName to do shell script "printenv APPLE_TOOLS_NOTES_NEW_NAME"
        tell application "Notes"
            repeat with s in (every folder of (container of theFolder))
                if (name of s) is newName and (id of s) is not (id of theFolder) and not (my isDeletedFolder(s)) then return "NAME_TAKEN"
            end repeat
            log "PHASE: pre-commit"
            set name of theFolder to newName
            log "PHASE: committed"
        end tell
        return "OK" & (character id 30) & my describeFolder(theFolder)
        """
        let f = try runMutation(script, ["APPLE_TOOLS_NOTES_FOLDER": folder, "APPLE_TOOLS_NOTES_NEW_NAME": newName], key: nil, folder: folder)
        return Folder(id: f[0], name: f[1], noteCount: nil, parentID: nil, path: nil)
    }

    /// Runs a mutation script and maps its status line to an error, or returns
    /// the fields of the single OK record.
    static func runMutation(_ script: String, _ env: [String: String], key: String?, folder: String?) throws -> [String] {
        let (out, err) = runAppleScript(script, env, nil)
        if let err = err { throw NotesError.scriptFailed(err) }
        let records = out.components(separatedBy: recordSep)
        let rows = records.dropFirst().map { $0.components(separatedBy: fieldSep) }
        func candidates() -> String {
            rows.filter { $0.count >= 3 }.map { "'\($0[1])' in '\($0[2])' (id \($0[0]))" }.joined(separator: "; ")
        }
        switch records[0] {
        case "OK":
            guard let row = rows.first, row.count >= 3 else { throw NotesError.parseFailure("changed, but failed to parse response") }
            return row
        case "NOTE_NONE": throw NotesError.notFound
        case "NOTE_MANY": throw NotesError.scriptFailed("more than one note is titled '\(key ?? "")'; pass the id of the one you mean: \(candidates())")
        case "NOTE_LOCKED": throw NotesError.scriptFailed("that note is locked with a password; unlock it in Notes first")
        case "FOLDER_NONE": throw NotesError.scriptFailed("no folder named '\(folder ?? "")'")
        case "FOLDER_MANY": throw NotesError.scriptFailed("more than one folder is named '\(folder ?? "")'; pass the id of the one you mean: \(candidates())")
        case "NAME_TAKEN": throw NotesError.scriptFailed("a folder with that name already exists alongside it")
        default: throw NotesError.parseFailure("unexpected response: \(out.prefix(200))")
        }
    }

    static func changedNote(_ row: [String]) throws -> ChangedNote {
        guard row.count >= 4 else { throw NotesError.parseFailure("changed, but failed to parse response") }
        return ChangedNote(id: row[0], title: row[1], folder: row[2], shared: row[3] == "1")
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
