/// Actions with no live test, each with the reason. Checked by `LiveCoverageTests`.
enum LiveExemptions {
    /// Cannot or need not be tested against the real Mac. Permanent until the reason changes.
    static let exempt: [String: String] = [
        "echo": "no OS interaction; the unit tests cover it",
        "photos.import": "an imported photo can only be removed by the user clicking a system dialog (#97), so every run would leave one behind",
    ]

    /// Not written yet. This list should only shrink.
    static let owed: [String: String] = [
        "email.reply": "#79: would mean replying to one of the user's real messages; needs a safe target",
        "email.move": "#79",
        "email.fetch_attachment": "#79: needs a message with an attachment to be discovered",
    ]
}
