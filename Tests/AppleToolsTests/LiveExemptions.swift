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
        "imessage.fetch_attachment": "#79: needs a message with an attachment to be discovered",
        "imessage.send": "#79: to the user's own number only; the message cannot be removed afterwards",
        "music.love": "#79: restore the track's previous state",
        "music.rate": "#79: restore the track's previous state",
        "music.playlist-add": "#79",
        "music.playlist-remove": "#79",
        // Everything below changes what the user hears or sees, so it belongs in the attended group.
        "music.play": "#79 (attended)",
        "music.pause": "#79 (attended)",
        "music.playpause": "#79 (attended)",
        "music.next": "#79 (attended)",
        "music.previous": "#79 (attended)",
        "music.stop": "#79 (attended)",
        "music.seek": "#79 (attended)",
        "music.volume": "#79 (attended)",
        "music.shuffle": "#79 (attended)",
        "music.repeat": "#79 (attended)",
        "music.airplay-select": "#79 (attended)",
        "open_uri": "#79 (attended): opens a real URI in front of the user",
    ]
}
