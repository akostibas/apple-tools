import Foundation

public struct NotesTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "notes",
        description: "Access Apple Notes. Actions: 'folders' (list folders), 'search' (find notes by keyword with pagination; matches titles by default, pass full_text=true to also search note bodies; a multi-word query is AND-of-terms — every word must appear, in any order, not only as an adjacent phrase; returns snippets only — use 'read' for full content), 'read' (get note content by ID or title), 'create' (new note in a folder), 'append' (add content to an existing note). Content is Markdown: headings (#, ##), **bold**, *italic*, ~~strike~~, `mono`, and -/1. lists round-trip. Apple Notes can't store links or checkboxes via this API, so [text](url) becomes 'text (url)' and '- [ ]' becomes a plain bullet on write; checkbox state on read may lag (read from the on-disk store).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "folders, search, read, create, or append"),
                "query": PropertySchema(type_: "string", description: "Search keyword(s) (required for search). Multiple words are AND-of-terms: every word must appear, in any order",
                    summary: "Search keyword", actions: ["search"]),
                "folder": PropertySchema(type_: "string", description: "Folder name or '/'-separated path as reported by 'folders' (for search, create). On create, an existing folder is used as-is; a path with missing segments creates them nested",
                    summary: "Folder name or '/'-separated path", actions: ["search", "create"]),
                "id": PropertySchema(type_: "string", description: "Note ID, x-coredata:// URI (for read, append)",
                    summary: "Note ID (x-coredata:// URI)", actions: ["read", "append"]),
                "title": PropertySchema(type_: "string", description: "Note title (for read, append, create)",
                    summary: "Note title", actions: ["read", "append", "create"]),
                "body": PropertySchema(type_: "string", description: "Note body as Markdown (for create)",
                    summary: "Note body as Markdown", actions: ["create"]),
                "text": PropertySchema(type_: "string", description: "Markdown to append (required for append)",
                    summary: "Markdown to append", actions: ["append"]),
                "offset": PropertySchema(type_: "integer", description: "Pagination offset, 0-based (for search, default 0)",
                    summary: "Pagination offset, 0-based (default 0)", actions: ["search"]),
                "limit": PropertySchema(type_: "integer", description: "Max results to return (for search, default 20, max 50)",
                    summary: "Max results (default 20, max 50)", actions: ["search"]),
                "full_text": PropertySchema(type_: "boolean", description: "Search note bodies, not just titles (for search, default false). Reads the on-disk store; results may lag a just-edited note by Notes' sync cadence.",
                    summary: "Search note bodies, not just titles (default false)", actions: ["search"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Read, search, create, and append Apple Notes.",
        actions: [
            ActionHelp(name: "folders", summary: "List folders",
                example: "apple-tools notes folders"),
            ActionHelp(name: "search", summary: "Find notes by keyword (titles, or bodies with --full_text)",
                example: "apple-tools notes search --query <text> [--folder <f>] [--full_text] [--limit <n>] [--offset <n>]", required: ["query"]),
            ActionHelp(name: "read", summary: "Get note content by ID or title",
                example: "apple-tools notes read (--id <id> | --title <t>)"),
            ActionHelp(name: "create", summary: "Create a new note in a folder",
                example: "apple-tools notes create --title <t> [--body <md>] [--folder <f>]", required: ["title"]),
            ActionHelp(name: "append", summary: "Add content to an existing note",
                example: "apple-tools notes append (--id <id> | --title <t>) --text <md>", required: ["text"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "folders": .read,
        "search":  .read,
        "read":    .read,
        "create":  .readWrite,
        "append":  .readWrite,
    ])

    public init() {}

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "folders":
            return listFolders()
        case "search":
            guard let query = params?["query"]?.value as? String, !query.isEmpty else {
                return ("missing required parameter: query", true)
            }
            let folder = params?["folder"]?.value as? String
            let offset = max(0, intParam(params, key: "offset") ?? 0)
            let limit = clamp(intParam(params, key: "limit") ?? 20, min: 1, max: 50)
            let fullText = boolParam(params, key: "full_text") ?? false
            return search(query: query, folder: folder, offset: offset, limit: limit, fullText: fullText)
        case "read":
            let id = params?["id"]?.value as? String
            let title = params?["title"]?.value as? String
            guard id != nil || title != nil else {
                return ("read requires 'id' or 'title' parameter", true)
            }
            return read(id: id, title: title)
        case "create":
            guard let title = params?["title"]?.value as? String, !title.isEmpty else {
                return ("missing required parameter: title", true)
            }
            let body = params?["body"]?.value as? String ?? ""
            let folder = params?["folder"]?.value as? String
            return create(title: title, body: body, folder: folder)
        case "append":
            let id = params?["id"]?.value as? String
            let title = params?["title"]?.value as? String
            guard id != nil || title != nil else {
                return ("append requires 'id' or 'title' parameter", true)
            }
            guard let text = params?["text"]?.value as? String, !text.isEmpty else {
                return ("missing required parameter: text", true)
            }
            return append(id: id, title: title, text: text)
        default:
            return ("unknown action: \(action) (use folders, search, read, create, or append)", true)
        }
    }

    public func preflight() -> (ok: Bool, message: String) {
        return NotesIntegration.preflight()
    }

    // MARK: - Folders

    private func listFolders() -> (String, Bool) {
        let folders: [NotesIntegration.Folder]
        do {
            folders = try NotesIntegration.listFolders()
        } catch let error as NotesIntegration.NotesError {
            return (error.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        let entries = folders.map { folder -> [String: Any] in
            var entry: [String: Any] = [
                "id": folder.id,
                "name": folder.name,
            ]
            if let count = folder.noteCount {
                entry["note_count"] = count
            }
            if let parentID = folder.parentID {
                entry["parent_id"] = parentID
            }
            if let path = folder.path {
                entry["path"] = path
            }
            return entry
        }

        let response: [String: Any] = [
            "count": entries.count,
            "folders": entries,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Search

    private func search(query: String, folder: String?, offset: Int, limit: Int, fullText: Bool) -> (String, Bool) {
        let total: Int
        let notes: [NotesIntegration.NoteSummary]
        do {
            (total, notes) = try NotesIntegration.searchNotes(query: query, folder: folder, offset: offset, limit: limit, fullText: fullText)
        } catch let error as NotesIntegration.NotesError {
            return (error.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        let entries = notes.map { n -> [String: Any] in
            return [
                "id": n.id,
                "title": n.title,
                "modified": n.modified,
                "snippet": n.snippet,
            ]
        }

        let response: [String: Any] = [
            "total": total,
            "offset": offset,
            "limit": limit,
            "count": entries.count,
            "notes": entries,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Read

    private func read(id: String?, title: String?) -> (String, Bool) {
        let note: NotesIntegration.Note
        do {
            note = try NotesIntegration.readNote(id: id, title: title)
        } catch let error as NotesIntegration.NotesError {
            return (error.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        let response: [String: Any] = [
            "id": note.id,
            "title": note.title,
            "folder": note.folder,
            "modified": note.modified,
            "created": note.created,
            "content": note.content,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Create

    private func create(title: String, body: String, folder: String?) -> (String, Bool) {
        let created: NotesIntegration.CreatedNote
        do {
            created = try NotesIntegration.createNote(title: title, body: body, folder: folder)
        } catch let error as NotesIntegration.NotesError {
            return (error.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        var response: [String: Any] = [
            "id": created.id,
            "title": created.title,
        ]
        if let folder = folder {
            response["folder"] = folder
        }
        return (jsonEncode(response), false)
    }

    // MARK: - Append

    private func append(id: String?, title: String?, text: String) -> (String, Bool) {
        let result: NotesIntegration.AppendResult
        do {
            result = try NotesIntegration.appendToNote(id: id, title: title, text: text)
        } catch let error as NotesIntegration.NotesError {
            return (error.description, true)
        } catch {
            return (error.localizedDescription, true)
        }

        var response: [String: Any] = [
            "id": result.id,
            "title": result.title,
        ]
        if let len = result.totalLength {
            response["total_length"] = len
        }
        return (jsonEncode(response), false)
    }

    // MARK: - Helpers

    private func intParam(_ params: [String: AnyCodable]?, key: String) -> Int? {
        guard let val = params?[key]?.value else { return nil }
        if let i = val as? Int { return i }
        if let d = val as? Double { return Int(d) }
        if let s = val as? String { return Int(s) }
        return nil
    }

    private func boolParam(_ params: [String: AnyCodable]?, key: String) -> Bool? {
        guard let val = params?[key]?.value else { return nil }
        if let b = val as? Bool { return b }
        if let i = val as? Int { return i != 0 }
        if let s = val as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return nil
    }

    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        return Swift.min(Swift.max(value, min), max)
    }

    private func jsonEncode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed to serialize response\"}"
        }
        return str
    }
}
