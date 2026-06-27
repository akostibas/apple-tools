import EventKit
import Foundation

public struct RemindersTool: ProbeTool {
    private static let maxNotesLength = 100

    public let definition = ToolDefinition(
        name: "reminders",
        description: "Manage Apple Reminders. Use 'lists' to see available lists, 'search' to find reminders (by keyword, list, or date range), 'get' to view a single reminder's full details, 'create' to add one, 'complete' to mark done.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "lists, search, get, create, or complete"),
                "list_name": PropertySchema(type_: "string", description: "Filter by reminder list name (for search, create)"),
                "title": PropertySchema(type_: "string", description: "Reminder title (required for create)"),
                "due_date": PropertySchema(type_: "string", description: "ISO 8601 date, e.g. 2026-04-15T09:00:00Z (for create, search)"),
                "due_date_end": PropertySchema(type_: "string", description: "End of date range filter, ISO 8601 (for search)"),
                "notes": PropertySchema(type_: "string", description: "Reminder notes (for create)"),
                "id": PropertySchema(type_: "string", description: "Reminder identifier (required for complete, get)"),
                "query": PropertySchema(type_: "string", description: "Search keyword (optional for search)"),
                "show_completed": PropertySchema(type_: "boolean", description: "Include completed reminders (for search, default false)"),
            ],
            required: ["action"]
        )
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "lists":    .read,
        "search":   .read,
        "get":      .read,
        "create":   .readWrite,
        "complete": .readWrite,
    ])

    public init() {}

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        // Validate parameters before requesting EventKit access so that
        // invalid input gets a clear error without a TCC prompt.
        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "lists":
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            return listLists()
        case "search":
            let query = params?["query"]?.value as? String
            let listName = params?["list_name"]?.value as? String
            let dueDate = params?["due_date"]?.value as? String
            let dueDateEnd = params?["due_date_end"]?.value as? String
            let showCompleted = params?["show_completed"]?.value as? Bool ?? false
            if query == nil && listName == nil && dueDate == nil {
                return ("search requires at least one of: query, list_name, or due_date", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            return searchReminders(query: query, listName: listName, dueDate: dueDate, dueDateEnd: dueDateEnd, showCompleted: showCompleted)
        case "get":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            return getReminder(id: id)
        case "create":
            guard let title = params?["title"]?.value as? String, !title.isEmpty else {
                return ("missing required parameter: title", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            let listName = params?["list_name"]?.value as? String
            let dueDate = params?["due_date"]?.value as? String
            let notes = params?["notes"]?.value as? String
            return createReminder(title: title, listName: listName, dueDate: dueDate, notes: notes)
        case "complete":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            return completeReminder(id: id)
        default:
            return ("unknown action: \(action) (use lists, search, get, create, or complete)", true)
        }
    }

    private var accessDenied: (String, Bool) {
        (RemindersIntegration.RemindersError.accessDenied.description, true)
    }

    public func preflight() -> (ok: Bool, message: String) {
        return RemindersIntegration.preflight()
    }

    // MARK: - Lists

    private func listLists() -> (String, Bool) {
        let calendars = RemindersIntegration.allLists()
        let defaultList = RemindersIntegration.defaultListForNewReminders()
        let results = calendars.map { cal -> [String: Any] in
            var entry: [String: Any] = [
                "name": cal.title,
                "id": cal.calendarIdentifier,
            ]
            if cal == defaultList {
                entry["is_default"] = true
            }
            return entry
        }
        return (jsonString(results) ?? "[]", false)
    }

    // MARK: - Search

    private func searchReminders(query: String?, listName: String?, dueDate: String?, dueDateEnd: String?, showCompleted: Bool) -> (String, Bool) {
        var calendars: [EKCalendar]? = nil
        if let listName = listName {
            guard let resolved = RemindersIntegration.resolveLists(name: listName) else {
                return ("no reminder list found with name: \(listName)", true)
            }
            calendars = resolved
        }

        var startDate: Date? = nil
        var endDate: Date? = nil
        if let startStr = dueDate {
            guard let parsed = RemindersIntegration.parseDate(startStr) else {
                return ("invalid due_date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
            }
            startDate = parsed
            if let endStr = dueDateEnd {
                guard let d = RemindersIntegration.parseDate(endStr) else {
                    return ("invalid due_date_end format", true)
                }
                endDate = d
            } else {
                endDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: parsed) ?? parsed.addingTimeInterval(86400)
            }
        }

        let predicate: NSPredicate
        if showCompleted || startDate != nil {
            predicate = RemindersIntegration.predicateForAllReminders(in: calendars)
        } else {
            predicate = RemindersIntegration.predicateForIncompleteReminders(in: calendars)
        }
        var reminders = RemindersIntegration.fetchReminders(predicate: predicate)

        if !showCompleted {
            reminders = reminders.filter { !$0.isCompleted }
        }

        if let start = startDate, let end = endDate {
            reminders = reminders.filter { reminder in
                guard let dueComps = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: dueComps) else {
                    return false
                }
                return due >= start && due <= end
            }
        }

        if let query = query, !query.isEmpty {
            let queryLower = query.lowercased()
            reminders = reminders.filter { reminder in
                if let title = reminder.title, title.lowercased().contains(queryLower) { return true }
                if let notes = reminder.notes, notes.lowercased().contains(queryLower) { return true }
                return false
            }
        }

        var results = reminders.map { reminderToDict($0, truncateNotes: true) }

        // Enrich with subtask relationships from the Reminders SQLite DB.
        let ids = reminders.compactMap { $0.calendarItemExternalIdentifier }
        let parentMap = RemindersDB.parents(forChildIDs: ids)
        let subtaskMap = RemindersDB.subtasks(forParentIDs: ids)
        for i in results.indices {
            let id = ids[i]
            if let parent = parentMap[id] {
                results[i]["parent"] = liteDict(parent)
            }
            if let subs = subtaskMap[id], !subs.isEmpty {
                results[i]["subtasks"] = subs.map { liteDict($0) }
            }
        }

        let response: [String: Any] = [
            "count": results.count,
            "reminders": results,
        ]
        return (jsonString(response) ?? "{}", false)
    }

    // MARK: - Get

    private func getReminder(id: String) -> (String, Bool) {
        guard let reminder = RemindersIntegration.findReminder(id: id) else {
            return ("reminder not found with id: \(id)", true)
        }

        var dict = reminderToDict(reminder, truncateNotes: false)

        // Enrich with subtask relationships from the Reminders SQLite DB.
        let ekID = reminder.calendarItemExternalIdentifier ?? ""
        if !ekID.isEmpty {
            if let parent = RemindersDB.parent(forChildID: ekID) {
                dict["parent"] = liteDict(parent)
            }
            let subs = RemindersDB.subtasks(forParentID: ekID)
            if !subs.isEmpty {
                dict["subtasks"] = subs.map { liteDict($0) }
            }
        }

        return (jsonString(dict) ?? "{}", false)
    }

    // MARK: - Create

    private func createReminder(title: String, listName: String?, dueDate: String?, notes: String?) -> (String, Bool) {
        var list: EKCalendar? = nil
        if let listName = listName {
            guard let resolved = RemindersIntegration.resolveLists(name: listName), let cal = resolved.first else {
                return ("no reminder list found with name: \(listName)", true)
            }
            list = cal
        }

        var due: Date? = nil
        if let dueDateStr = dueDate {
            guard let date = RemindersIntegration.parseDate(dueDateStr) else {
                return ("invalid due_date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
            }
            due = date
        }

        let reminder: EKReminder
        do {
            reminder = try RemindersIntegration.createReminder(title: title, list: list, dueDate: due, notes: notes)
        } catch let error as RemindersIntegration.RemindersError {
            return (error.description, true)
        } catch {
            return ("failed to save reminder: \(error.localizedDescription)", true)
        }

        let response: [String: Any] = [
            "id": reminder.calendarItemExternalIdentifier ?? "",
            "title": reminder.title ?? "",
            "list": reminder.calendar.title,
        ]
        return (jsonString(response) ?? "{}", false)
    }

    // MARK: - Complete

    private func completeReminder(id: String) -> (String, Bool) {
        guard let reminder = RemindersIntegration.findReminder(id: id) else {
            return ("reminder not found with id: \(id)", true)
        }

        do {
            try RemindersIntegration.complete(reminder)
        } catch let error as RemindersIntegration.RemindersError {
            return (error.description, true)
        } catch {
            return ("failed to complete reminder: \(error.localizedDescription)", true)
        }

        return (jsonString(["title": reminder.title ?? "", "completed": true] as [String: Any]) ?? "{}", false)
    }

    // MARK: - LLM payload formatting

    private func reminderToDict(_ reminder: EKReminder, truncateNotes: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "id": reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": reminder.calendar.title,
            "completed": reminder.isCompleted,
        ]

        if let dueComps = reminder.dueDateComponents,
           let dueDate = Calendar.current.date(from: dueComps) {
            entry["due_date"] = DateFormatting.iso(dueDate)
        }

        if let notes = reminder.notes, !notes.isEmpty {
            if truncateNotes && notes.count > Self.maxNotesLength {
                entry["notes"] = String(notes.prefix(Self.maxNotesLength)) + "…"
            } else {
                entry["notes"] = notes
            }
        }

        if let priority = priorityLabel(reminder.priority) {
            entry["priority"] = priority
        }

        return entry
    }

    private func liteDict(_ lite: RemindersDB.LiteReminder) -> [String: Any] {
        return [
            "id": lite.id,
            "title": lite.title,
            "completed": lite.completed,
        ]
    }

    private func priorityLabel(_ priority: Int) -> String? {
        switch priority {
        case 1: return "high"
        case 5: return "medium"
        case 9: return "low"
        default: return nil
        }
    }

    private func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
