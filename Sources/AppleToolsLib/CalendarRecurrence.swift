import EventKit
import Foundation

/// RFC 5545 RRULE <-> EKRecurrenceRule. EventKit has no public RRULE parser,
/// so this covers the subset EKRecurrenceRule can represent and rejects the rest.
public enum CalendarRecurrence {

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    private static let frequencies: [String: EKRecurrenceFrequency] = [
        "DAILY": .daily, "WEEKLY": .weekly, "MONTHLY": .monthly, "YEARLY": .yearly,
    ]
    private static let weekdays: [String: EKWeekday] = [
        "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
        "TH": .thursday, "FR": .friday, "SA": .saturday,
    ]

    /// Parse an RRULE (optionally `RRULE:`-prefixed) or a bare `daily`/`weekly`/
    /// `monthly`/`yearly`. UNTIL is read in `timeZone` when it carries no zone.
    public static func parse(_ input: String, timeZone: TimeZone = .current) throws -> EKRecurrenceRule {
        var text = input.trimmingCharacters(in: .whitespaces)
        if text.uppercased().hasPrefix("RRULE:") { text = String(text.dropFirst(6)) }
        if frequencies[text.uppercased()] != nil { text = "FREQ=" + text }

        var parts: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard kv.count == 2, !kv[1].isEmpty else { throw ParseError(description: "malformed recurrence part: \(pair)") }
            guard parts[kv[0]] == nil else { throw ParseError(description: "duplicate recurrence part: \(kv[0])") }
            parts[kv[0]] = kv[1]
        }

        guard let freqStr = parts.removeValue(forKey: "FREQ"), let freq = frequencies[freqStr] else {
            throw ParseError(description: "recurrence needs FREQ=DAILY, WEEKLY, MONTHLY, or YEARLY")
        }

        var interval = 1
        if let s = parts.removeValue(forKey: "INTERVAL") {
            guard let n = Int(s), n > 0 else { throw ParseError(description: "INTERVAL must be a positive integer") }
            interval = n
        }

        var end: EKRecurrenceEnd?
        let count = parts.removeValue(forKey: "COUNT")
        let until = parts.removeValue(forKey: "UNTIL")
        switch (count, until) {
        case (.some, .some):
            throw ParseError(description: "recurrence can't have both COUNT and UNTIL")
        case (.some(let s), nil):
            guard let n = Int(s), n > 0 else { throw ParseError(description: "COUNT must be a positive integer") }
            end = EKRecurrenceEnd(occurrenceCount: n)
        case (nil, .some(let s)):
            guard let d = parseUntil(s, timeZone: timeZone) else {
                throw ParseError(description: "UNTIL must look like 20261231, 20261231T235959Z, or 2026-12-31")
            }
            end = EKRecurrenceEnd(end: d)
        case (nil, nil):
            break
        }

        let days = try parts.removeValue(forKey: "BYDAY").map(parseDays)
        let monthDays = try parts.removeValue(forKey: "BYMONTHDAY").map { try ints($0, "BYMONTHDAY", range: -31...31) }
        let months = try parts.removeValue(forKey: "BYMONTH").map { try ints($0, "BYMONTH", range: 1...12) }
        let setPositions = try parts.removeValue(forKey: "BYSETPOS").map { try ints($0, "BYSETPOS", range: -366...366) }
        // WKST is harmless to drop; Calendar.app emits it on weekly rules.
        parts.removeValue(forKey: "WKST")

        if let unknown = parts.keys.sorted().first {
            throw ParseError(description: "unsupported recurrence part: \(unknown) (supported: FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS)")
        }
        if days?.contains(where: { $0.weekNumber != 0 }) == true, freq != .monthly, freq != .yearly {
            throw ParseError(description: "numbered BYDAY (e.g. 2TU) only works with MONTHLY or YEARLY")
        }

        return EKRecurrenceRule(
            recurrenceWith: freq,
            interval: interval,
            daysOfTheWeek: days,
            daysOfTheMonth: monthDays?.map { NSNumber(value: $0) },
            monthsOfTheYear: months?.map { NSNumber(value: $0) },
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: setPositions?.map { NSNumber(value: $0) },
            end: end
        )
    }

    /// Serialize back to an RRULE string (no `RRULE:` prefix), UNTIL in UTC.
    public static func format(_ rule: EKRecurrenceRule) -> String {
        let freq = frequencies.first { $0.value == rule.frequency }?.key ?? "DAILY"
        var parts = ["FREQ=\(freq)"]
        if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let codes = days.map { day -> String in
                let code = weekdays.first { $0.value == day.dayOfTheWeek }?.key ?? "MO"
                return day.weekNumber == 0 ? code : "\(day.weekNumber)\(code)"
            }
            parts.append("BYDAY=" + codes.joined(separator: ","))
        }
        if let v = rule.daysOfTheMonth, !v.isEmpty { parts.append("BYMONTHDAY=" + join(v)) }
        if let v = rule.monthsOfTheYear, !v.isEmpty { parts.append("BYMONTH=" + join(v)) }
        if let v = rule.setPositions, !v.isEmpty { parts.append("BYSETPOS=" + join(v)) }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.timeZone = TimeZone(identifier: "UTC")
                fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                parts.append("UNTIL=" + fmt.string(from: date))
            } else if end.occurrenceCount > 0 {
                parts.append("COUNT=\(end.occurrenceCount)")
            }
        }
        return parts.joined(separator: ";")
    }

    // MARK: - Helpers

    private static func parseDays(_ s: String) throws -> [EKRecurrenceDayOfWeek] {
        try s.split(separator: ",").map { token in
            let code = String(token.suffix(2))
            let prefix = String(token.dropLast(2))
            guard let day = weekdays[code] else { throw ParseError(description: "bad BYDAY value: \(token)") }
            if prefix.isEmpty { return EKRecurrenceDayOfWeek(day) }
            guard let n = Int(prefix), n != 0, (-53...53).contains(n) else {
                throw ParseError(description: "bad BYDAY value: \(token)")
            }
            return EKRecurrenceDayOfWeek(day, weekNumber: n)
        }
    }

    private static func ints(_ s: String, _ name: String, range: ClosedRange<Int>) throws -> [Int] {
        try s.split(separator: ",").map {
            guard let n = Int($0), n != 0, range.contains(n) else { throw ParseError(description: "bad \(name) value: \($0)") }
            return n
        }
    }

    private static func join(_ v: [NSNumber]) -> String {
        v.map { $0.stringValue }.joined(separator: ",")
    }

    private static func parseUntil(_ s: String, timeZone: TimeZone) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let forms: [(String, TimeZone?)] = [
            ("yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")),
            ("yyyyMMdd'T'HHmmss", timeZone),
        ]
        for (format, tz) in forms {
            fmt.dateFormat = format
            fmt.timeZone = tz
            if let d = fmt.date(from: s) { return d }
        }
        // A bare date means "through the end of that day" in the event's zone.
        let day = s.count == 8 ? "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.suffix(2))" : s
        if CalendarIntegration.isDateOnly(day), let start = CalendarIntegration.parseDay(day, timeZone: timeZone) {
            return start.addingTimeInterval(86399)
        }
        return CalendarIntegration.parseDate(s, timeZone: timeZone)
    }
}
