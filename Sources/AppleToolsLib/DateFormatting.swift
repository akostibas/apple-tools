import Foundation

/// Canonical date formatting for all apple-tools JSON output.
///
/// Every tool emits timestamps as ISO-8601 in **UTC** — e.g.
/// `2026-06-27T16:30:00Z`. UTC (not a local offset) is deliberate: apple-tools
/// is consumed both as a CLI on the user's own Mac *and* as `AppleToolsLib`
/// inside a probe, where the machine running the code is not necessarily where
/// the user is — a baked-in local offset would encode the *probe machine's*
/// timezone, which a remote consumer can't interpret. UTC pins the exact
/// instant with zero embedded location assumptions, is portable to any
/// consumer, and sorts lexically.
///
/// Route ALL output dates through here so formats can't drift per-tool. Before
/// this existed, `email inbox` emitted a localized AppleScript string and
/// `email read` an RFC-2822 header, while `email search` emitted ISO-8601
/// (issue #11); Notes emitted localized strings too. The single formatter is
/// the structural fix.
///
/// The machine's timezone is used for exactly one thing — interpreting
/// AppleScript's *local* wall-clock components into an absolute instant (valid,
/// since that data is local to the same machine). The output is always UTC.
///
/// Input parsers (accepting user- or source-supplied dates) and filename
/// timestamps are intentionally NOT routed here — they have different needs.
public enum DateFormatting {
    /// Timezone all output is rendered in. Defaults to UTC — the safe, portable
    /// choice when the consumer's location is unknown (e.g. a probe running
    /// `AppleToolsLib` on a machine that isn't where the user is).
    ///
    /// A library consumer that *does* know the user's actual location can set
    /// this once at startup to render every timestamp in that zone instead:
    ///
    /// ```swift
    /// DateFormatting.outputTimeZone = TimeZone(identifier: "America/New_York")!
    /// ```
    ///
    /// This only changes the *rendered offset* — the underlying instant is
    /// identical. It does not affect how AppleScript local wall-clock is
    /// interpreted into an instant (that always uses the machine timezone,
    /// because the source data is local to that machine).
    public static var outputTimeZone: TimeZone = TimeZone(identifier: "UTC")! {
        didSet { outputFormatter.timeZone = outputTimeZone }
    }

    /// Shared output formatter. `ISO8601DateFormatter` is safe to reuse for
    /// concurrent `string(from:)` calls in modern Foundation, and apple-tools
    /// runs single-threaded per invocation regardless.
    private static let outputFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Format a `Date` as canonical ISO-8601 output (UTC `Z`). This is the one
    /// true output formatter — every tool's date field flows through it.
    public static func iso(_ date: Date) -> String {
        outputFormatter.string(from: date)
    }

    /// Format floating wall-clock `DateComponents` as a **zone-less** local
    /// string — `"YYYY-MM-DDTHH:MM:SS"` when a time-of-day is present, or a bare
    /// `"YYYY-MM-DD"` when it isn't (a date-only reminder). Used for values that
    /// must never be timezone-converted, e.g. EventKit reminder due dates: a
    /// reminder due 9am fires at 9am wherever the user is, so the components are
    /// serialized verbatim rather than round-tripped through a `Date` (which
    /// would anchor them to the probe machine's zone and destroy the floating
    /// semantics — the #824 bug). Returns `nil` if the components lack a date.
    public static func floatingLocal(from comps: DateComponents) -> String? {
        guard let y = comps.year, let mo = comps.month, let d = comps.day else {
            return nil
        }
        if let h = comps.hour, let mi = comps.minute {
            let s = comps.second ?? 0
            return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, mo, d, h, mi, s)
        }
        return String(format: "%04d-%02d-%02d", y, mo, d)
    }

    /// Format a `Date` as a bare local calendar date `"YYYY-MM-DD"` in the
    /// machine timezone. Used for all-day calendar events, whose `startDate` is
    /// anchored at machine-local midnight: rendering date-only (not a UTC
    /// instant) avoids a conversion that shifts the date across a day boundary
    /// for probe machines east of UTC (the all-day off-by-one, folded into #824).
    public static func localDateOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Serialize a calendar event time: a bare local date for all-day events
    /// (never converted, see ``localDateOnly(_:)``), otherwise the canonical UTC
    /// instant (a timed event is a real instant, safe to convert downstream).
    public static func calendarTime(_ date: Date, allDay: Bool) -> String {
        allDay ? localDateOnly(date) : iso(date)
    }

    /// AppleScript handler that serializes a date to locale-independent integer
    /// components `"year,month,day,hours,minutes,seconds"`. Inject this near the
    /// top of a script (OUTSIDE any `tell application` block) and invoke it as
    /// `my atDateComponents(someDate)`.
    ///
    /// We extract integer components rather than emitting `date received`'s
    /// localized display string because parsing that string back is
    /// locale-fragile (the exact regression issue #11 warned against). Integer
    /// components are locale-independent.
    public static let appleScriptComponentsHandler = """
    on atDateComponents(d)
        return (year of d as string) & "," & ((month of d) as integer as string) & "," & (day of d as string) & "," & (hours of d as string) & "," & (minutes of d as string) & "," & (seconds of d as string)
    end atDateComponents
    """

    /// Convert AppleScript date components (`"y,mo,d,h,mi,s"`, local wall-clock,
    /// produced by ``appleScriptComponentsHandler``) to canonical ISO-8601.
    /// Returns the raw input unchanged if it doesn't parse, so a value is never
    /// silently dropped.
    public static func isoFromAppleScriptComponents(_ raw: String) -> String {
        let parts = raw.split(separator: ",").map {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 6,
              let year = parts[0], let month = parts[1], let day = parts[2],
              let hour = parts[3], let minute = parts[4], let second = parts[5]
        else { return raw }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = .current

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: components) else { return raw }
        return iso(date)
    }

    /// Parse an RFC-2822 `Date:` header (e.g. `Thu, 15 Jan 2026 09:30:00 -0800`)
    /// and re-emit it as canonical ISO-8601. Used by the email read fast path,
    /// which reads the raw header off the `.emlx` file. Returns the raw input
    /// unchanged if it doesn't parse.
    public static func isoFromRFC2822(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        for formatter in rfc2822Formatters {
            if let date = formatter.date(from: trimmed) { return iso(date) }
        }
        return raw
    }

    /// RFC-2822 `Date:` variants we accept: with/without the optional
    /// day-of-week, with/without seconds. POSIX locale so month/weekday names
    /// parse regardless of system locale.
    private static let rfc2822Formatters: [DateFormatter] = {
        ["EEE, d MMM yyyy HH:mm:ss Z",
         "d MMM yyyy HH:mm:ss Z",
         "EEE, d MMM yyyy HH:mm Z",
         "d MMM yyyy HH:mm Z"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()
}
