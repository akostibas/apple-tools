import EventKit
import Foundation

public struct RemindersTool: ProbeTool {
    private static let maxNotesLength = 100

    public let definition = ToolDefinition(
        name: "reminders",
        description: "Manage Apple Reminders. Use 'lists' to see available lists, 'search' to find reminders (by keyword, list, or date range), 'get' to view a single reminder's full details, 'create' to add one, 'update' to change one, 'delete' to remove one, 'create-list' to add a new list, 'complete' to mark done.",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "lists, search, get, create, update, delete, create-list, or complete"),
                "list_name": PropertySchema(type_: "string", description: "Reminder list name: filter for search, target for create, destination for update",
                    summary: "Reminder list name", actions: ["search", "create", "update"]),
                "title": PropertySchema(type_: "string", description: "Reminder title (required for create; new title for update)",
                    summary: "Reminder title", actions: ["create", "update"]),
                "priority": PropertySchema(type_: "string", description: "high, medium, low, or none (for create, update)",
                    summary: "high, medium, low, or none", actions: ["create", "update"]),
                "recurrence": PropertySchema(type_: "string", description: "Repeat rule for create/update, RFC 5545 RRULE: e.g. FREQ=WEEKLY;BYDAY=TU or FREQ=MONTHLY;UNTIL=20271231. Plain daily/weekly/monthly/yearly also work. Needs a due date. On update pass 'none' to stop repeating.",
                    summary: "RRULE, e.g. FREQ=WEEKLY;BYDAY=TU ('none' clears on update)", actions: ["create", "update"]),
                "name": PropertySchema(type_: "string", description: "New list name (required for create-list)",
                    summary: "New list name", actions: ["create-list"]),
                "account": PropertySchema(type_: "string", description: "Account/source to hold the new list, e.g. iCloud (optional for create-list)",
                    summary: "Account/source for the new list, e.g. iCloud", actions: ["create-list"]),
                "due_date": PropertySchema(type_: "string", description: "ISO 8601 date, e.g. 2026-04-15T09:00:00Z (for create, search, update; 'none' clears it on update)",
                    summary: "ISO 8601 due date, e.g. 2026-04-15T09:00:00Z", actions: ["search", "create", "update"]),
                "due_date_end": PropertySchema(type_: "string", description: "End of date range filter, ISO 8601 (for search)",
                    summary: "End of date-range filter, ISO 8601", actions: ["search"]),
                "notes": PropertySchema(type_: "string", description: "Reminder notes (for create, update)",
                    summary: "Reminder notes", actions: ["create", "update"]),
                "id": PropertySchema(type_: "string", description: "Reminder identifier (required for get, update, delete, complete)",
                    summary: "Reminder identifier", actions: ["get", "update", "delete", "complete"]),
                "query": PropertySchema(type_: "string", description: "Search keyword (optional for search)",
                    summary: "Search keyword", actions: ["search"]),
                "show_completed": PropertySchema(type_: "boolean", description: "Include completed reminders (for search, default false)",
                    summary: "Include completed reminders (default false)", actions: ["search"]),
                "flagged": PropertySchema(type_: "boolean", description: "For search: only return flagged reminders (default false). For create/update: set or clear the flag.",
                    summary: "Search: only flagged. Create/update: set the flag", actions: ["search", "create", "update"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Manage Apple Reminders — list, search, create, update, delete, and complete.",
        actions: [
            ActionHelp(name: "lists", summary: "See available reminder lists",
                example: "apple-tools reminders lists"),
            ActionHelp(name: "search", summary: "Find reminders by keyword, list, or date range",
                example: "apple-tools reminders search [--query <text>] [--list_name <name>] [--due_date <date>] [--due_date_end <date>] [--show_completed] [--flagged]"),
            ActionHelp(name: "get", summary: "View a single reminder's full details",
                example: "apple-tools reminders get --id <id>", required: ["id"]),
            ActionHelp(name: "create", summary: "Add a reminder",
                example: "apple-tools reminders create --title <text> [--list_name <name>] [--due_date <date>] [--notes <text>] [--priority <p>] [--flagged] [--recurrence <rrule>]", required: ["title"]),
            ActionHelp(name: "update", summary: "Change a reminder's title, notes, due date, list, priority, flag, or repeat",
                example: "apple-tools reminders update --id <id> [--title <text>] [--due_date <date|none>] [--list_name <name>] [--notes <text>] [--priority <p>] [--flagged true|false] [--recurrence <rrule|none>]", required: ["id"]),
            ActionHelp(name: "delete", summary: "Delete a reminder (a repeating one is deleted entirely)",
                example: "apple-tools reminders delete --id <id>", required: ["id"]),
            ActionHelp(name: "create-list", summary: "Add a new reminder list",
                example: "apple-tools reminders create-list --name <name> [--account <src>]", required: ["name"]),
            ActionHelp(name: "complete", summary: "Mark a reminder done",
                example: "apple-tools reminders complete --id <id>", required: ["id"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "lists":       .read,
        "search":      .read,
        "get":         .read,
        "create":      .readWrite,
        "update":      .readWrite,
        "delete":      .readWrite,
        "create-list": .readWrite,
        "complete":    .readWrite,
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
            let flaggedOnly = params?["flagged"]?.value as? Bool ?? false
            if query == nil && listName == nil && dueDate == nil && dueDateEnd == nil && !flaggedOnly {
                return ("search requires at least one of: query, list_name, due_date, due_date_end, or flagged", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            return searchReminders(query: query, listName: listName, dueDate: dueDate, dueDateEnd: dueDateEnd, showCompleted: showCompleted, flaggedOnly: flaggedOnly)
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
            return saveReminder(RemindersIntegration.newReminder(), params: params ?? [:], isNew: true)
        case "update", "delete":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            guard let reminder = RemindersIntegration.findReminder(id: id) else {
                return ("reminder not found with id: \(id)", true)
            }
            guard reminder.calendar.allowsContentModifications else {
                return (readOnlyMessage(reminder.calendar), true)
            }
            return action == "update"
                ? saveReminder(reminder, params: params ?? [:], isNew: false)
                : deleteReminder(reminder)
        case "create-list":
            guard let name = params?["name"]?.value as? String, !name.isEmpty else {
                return ("missing required parameter: name", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            let account = params?["account"]?.value as? String
            return createList(name: name, account: account)
        case "complete":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            guard RemindersIntegration.requestAccess() else { return accessDenied }
            return completeReminder(id: id)
        default:
            return ("unknown action: \(action) (use lists, search, get, create, update, delete, create-list, or complete)", true)
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

    private func searchReminders(query: String?, listName: String?, dueDate: String?, dueDateEnd: String?, showCompleted: Bool, flaggedOnly: Bool) -> (String, Bool) {
        var calendars: [EKCalendar]? = nil
        if let listName = listName {
            guard let resolved = RemindersIntegration.resolveLists(name: listName) else {
                return ("no reminder list found with name: \(listName)", true)
            }
            calendars = resolved
        }

        // Parse the range bounds independently so an upper bound works on its
        // own: `due_date_end` without `due_date` means "everything due at or
        // before X" rather than being silently ignored (#38).
        var startDate: Date? = nil
        var endDate: Date? = nil
        if let startStr = dueDate {
            guard let parsed = RemindersIntegration.parseDate(startStr) else {
                return ("invalid due_date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
            }
            startDate = parsed
        }
        if let endStr = dueDateEnd {
            guard let parsed = RemindersIntegration.parseDate(endStr) else {
                return ("invalid due_date_end format", true)
            }
            endDate = parsed
        }
        // A lone `due_date` means "due on that day": bound the (otherwise
        // point) range to end-of-day so the whole day matches. A lone
        // `due_date_end` stays open at the bottom.
        if let start = startDate, endDate == nil {
            endDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: start) ?? start.addingTimeInterval(86400)
        }

        let predicate: NSPredicate
        if showCompleted || startDate != nil || endDate != nil {
            predicate = RemindersIntegration.predicateForAllReminders(in: calendars)
        } else {
            predicate = RemindersIntegration.predicateForIncompleteReminders(in: calendars)
        }
        var reminders = RemindersIntegration.fetchReminders(predicate: predicate)

        if !showCompleted {
            reminders = reminders.filter { !$0.isCompleted }
        }

        if startDate != nil || endDate != nil {
            reminders = reminders.filter { reminder in
                guard let dueComps = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: dueComps) else {
                    return false
                }
                if let start = startDate, due < start { return false }
                if let end = endDate, due > end { return false }
                return true
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

        // Flag state and subtask relationships both come from the Reminders
        // SQLite DB (neither is exposed by EventKit). An unreadable store makes
        // everything look unflagged and childless, so ask once and say so.
        // Under `flaggedOnly` that's not a footnote — the filter would drop
        // every reminder and report a confident, wrong "you have none".
        let dbIssue = RemindersDB.unavailableReason()
        if flaggedOnly, let reason = dbIssue {
            return ("cannot filter by flag: \(reason)", true)
        }

        var results = reminders.map { reminderToDict($0, truncateNotes: true) }

        if dbIssue == nil {
            let candidateIDs = reminders.map { $0.calendarItemExternalIdentifier ?? $0.calendarItemIdentifier }
            let flaggedIDs = RemindersDB.flagged(forIDs: candidateIDs)
            if flaggedOnly {
                reminders = reminders.filter { flaggedIDs.contains($0.calendarItemExternalIdentifier ?? $0.calendarItemIdentifier) }
            }
            results = reminders.map { reminderToDict($0, truncateNotes: true) }

            // One entry per (surviving) reminder, falling back to the local
            // identifier when the external one is nil, so ids[i] stays aligned
            // with results[i].
            let ids = reminders.map { $0.calendarItemExternalIdentifier ?? $0.calendarItemIdentifier }
            let parentMap = RemindersDB.parents(forChildIDs: ids)
            let subtaskMap = RemindersDB.subtasks(forParentIDs: ids)
            for i in results.indices {
                let id = ids[i]
                results[i]["is_flagged"] = flaggedIDs.contains(id)
                if let parent = parentMap[id] {
                    results[i]["parent"] = liteDict(parent)
                }
                if let subs = subtaskMap[id], !subs.isEmpty {
                    results[i]["subtasks"] = subs.map { liteDict($0) }
                }
            }
        }

        var response: [String: Any] = [
            "count": results.count,
            "reminders": results,
        ]
        if let reason = dbIssue { response["warnings"] = [reason] }
        return (jsonString(response) ?? "{}", false)
    }

    // MARK: - Get

    private func getReminder(id: String) -> (String, Bool) {
        guard let reminder = RemindersIntegration.findReminder(id: id) else {
            return ("reminder not found with id: \(id)", true)
        }

        var dict = reminderToDict(reminder, truncateNotes: false)

        // Enrich with flag state and subtask relationships from the Reminders
        // SQLite DB (neither is exposed by EventKit). If that store is
        // unreadable the enrichment is absent, not false — say which.
        let ekID = reminder.calendarItemExternalIdentifier ?? ""
        if let reason = RemindersDB.unavailableReason() {
            dict["warnings"] = [reason]
        } else {
            dict["is_flagged"] = ekID.isEmpty ? false : RemindersDB.isFlagged(forID: ekID)
            if !ekID.isEmpty {
                if let parent = RemindersDB.parent(forChildID: ekID) {
                    dict["parent"] = liteDict(parent)
                }
                let subs = RemindersDB.subtasks(forParentID: ekID)
                if !subs.isEmpty {
                    dict["subtasks"] = subs.map { liteDict($0) }
                }
            }
        }

        return (jsonString(dict) ?? "{}", false)
    }

    // MARK: - Create / update / delete

    private static let editableFields = ["title", "notes", "due_date", "list_name", "priority", "recurrence", "flagged"]
    private static let priorities = ["high": 1, "medium": 5, "low": 9, "none": 0]

    /// Validates every field before touching `reminder`: the EKEventStore is
    /// shared, so a half-applied edit would linger in a long-lived host.
    private func saveReminder(_ reminder: EKReminder, params p: [String: AnyCodable], isNew: Bool) -> (String, Bool) {
        func str(_ key: String) -> String? { p[key]?.value as? String }
        func clears(_ key: String) -> Bool { !isNew && str(key)?.lowercased() == "none" }

        if !isNew, !Self.editableFields.contains(where: { p[$0] != nil }) {
            return ("nothing to update: pass at least one of " + Self.editableFields.joined(separator: ", "), true)
        }
        if let title = str("title"), title.isEmpty { return ("title can't be empty", true) }

        var list: EKCalendar?
        if let name = str("list_name") {
            guard let cal = RemindersIntegration.resolveLists(name: name)?.first else {
                return ("no reminder list found with name: \(name)", true)
            }
            guard cal.allowsContentModifications else { return (readOnlyMessage(cal), true) }
            list = cal
        }
        var due: Date?
        if let s = str("due_date"), !clears("due_date") {
            guard let d = RemindersIntegration.parseDate(s) else {
                return ("invalid due_date format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)", true)
            }
            due = d
        }
        var priority: Int?
        if let s = str("priority") {
            guard let v = Self.priorities[s.lowercased()] else { return ("priority must be high, medium, low, or none", true) }
            priority = v
        }
        var rule: EKRecurrenceRule?
        if let s = str("recurrence"), !clears("recurrence") {
            do { rule = try CalendarRecurrence.parse(s) } catch { return ("\(error)", true) }
        }
        let hasDue = due != nil || (reminder.dueDateComponents != nil && !clears("due_date"))
        let repeats = rule != nil || (reminder.hasRecurrenceRules && !clears("recurrence"))
        if repeats && !hasDue {
            return ("a repeating reminder needs a due date", true)
        }

        if let title = str("title") { reminder.title = title }
        if let notes = str("notes") { reminder.notes = notes.isEmpty ? nil : notes }
        if let list = list { reminder.calendar = list }
        if let due = due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: due)
        } else if clears("due_date") {
            reminder.dueDateComponents = nil
        }
        if let priority = priority { reminder.priority = priority }
        if let rule = rule {
            reminder.recurrenceRules = [rule]
        } else if clears("recurrence") {
            reminder.recurrenceRules = nil
        }

        do {
            try RemindersIntegration.save(reminder)
        } catch {
            return ("\(error)", true)
        }

        var result = reminderToDict(reminder, truncateNotes: false)
        if let flagged = p["flagged"]?.value as? Bool {
            do {
                try RemindersIntegration.setFlagged(reminder, flagged)
                result["is_flagged"] = flagged
            } catch {
                return ("reminder saved, but \(error)", true)
            }
        }
        return (jsonString(result) ?? "{}", false)
    }

    private func deleteReminder(_ reminder: EKReminder) -> (String, Bool) {
        let result: [String: Any] = [
            "id": reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "deleted": true,
        ]
        do {
            try RemindersIntegration.delete(reminder)
        } catch {
            return ("\(error)", true)
        }
        return (jsonString(result) ?? "{}", false)
    }

    private func readOnlyMessage(_ list: EKCalendar) -> String {
        "the list '\(list.title)' is read-only, so its reminders can't be changed here"
    }

    // MARK: - Create list

    private func createList(name: String, account: String?) -> (String, Bool) {
        let list: EKCalendar
        do {
            list = try RemindersIntegration.createList(name: name, account: account)
        } catch let error as RemindersIntegration.RemindersError {
            return (error.description, true)
        } catch {
            return ("failed to create reminder list: \(error.localizedDescription)", true)
        }

        let response: [String: Any] = [
            "id": list.calendarIdentifier,
            "name": list.title,
            "account": list.source.title,
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

        // Reminder due times are floating wall-clock (no zone). Emit them
        // zone-less so the server can label — never convert — them (#824). A
        // timed reminder yields "YYYY-MM-DDTHH:MM:SS"; a date-only one yields
        // "YYYY-MM-DD".
        if let dueComps = reminder.dueDateComponents,
           let due = DateFormatting.floatingLocal(from: dueComps) {
            entry["due_date"] = due
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

        if let rule = reminder.recurrenceRules?.first {
            entry["recurrence"] = CalendarRecurrence.format(rule)
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
