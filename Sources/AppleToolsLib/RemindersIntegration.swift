import EventKit
import Foundation

/// Shared Apple Reminders (EventKit) integration. All EventKit access for
/// reminders lives here.
///
/// Consumers: RemindersTool (LLM tool wrapper) and any future reminders
/// integration point.
///
/// Design: stateless enum with static methods. A single shared EKEventStore
/// is retained internally because EventKit expects a long-lived store.
public enum RemindersIntegration {

    private static let store = EKEventStore()

    // MARK: - Types

    public enum RemindersError: Error, CustomStringConvertible {
        case accessDenied
        case listNotFound(String)
        case reminderNotFound(String)
        case invalidDate(String)
        case saveFailed(String)
        case completeFailed(String)

        public var description: String {
            switch self {
            case .accessDenied:
                return "Reminders access denied. Grant permission in System Settings → Privacy & Security → Reminders."
            case .listNotFound(let name):
                return "no reminder list found with name: \(name)"
            case .reminderNotFound(let id):
                return "reminder not found with id: \(id)"
            case .invalidDate(let field):
                return "invalid \(field) format (use ISO 8601, e.g. 2026-04-15T09:00:00Z)"
            case .saveFailed(let reason):
                return "failed to save reminder: \(reason)"
            case .completeFailed(let reason):
                return "failed to complete reminder: \(reason)"
            }
        }
    }

    // MARK: - Access

    public static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { result, _ in
                granted = result
                semaphore.signal()
            }
        } else {
            store.requestAccess(to: .reminder) { result, _ in
                granted = result
                semaphore.signal()
            }
        }

        semaphore.wait()
        return granted
    }

    public static func preflight() -> (ok: Bool, message: String) {
        let granted = requestAccess()
        return (granted, granted ? "reminders access granted" : "reminders access denied")
    }

    // MARK: - Lists

    public static func allLists() -> [EKCalendar] {
        store.calendars(for: .reminder)
    }

    public static func defaultListForNewReminders() -> EKCalendar? {
        store.defaultCalendarForNewReminders()
    }

    /// Resolve reminder lists by case-insensitive name match.
    public static func resolveLists(name: String) -> [EKCalendar]? {
        let matching = store.calendars(for: .reminder).filter { $0.title.lowercased() == name.lowercased() }
        return matching.isEmpty ? nil : matching
    }

    // MARK: - Fetch

    /// Synchronously fetch reminders matching a predicate.
    public static func fetchReminders(predicate: NSPredicate) -> [EKReminder] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in
            result = reminders ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Predicate matching all reminders (complete + incomplete) in the given lists.
    public static func predicateForAllReminders(in calendars: [EKCalendar]?) -> NSPredicate {
        store.predicateForReminders(in: calendars)
    }

    /// Predicate matching incomplete reminders in the given lists.
    public static func predicateForIncompleteReminders(in calendars: [EKCalendar]?) -> NSPredicate {
        store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
    }

    /// Find a reminder by its calendarItemExternalIdentifier or calendarItemIdentifier.
    public static func findReminder(id: String) -> EKReminder? {
        let predicate = predicateForAllReminders(in: nil)
        let all = fetchReminders(predicate: predicate)
        return all.first { $0.calendarItemExternalIdentifier == id || $0.calendarItemIdentifier == id }
    }

    // MARK: - Mutations

    public static func createReminder(
        title: String,
        list: EKCalendar?,
        dueDate: Date?,
        notes: String?
    ) throws -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list ?? store.defaultCalendarForNewReminders()

        if let dueDate = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: dueDate
            )
        }
        if let notes = notes {
            reminder.notes = notes
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersError.saveFailed(error.localizedDescription)
        }
        return reminder
    }

    public static func complete(_ reminder: EKReminder) throws {
        reminder.isCompleted = true
        reminder.completionDate = Date()
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersError.completeFailed(error.localizedDescription)
        }
    }

    // MARK: - Date parsing

    /// Parse ISO 8601 with optional fractional seconds. Matches the behavior
    /// the Reminders tool relied on before the integration extraction.
    public static func parseDate(_ str: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }
        let fmtBasic = ISO8601DateFormatter()
        return fmtBasic.date(from: str)
    }
}
