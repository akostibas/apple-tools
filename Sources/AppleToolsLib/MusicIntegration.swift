import Foundation

/// Read-only Music.app integration (Apple Music / Music.app on macOS).
///
/// Everything here is zero-auth: it drives `application "Music"` via
/// AppleScript (through ``AppleScriptRunner``), needing only the one-time TCC
/// Automation grant — no Apple Developer account, MusicKit token, or the
/// interactive Music-User-Token popup. That places a hard ceiling on what it
/// can see: the local library plus whatever is *currently* playing (including a
/// streamed `URL track`). The Apple Music *catalog* (search, recommendations)
/// and the authoritative cross-device listening history live behind the Apple
/// Music API and are intentionally out of scope here — see issue #55.
///
/// ## The two worlds, in the data
///
/// A track's `class` and `cloud status` reveal which world it belongs to:
/// - `file track`  — a real file on disk (imported, purchased, or an Apple
///   Music track that's been downloaded). Fully readable.
/// - `shared track` — added from Apple Music but not downloaded. Readable, but
///   the cloud is authoritative for its play stats (local edits revert on sync).
/// - `URL track`   — a pure catalog stream that was never added to the library.
///   Visible only as the *current* track; never in `library playlist 1`.
///
/// `cloud status` (`subscription` / `purchased` / `matched` / `uploaded` /
/// nil) further distinguishes streamed-in catalog content from the user's own
/// files. Both fields are surfaced so callers can tell them apart.
public enum MusicIntegration {

    // MARK: - Text protocol

    /// Field / section delimiters — ASCII Unit Separator (0x1F) and Record
    /// Separator (0x1E). Track/artist/album names routinely contain commas,
    /// tabs, and pipes but never these control characters, so they're safe
    /// field delimiters. Mirrors the convention in ``EmailIntegration``.
    static let fieldSep = "\u{1F}"
    static let sectionSep = "\u{1E}"

    // MARK: - Models

    /// One library or now-playing track. `cloudStatus` / `playedDate` are nil
    /// when Music reports `missing value` (e.g. a stream, or a never-played
    /// track).
    public struct Track {
        public let name: String
        public let artist: String
        public let album: String
        public let duration: Double
        public let playedCount: Int
        public let rating: Int          // 0–100 (Music's scale; 20 per star)
        public let loved: Bool
        public let kind: String         // "file track" / "shared track" / "URL track"
        public let cloudStatus: String? // "subscription" / "purchased" / … / nil
        public let playedDate: String?  // ISO-8601, nil if never played
        public let databaseID: String
        public let dateAdded: String?   // ISO-8601; present for every real track
    }

    /// Player transport state plus the current track (nil when stopped / idle).
    public struct NowPlaying {
        public let state: String        // "playing" / "paused" / "stopped" / …
        public let position: Double?    // seconds into the current track
        public let track: Track?
    }

    /// Result of a curation write (love / rate). `verified` is the in-script
    /// read-back: did Music report the new value right after the write? A
    /// `false` means the edit didn't stick (a silent no-op). Note the read-back
    /// only proves Music accepted it *locally* — iCloud can still revert a
    /// cloud-track edit on a later sync, which this can't see (issue #55).
    public struct CurationResult {
        public let verified: Bool
        public let value: Int           // loved → 0/1; rate → rating 0–100
        public let track: Track?
    }

    /// Result of a playlist mutation. `verified` is the read-back (playlist
    /// exists / track count changed as intended); `already` is set for a
    /// create that found an identically-named playlist and made none.
    public struct PlaylistResult {
        public let verified: Bool
        public let already: Bool
        public let playlistID: String?
        public let track: Track?
    }

    /// One AirPlay output device. `selected` marks the currently-active
    /// output(s); `volume` is per-device (nil if Music doesn't report one).
    public struct AirPlayDevice {
        public let name: String
        public let selected: Bool
        public let kind: String
        public let volume: Int?
    }

    /// Which field(s) a `search` matches against.
    public enum SearchField: String {
        case any, title, artist, album
    }

    /// How `stats` ranks the library.
    public enum StatKind: String {
        case mostPlayed = "most-played"
        case recentlyPlayed = "recently-played"
        case mostLoved = "most-loved"
    }

    /// Derived "what should I play right now" queries (the `mix` action).
    /// Unlike `stats` (honest all-time facts), these blend recency, play
    /// count, ratings, and library age into actionable picks. All computed
    /// from the same local fields — no play-history log needed. See issue #56.
    public enum MixKind: String {
        /// Loved / 4★+ tracks not heard in `months`. The canonical
        /// "rediscover something you love" query; self-clearing (playing a
        /// track evicts it until the window lapses again).
        case neglectedFavorites = "neglected-favorites"
        /// Heavily played but not heard in `months` — like neglected-favorites
        /// but earned by plays, so it catches things you loved yet never rated.
        case rediscover
        /// plays ÷ days-since-added, highest first. The honest local stand-in
        /// for "trending": distinguishes a fresh obsession from an old warhorse.
        case velocity
        /// Added within `days` and barely played — new music you haven't given
        /// a fair hearing yet.
        case fresh
        /// Loved / 4★+ but never played — flagged gems still in the backlog.
        case unplayedGems = "unplayed-gems"
    }

    public enum MusicError: Error, CustomStringConvertible {
        case scriptFailed(String)
        case notFound(String)
        public var description: String {
            switch self {
            case .scriptFailed(let detail): return "Music automation failed: \(detail)"
            case .notFound(let detail): return detail
            }
        }
    }

    // MARK: - AppleScript building blocks

    /// A script-scope handler that extracts one track's fields as a
    /// `fieldSep`-joined line. It re-establishes its own `tell application
    /// "Music"` because Music-specific terminology (`artist`, `played count`,
    /// `cloud status`, `loved`, `database ID`) only resolves inside that
    /// context — a handler defined at script scope can't see it otherwise.
    /// Field order must stay in lockstep with ``parseTrackRecord``.
    ///
    /// Depends on `atDateComponents` (from
    /// ``DateFormatting/appleScriptComponentsHandler``) being defined in the
    /// same script, so `played date` is emitted as parseable components rather
    /// than a locale-formatted string.
    static let trackRecordHandler = """
    on trackRecord(theTrack)
        set fieldSep to (character id 31)
        tell application "Music"
            set nm to ""
            try
                set nm to (name of theTrack)
            end try
            set ar to ""
            try
                set ar to (artist of theTrack)
            end try
            set alb to ""
            try
                set alb to (album of theTrack)
            end try
            set dur to 0
            try
                set dur to (duration of theTrack)
            end try
            set playCount to 0
            try
                set playCount to (played count of theTrack)
            end try
            set theRating to 0
            try
                set theRating to (rating of theTrack)
            end try
            -- macOS 26 (Tahoe) renamed "Love" to "Favorite": `favorited` is the
            -- current property and `loved` throws a descriptor-type-mismatch.
            -- On macOS 13–15 it's the reverse. Try the new name, fall back.
            set isLoved to false
            try
                set isLoved to (favorited of theTrack)
            on error
                try
                    set isLoved to (loved of theTrack)
                end try
            end try
            set theClass to ""
            try
                set theClass to (class of theTrack as text)
            end try
            set cloudStat to ""
            try
                set cloudVal to (cloud status of theTrack)
                if cloudVal is not missing value then set cloudStat to (cloudVal as text)
            end try
            set playedStr to ""
            try
                set playedVal to (played date of theTrack)
                if playedVal is not missing value then set playedStr to my atDateComponents(playedVal)
            end try
            set dbid to ""
            try
                set dbid to (database ID of theTrack as text)
            end try
            set addedStr to ""
            try
                set addedVal to (date added of theTrack)
                if addedVal is not missing value then set addedStr to my atDateComponents(addedVal)
            end try
        end tell
        return nm & fieldSep & ar & fieldSep & alb & fieldSep & dur & fieldSep & playCount & fieldSep & theRating & fieldSep & isLoved & fieldSep & theClass & fieldSep & cloudStat & fieldSep & playedStr & fieldSep & dbid & fieldSep & addedStr
    end trackRecord
    """

    /// Common preamble for scripts that call `trackRecord`.
    private static var handlers: String {
        return DateFormatting.appleScriptComponentsHandler + "\n" + trackRecordHandler
    }

    // MARK: - Preflight

    /// Read the player state to trigger (and verify) the Automation grant.
    public static func preflight() -> (ok: Bool, message: String) {
        let script = """
        tell application "Music"
            return (player state as text)
        end tell
        """
        let (_, err) = runAppleScript(script, [:], nil)
        if let err = err {
            return (false, "music access denied: \(err)")
        }
        return (true, "music access granted")
    }

    // MARK: - Now playing

    public static func nowPlaying() throws -> NowPlaying {
        return try controlAndReport(command: "", env: [:])
    }

    /// Body of a script that reads player state + current track into the
    /// `state<FS>pos<SS>trackLine` wire format ``parseNowPlaying`` expects.
    /// `command` runs inside the Music tell before the state read, so control
    /// verbs (`play`, `pause`, `next`, `set sound volume …`) report the
    /// resulting state; `prelude` runs before the tell (e.g. reading an env
    /// var into `theQuery`). An empty command is just a read (now-playing).
    static func controlAndReport(prelude: String = "", command: String, env: [String: String]) throws -> NowPlaying {
        // Transport verbs (`pause`, `play`, `next`, `set player position …`)
        // return control before Music applies them, so an immediate `player
        // state` read races the change and reports the OLD state. A short
        // settle delay makes the read-back reflect reality. `now-playing`
        // passes no command, so it stays instant.
        let settle = command.isEmpty ? "" : "delay 0.3"
        let script = """
        \(prelude)
        \(handlers)
        set fieldSep to (character id 31)
        set sectionSep to (character id 30)
        tell application "Music"
            \(command)
            \(settle)
            set theState to (player state as text)
            set thePos to ""
            try
                set thePos to (player position as text)
            end try
            set currentRef to missing value
            try
                set currentRef to current track
            end try
        end tell
        set trackLine to ""
        if currentRef is not missing value then set trackLine to my trackRecord(currentRef)
        return theState & fieldSep & thePos & sectionSep & trackLine
        """
        let (out, err) = runAppleScript(script, env, nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return parseNowPlaying(out)
    }

    static func parseNowPlaying(_ out: String) -> NowPlaying {
        let sections = out.components(separatedBy: sectionSep)
        let header = sections.first ?? ""
        let headerParts = header.components(separatedBy: fieldSep)
        let state = headerParts.first ?? "unknown"
        let position = headerParts.count > 1 ? Double(headerParts[1]) : nil

        var track: Track? = nil
        if sections.count > 1 {
            let trackLine = sections[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trackLine.isEmpty {
                track = parseTrackRecord(trackLine)
            }
        }
        return NowPlaying(state: state, position: position, track: track)
    }

    // MARK: - Playback control (mutating)

    /// The `whose` clause for a library-track match, shared by `search` and
    /// `play --query`.
    static func matchClause(_ field: SearchField) -> String {
        switch field {
        case .title:  return "name contains theQuery"
        case .artist: return "artist contains theQuery"
        case .album:  return "album contains theQuery"
        case .any:    return "(name contains theQuery) or (artist contains theQuery) or (album contains theQuery)"
        }
    }

    /// Resume / pause / toggle / skip / stop. `command` is a Music verb.
    public static func transport(_ command: String) throws -> NowPlaying {
        return try controlAndReport(command: command, env: [:])
    }

    /// Play the first library track matching `query`. Throws if nothing matches.
    public static func playQuery(_ query: String, field: SearchField) throws -> NowPlaying {
        let prelude = #"set theQuery to do shell script "printenv APPLE_TOOLS_MUSIC_QUERY""#
        let command = """
        set matches to (every track of library playlist 1 whose \(matchClause(field)))
                if (count of matches) is 0 then error "NO_MATCH"
                play (item 1 of matches)
        """
        do {
            return try controlAndReport(prelude: prelude, command: command,
                                        env: ["APPLE_TOOLS_MUSIC_QUERY": query])
        } catch let MusicError.scriptFailed(detail) where detail.contains("NO_MATCH") {
            throw MusicError.notFound("no library track matches: \(query)")
        }
    }

    /// Play a user playlist by name (first whose name contains `name`). Throws
    /// if none matches.
    public static func playPlaylist(_ name: String) throws -> NowPlaying {
        let prelude = #"set thePlaylist to do shell script "printenv APPLE_TOOLS_MUSIC_PLAYLIST""#
        let command = """
        set matches to (every user playlist whose name contains thePlaylist)
                if (count of matches) is 0 then error "NO_MATCH"
                play (item 1 of matches)
        """
        do {
            return try controlAndReport(prelude: prelude, command: command,
                                        env: ["APPLE_TOOLS_MUSIC_PLAYLIST": name])
        } catch let MusicError.scriptFailed(detail) where detail.contains("NO_MATCH") {
            throw MusicError.notFound("no playlist matches: \(name)")
        }
    }

    /// Set the app volume (0–100) and return the value Music reports back.
    public static func setVolume(_ level: Int) throws -> Int {
        let clamped = min(100, max(0, level))
        let (out, err) = runAppleScript("""
        tell application "Music"
            set sound volume to \(clamped)
            return (sound volume as text)
        end tell
        """, [:], nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? clamped
    }

    /// Toggle shuffle; returns the resulting state.
    public static func setShuffle(_ on: Bool) throws -> Bool {
        let (out, err) = runAppleScript("""
        tell application "Music"
            set shuffle enabled to \(on ? "true" : "false")
            delay 0.2
            return (shuffle enabled as text)
        end tell
        """, [:], nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Set repeat mode (`off` / `one` / `all`); returns the resulting mode.
    public static func setRepeat(_ mode: String) throws -> String {
        let (out, err) = runAppleScript("""
        tell application "Music"
            set song repeat to \(mode)
            delay 0.2
            return (song repeat as text)
        end tell
        """, [:], nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Seek to `seconds` within the current track; returns the new now-playing.
    public static func seek(toSeconds seconds: Int) throws -> NowPlaying {
        return try controlAndReport(command: "set player position to \(max(0, seconds))", env: [:])
    }

    // MARK: - Curation (Group C — mutating, with read-back verify)
    //
    // Every mutating script below carries `applescript-runner: no-verifier`
    // (ADR-032 opt-out). The async post-verify hook exists to disambiguate a
    // SIGKILL-during-pre-commit by polling an external store (chat.db, Mail
    // index). Music.app has no such store — the authoritative record IS
    // Music's own state — so these scripts verify *in-script*: they issue the
    // write, then read the property / count back before returning and report
    // `verified`. PHASE markers are still emitted so a deadline-kill classifies
    // as outcome_unknown. Caveat: the read-back proves Music accepted the edit
    // locally; iCloud can still revert a cloud-track edit on a later sync (#55).

    /// AppleScript that binds `theTrack` to the mutation target: the first
    /// library match for `query`, or the current track when `query` is nil.
    /// `prelude` runs before any tell (reads the env var); `command` runs
    /// inside the Music tell and may `error "NO_MATCH"` / `"NO_CURRENT"`.
    private struct TrackTarget {
        let prelude: String
        let command: String
        let env: [String: String]
    }

    private static func trackTarget(query: String?, field: SearchField) -> TrackTarget {
        if let query = query, !query.isEmpty {
            return TrackTarget(
                prelude: #"set theQuery to do shell script "printenv APPLE_TOOLS_MUSIC_QUERY""#,
                command: """
                set matches to (every track of library playlist 1 whose \(matchClause(field)))
                        if (count of matches) is 0 then error "NO_MATCH"
                        set theTrack to item 1 of matches
                """,
                env: ["APPLE_TOOLS_MUSIC_QUERY": query]
            )
        }
        // No query → operate on whatever's cued. `current track` throws when
        // stopped, so probe it defensively and surface a clean NO_CURRENT.
        return TrackTarget(
            prelude: "",
            command: """
            set theTrack to missing value
                    try
                        set theTrack to current track
                    end try
                    if theTrack is missing value then error "NO_CURRENT"
            """,
            env: [:]
        )
    }

    /// Map a raw script failure carrying one of our sentinel markers to a
    /// friendly ``MusicError/notFound``; rethrow anything else.
    private static func mapTargetError(_ error: Error, query: String?) throws -> Never {
        guard case let MusicError.scriptFailed(detail) = error else { throw error }
        if detail.contains("NO_MATCH") {
            throw MusicError.notFound("no library track matches: \(query ?? "")")
        }
        if detail.contains("NO_CURRENT") {
            throw MusicError.notFound("nothing is playing — pass --query to target a library track")
        }
        throw error
    }

    /// Favorite / unfavorite the target track, then read the flag back.
    /// macOS 26 renamed `loved` → `favorited`; try the new name, fall back.
    public static func setLoved(_ on: Bool, query: String?, field: SearchField) throws -> CurationResult {
        let target = trackTarget(query: query, field: field)
        let lit = on ? "true" : "false"
        let script = """
        \(target.prelude)
        \(handlers)
        set fieldSep to (character id 31)
        set sectionSep to (character id 30)
        log "PHASE: prepare"
        tell application "Music"
            \(target.command)
            log "PHASE: pre-commit"
            -- The write can be rejected (a URL-track stream, or an iCloud
            -- permission error -54): swallow it and let the read-back below
            -- report verified=false, rather than hard-erroring. macOS 26
            -- renamed `loved` → `favorited`; try the new name, fall back.
            try
                set favorited of theTrack to \(lit)
            on error
                try
                    set loved of theTrack to \(lit)
                end try
            end try
            log "PHASE: committed"
            delay 0.2
            set nowVal to false
            try
                set nowVal to (favorited of theTrack)
            on error
                try
                    set nowVal to (loved of theTrack)
                end try
            end try
            set trackLine to my trackRecord(theTrack)
        end tell
        return (nowVal as text) & sectionSep & trackLine
        """
        let out: String
        do {
            out = try runMutation(script, env: target.env)
        } catch {
            try mapTargetError(error, query: query)
        }
        let (head, track) = splitHeaderTrack(out)
        let readBack = (head == "true")
        return CurationResult(verified: readBack == on, value: readBack ? 1 : 0, track: track)
    }

    /// Set the target track's star rating (0–5 → Music's 0–100), then read it
    /// back. `verified` is whether the stored rating matches what we set.
    public static func setRating(stars: Int, query: String?, field: SearchField) throws -> CurationResult {
        let value = max(0, min(5, stars)) * 20
        let target = trackTarget(query: query, field: field)
        let script = """
        \(target.prelude)
        \(handlers)
        set fieldSep to (character id 31)
        set sectionSep to (character id 30)
        log "PHASE: prepare"
        tell application "Music"
            \(target.command)
            log "PHASE: pre-commit"
            -- A URL-track stream or an iCloud permission error (-54) rejects
            -- the write; swallow it so the read-back reports verified=false
            -- instead of hard-erroring (matches `love`'s behavior).
            try
                set rating of theTrack to \(value)
            end try
            log "PHASE: committed"
            delay 0.2
            set nowVal to 0
            try
                set nowVal to (rating of theTrack)
            end try
            set trackLine to my trackRecord(theTrack)
        end tell
        return (nowVal as text) & sectionSep & trackLine
        """
        let out: String
        do {
            out = try runMutation(script, env: target.env)
        } catch {
            try mapTargetError(error, query: query)
        }
        let (head, track) = splitHeaderTrack(out)
        let readBack = Int(head) ?? -1
        return CurationResult(verified: readBack == value, value: readBack, track: track)
    }

    // MARK: - Playlists

    /// Create a user playlist. Idempotent: if one with the exact name already
    /// exists we make none and report `already`, so repeated calls can't spawn
    /// duplicate playlists.
    public static func createPlaylist(_ name: String) throws -> PlaylistResult {
        // applescript-runner: no-verifier — verified in-script via read-back
        // (playlist existence count); Music has no external store to poll.
        let script = """
        set theName to do shell script "printenv APPLE_TOOLS_MUSIC_PLAYLIST"
        set fieldSep to (character id 31)
        tell application "Music"
            set existing to (every user playlist whose name is theName)
            if (count of existing) > 0 then
                set plId to ""
                try
                    set plId to (persistent ID of item 1 of existing as text)
                end try
                return "existed" & fieldSep & plId
            end if
            log "PHASE: pre-commit"
            set newPl to make new user playlist with properties {name:theName}
            log "PHASE: committed"
            delay 0.2
            set check to (count of (every user playlist whose name is theName))
            set plId to ""
            try
                set plId to (persistent ID of newPl as text)
            end try
            return (check as text) & fieldSep & plId
        end tell
        """
        let out = try runMutation(script, env: ["APPLE_TOOLS_MUSIC_PLAYLIST": name])
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: fieldSep)
        let head = f.first ?? ""
        let plId = (f.count > 1 && !f[1].isEmpty) ? f[1] : nil
        if head == "existed" {
            return PlaylistResult(verified: true, already: true, playlistID: plId, track: nil)
        }
        let count = Int(head) ?? 0
        return PlaylistResult(verified: count >= 1, already: false, playlistID: plId, track: nil)
    }

    /// Add the first library track matching `query` to the named user playlist
    /// (`duplicate` — the dictionary's track→playlist verb), then verify the
    /// track's count in the playlist went up. Only library tracks can be added;
    /// a pure catalog item must be added to the library first (issue #55).
    public static func playlistAdd(name: String, query: String, field: SearchField) throws -> PlaylistResult {
        // applescript-runner: no-verifier — verified in-script via read-back
        // (playlist track-count delta); Music has no external store to poll.
        let script = """
        set thePlaylist to do shell script "printenv APPLE_TOOLS_MUSIC_PLAYLIST"
        set theQuery to do shell script "printenv APPLE_TOOLS_MUSIC_QUERY"
        \(handlers)
        set fieldSep to (character id 31)
        set sectionSep to (character id 30)
        tell application "Music"
            set pls to (every user playlist whose name is thePlaylist)
            if (count of pls) is 0 then error "NO_PLAYLIST"
            set thePl to item 1 of pls
            set matches to (every track of library playlist 1 whose \(matchClause(field)))
            if (count of matches) is 0 then error "NO_MATCH"
            set theTrack to item 1 of matches
            set dbid to (database ID of theTrack)
            set beforeCount to (count of (every track of thePl whose database ID is dbid))
            log "PHASE: pre-commit"
            duplicate theTrack to thePl
            log "PHASE: committed"
            delay 0.3
            set afterCount to (count of (every track of thePl whose database ID is dbid))
            set trackLine to my trackRecord(theTrack)
        end tell
        return (afterCount as text) & fieldSep & (beforeCount as text) & sectionSep & trackLine
        """
        return try runPlaylistTrackMutation(
            script,
            env: ["APPLE_TOOLS_MUSIC_PLAYLIST": name, "APPLE_TOOLS_MUSIC_QUERY": query],
            name: name, query: query,
            verified: { after, before in after > before }
        )
    }

    /// Remove the first track matching `query` from the named user playlist,
    /// then verify the playlist's matching-track count dropped.
    public static func playlistRemove(name: String, query: String, field: SearchField) throws -> PlaylistResult {
        // applescript-runner: no-verifier — verified in-script via read-back
        // (playlist track-count delta); Music has no external store to poll.
        let script = """
        set thePlaylist to do shell script "printenv APPLE_TOOLS_MUSIC_PLAYLIST"
        set theQuery to do shell script "printenv APPLE_TOOLS_MUSIC_QUERY"
        \(handlers)
        set fieldSep to (character id 31)
        set sectionSep to (character id 30)
        tell application "Music"
            set pls to (every user playlist whose name is thePlaylist)
            if (count of pls) is 0 then error "NO_PLAYLIST"
            set thePl to item 1 of pls
            set matches to (every track of thePl whose \(matchClause(field)))
            if (count of matches) is 0 then error "NO_MATCH"
            set beforeCount to (count of matches)
            set theTrack to item 1 of matches
            set trackLine to my trackRecord(theTrack)
            log "PHASE: pre-commit"
            delete theTrack
            log "PHASE: committed"
            delay 0.3
            set afterCount to (count of (every track of thePl whose \(matchClause(field))))
        end tell
        return (afterCount as text) & fieldSep & (beforeCount as text) & sectionSep & trackLine
        """
        return try runPlaylistTrackMutation(
            script,
            env: ["APPLE_TOOLS_MUSIC_PLAYLIST": name, "APPLE_TOOLS_MUSIC_QUERY": query],
            name: name, query: query,
            verified: { after, before in after < before }
        )
    }

    /// Shared runner for playlist add/remove: run, map the NO_PLAYLIST/NO_MATCH
    /// sentinels, and decide `verified` from the before/after counts the script
    /// returns in its header (`after<FS>before<SS>trackLine`).
    private static func runPlaylistTrackMutation(
        _ script: String, env: [String: String], name: String, query: String,
        verified: (_ after: Int, _ before: Int) -> Bool
    ) throws -> PlaylistResult {
        let out: String
        do {
            out = try runMutation(script, env: env)
        } catch let MusicError.scriptFailed(detail) where detail.contains("NO_PLAYLIST") {
            throw MusicError.notFound("no playlist named: \(name)")
        } catch let MusicError.scriptFailed(detail) where detail.contains("NO_MATCH") {
            throw MusicError.notFound("no track matches: \(query)")
        }
        let (head, track) = splitHeaderTrack(out)
        let parts = head.components(separatedBy: fieldSep)
        let after = Int(parts.first ?? "") ?? 0
        let before = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return PlaylistResult(verified: verified(after, before), already: false,
                              playlistID: nil, track: track)
    }

    // MARK: - AirPlay

    /// List AirPlay output devices Music can see, marking the active one(s).
    public static func airplayList() throws -> [AirPlayDevice] {
        let script = """
        set fieldSep to (character id 31)
        tell application "Music"
            set devs to (every AirPlay device)
            set rows to {}
            repeat with d in devs
                set nm to (name of d)
                set sel to (selected of d as text)
                set knd to ""
                try
                    set knd to (kind of d as text)
                end try
                set vol to ""
                try
                    set vol to (sound volume of d as text)
                end try
                set end of rows to nm & fieldSep & sel & fieldSep & knd & fieldSep & vol
            end repeat
            set AppleScript's text item delimiters to (character id 10)
            return rows as text
        end tell
        """
        let (out, err) = runAppleScript(script, [:], nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return out.components(separatedBy: "\n").compactMap { line in
            let f = line.components(separatedBy: fieldSep)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return AirPlayDevice(
                name: f[0],
                selected: f[1] == "true",
                kind: f.count > 2 ? f[2] : "",
                volume: (f.count > 3 && !f[3].isEmpty) ? Int(f[3]) : nil
            )
        }
    }

    /// Route Music's output to the AirPlay device named exactly `device`, then
    /// read `selected` back. Exact-name match (not substring) so an ambiguous
    /// name can't silently switch the wrong output.
    public static func airplaySelect(_ device: String) throws -> (verified: Bool, name: String) {
        // applescript-runner: no-verifier — verified in-script via read-back
        // (device `selected` flag); Music has no external store to poll.
        let script = """
        set theDevice to do shell script "printenv APPLE_TOOLS_MUSIC_DEVICE"
        set fieldSep to (character id 31)
        tell application "Music"
            set devs to (every AirPlay device whose name is theDevice)
            if (count of devs) is 0 then error "NO_DEVICE"
            set theDev to item 1 of devs
            log "PHASE: pre-commit"
            set current AirPlay devices to {theDev}
            log "PHASE: committed"
            delay 0.3
            set sel to (selected of theDev as text)
            set nm to (name of theDev)
        end tell
        return sel & fieldSep & nm
        """
        let out: String
        do {
            out = try runMutation(script, env: ["APPLE_TOOLS_MUSIC_DEVICE": device])
        } catch let MusicError.scriptFailed(detail) where detail.contains("NO_DEVICE") {
            throw MusicError.notFound("no AirPlay device named: \(device)")
        }
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: fieldSep)
        return (verified: f.first == "true", name: f.count > 1 ? f[1] : device)
    }

    // MARK: - Curation helpers

    /// Run a mutating script and surface any failure as ``MusicError``.
    private static func runMutation(_ script: String, env: [String: String]) throws -> String {
        let (out, err) = runAppleScript(script, env, nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return out
    }

    /// Split a `header<SS>trackLine` payload into the header string and the
    /// parsed ``Track`` (nil when no track line was emitted).
    private static func splitHeaderTrack(_ out: String) -> (header: String, track: Track?) {
        let sections = out.components(separatedBy: sectionSep)
        let header = (sections.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var track: Track? = nil
        if sections.count > 1 {
            let line = sections[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { track = parseTrackRecord(line) }
        }
        return (header, track)
    }

    // MARK: - Search

    /// Search the local library. Matches are bounded to `limit` inside
    /// AppleScript so a broad query can't drag the whole library over the wire.
    public static func search(query: String, field: SearchField, limit: Int) throws -> [Track] {
        let script = """
        set theQuery to do shell script "printenv APPLE_TOOLS_MUSIC_QUERY"
        \(handlers)
        tell application "Music"
            set matches to (every track of library playlist 1 whose \(matchClause(field)))
        end tell
        set matchCount to (count of matches)
        if matchCount > \(limit) then set matchCount to \(limit)
        set rows to {}
        repeat with i from 1 to matchCount
            set end of rows to my trackRecord(item i of matches)
        end repeat
        set AppleScript's text item delimiters to (character id 10)
        return rows as text
        """
        let (out, err) = runAppleScript(script, ["APPLE_TOOLS_MUSIC_QUERY": query], nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return parseTrackLines(out)
    }

    // MARK: - Stats

    /// Rank the whole library by a local play statistic. Uses vectorized bulk
    /// property reads (`X of every track` — one Apple event per property, not
    /// per track), then sorts/trims in Swift. Play stats are **local**: streamed
    /// plays don't reliably increment `played count`, and iCloud sync is
    /// authoritative for cloud tracks (issue #55) — so this is "what this Mac
    /// recorded", not a true cross-device listening history.
    public static func stats(by kind: StatKind, limit: Int) throws -> [Track] {
        let tracks = try allLibraryTracks()
        let ranked: [Track]
        switch kind {
        case .mostPlayed:
            ranked = tracks
                .filter { $0.playedCount > 0 }
                .sorted { $0.playedCount > $1.playedCount }
        case .recentlyPlayed:
            ranked = tracks
                .filter { $0.playedDate != nil }
                .sorted { ($0.playedDate ?? "") > ($1.playedDate ?? "") }
        case .mostLoved:
            ranked = tracks
                .filter { $0.loved }
                .sorted { $0.playedCount > $1.playedCount }
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Mix (derived "what to play now" queries)

    /// Play count below which a track counts as "high rated" for the star-based
    /// filters. Music stores ratings 0–100 at 20 per star, so 80 = 4★.
    static let fourStars = 80
    /// A track needs at least this many lifetime plays to qualify for
    /// `rediscover` — enough that it was genuinely a favorite once, not a
    /// one-off. Deliberately a plain constant (documented, not a flag) to keep
    /// the surface small; revisit if libraries vary too much.
    static let rediscoverMinPlays = 8

    /// Run a derived pick query. `months` is the staleness window for the
    /// "not heard lately" filters; `days` is the recency window for `fresh`.
    /// `now` is injectable so tests are deterministic.
    public static func mix(by kind: MixKind, limit: Int, months: Int, days: Int, now: Date = Date()) throws -> [Track] {
        return rankMix(try allLibraryTracks(), by: kind, limit: limit, months: months, days: days, now: now)
    }

    /// Pure ranking core of ``mix`` — no AppleScript, so it's directly
    /// unit-testable with hand-built tracks and an injected `now`.
    static func rankMix(_ tracks: [Track], by kind: MixKind, limit: Int, months: Int, days: Int, now: Date) -> [Track] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]

        // Days between `now` and an ISO timestamp; nil if unparseable/absent.
        func daysSince(_ iso: String?) -> Double? {
            guard let iso = iso, let date = parser.date(from: iso) else { return nil }
            return now.timeIntervalSince(date) / 86_400
        }
        let staleWindow = Double(months) * 30
        // A track is "stale" if last played longer ago than the window — or was
        // never played at all (nil playedDate ⇒ never heard ⇒ maximally stale).
        func isStale(_ track: Track) -> Bool {
            guard let ago = daysSince(track.playedDate) else { return true }
            return ago >= staleWindow
        }
        func isFavorite(_ track: Track) -> Bool { track.loved || track.rating >= fourStars }

        let ranked: [Track]
        switch kind {
        case .neglectedFavorites:
            // Favorites gone cold. Never-played favorites (empty playedDate)
            // sort first, then oldest-played — the most neglected on top.
            ranked = tracks
                .filter { isFavorite($0) && isStale($0) }
                .sorted { ($0.playedDate ?? "") < ($1.playedDate ?? "") }
        case .rediscover:
            // Earned by plays rather than stars: heavily played, now cold.
            ranked = tracks
                .filter { $0.playedCount >= rediscoverMinPlays && isStale($0) && ($0.playedDate != nil) }
                .sorted { $0.playedCount > $1.playedCount }
        case .velocity:
            // plays ÷ days-since-added, highest first. Needs date_added and at
            // least one play; max(age,1) guards a same-day add.
            func velocity(_ track: Track) -> Double {
                Double(track.playedCount) / max(daysSince(track.dateAdded) ?? 1, 1)
            }
            ranked = tracks
                .filter { $0.playedCount > 0 && daysSince($0.dateAdded) != nil }
                .sorted { velocity($0) > velocity($1) }
        case .fresh:
            // Added within `days`, still barely played. Newest add first.
            let freshWindow = Double(days)
            ranked = tracks
                .filter { track in
                    guard let addedAgo = daysSince(track.dateAdded) else { return false }
                    return addedAgo <= freshWindow && track.playedCount < 3
                }
                .sorted { ($0.dateAdded ?? "") > ($1.dateAdded ?? "") }
        case .unplayedGems:
            // Flagged favorites never played. Highest rated / newest first.
            ranked = tracks
                .filter { isFavorite($0) && $0.playedCount == 0 }
                .sorted {
                    $0.rating != $1.rating ? $0.rating > $1.rating
                        : ($0.dateAdded ?? "") > ($1.dateAdded ?? "")
                }
        }
        return Array(ranked.prefix(limit))
    }

    /// Every track in `library playlist 1`, read via vectorized bulk property
    /// fetches. Parallel lists are zipped in AppleScript and emitted one
    /// `fieldSep`-joined line per track — same shape `trackRecord` produces, so
    /// ``parseTrackRecord`` handles both.
    static func allLibraryTracks() throws -> [Track] {
        let script = """
        \(DateFormatting.appleScriptComponentsHandler)
        set fieldSep to (character id 31)
        tell application "Music"
            set lib to library playlist 1
            set namesList to name of every track of lib
            set artistsList to artist of every track of lib
            set albumsList to album of every track of lib
            set durationsList to duration of every track of lib
            set playCountsList to played count of every track of lib
            set ratingsList to rating of every track of lib
            set classesList to class of every track of lib
            set cloudList to cloud status of every track of lib
            set playedList to played date of every track of lib
            set idsList to database ID of every track of lib
            set addedList to date added of every track of lib
            -- `loved` can't be bulk-fetched on macOS 26 (renamed to
            -- `favorited`); older macOS only knows `loved`. Try new, fall back.
            try
                set lovedList to favorited of every track of lib
            on error
                set lovedList to loved of every track of lib
            end try
        end tell
        set trackTotal to count of namesList
        set rows to {}
        repeat with i from 1 to trackTotal
            set cloudItem to item i of cloudList
            set cloudStr to ""
            if cloudItem is not missing value then set cloudStr to (cloudItem as text)
            set playedItem to item i of playedList
            set playedStr to ""
            if playedItem is not missing value then set playedStr to my atDateComponents(playedItem)
            set addedItem to item i of addedList
            set addedStr to ""
            if addedItem is not missing value then set addedStr to my atDateComponents(addedItem)
            set end of rows to (item i of namesList) & fieldSep & (item i of artistsList) & fieldSep & (item i of albumsList) & fieldSep & (item i of durationsList) & fieldSep & (item i of playCountsList) & fieldSep & (item i of ratingsList) & fieldSep & (item i of lovedList) & fieldSep & ((item i of classesList) as text) & fieldSep & cloudStr & fieldSep & playedStr & fieldSep & (item i of idsList) & fieldSep & addedStr
        end repeat
        set AppleScript's text item delimiters to (character id 10)
        return rows as text
        """
        let (out, err) = runAppleScript(script, [:], nil)
        if let err = err { throw MusicError.scriptFailed(err) }
        return parseTrackLines(out)
    }

    // MARK: - Parsing

    static func parseTrackLines(_ out: String) -> [Track] {
        return out.components(separatedBy: "\n").compactMap { line in
            line.isEmpty ? nil : parseTrackRecord(line)
        }
    }

    /// Parse one `fieldSep`-joined track line. Field order is fixed by
    /// ``trackRecordHandler`` and the vectorized stats emitter — keep all three
    /// in lockstep.
    static func parseTrackRecord(_ line: String) -> Track? {
        let f = line.components(separatedBy: fieldSep)
        guard f.count >= 11 else { return nil }
        let cloud = f[8].isEmpty ? nil : f[8]
        let played = f[9].isEmpty ? nil : DateFormatting.isoFromAppleScriptComponents(f[9])
        // date_added (field 11) is appended; tolerate its absence so older
        // callers / truncated lines still parse.
        let added: String? = (f.count > 11 && !f[11].isEmpty)
            ? DateFormatting.isoFromAppleScriptComponents(f[11]) : nil
        return Track(
            name: f[0],
            artist: f[1],
            album: f[2],
            duration: Double(f[3]) ?? 0,
            playedCount: Int(f[4]) ?? 0,
            rating: Int(f[5]) ?? 0,
            loved: f[6] == "true",
            kind: f[7],
            cloudStatus: cloud,
            playedDate: played,
            databaseID: f[10],
            dateAdded: added
        )
    }

    // MARK: - AppleScript runner (test seam)

    /// Swappable runner, mirroring the other AppleScript integrations. Reads
    /// pass a nil verify hook (nothing to reconcile). Default routes through
    /// ``AppleScriptRunner/runLegacy`` with `tool: "music"`.
    public static var runAppleScript: (_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) = defaultRunAppleScript

    public static func defaultRunAppleScript(_ source: String, _ environment: [String: String], _ verifyHook: (() -> AppleScriptRunner.VerifyResult)?) -> (String, String?) {
        return AppleScriptRunner.runLegacy(source: source, tool: "music", environment: environment, onOutcomeUnknown: verifyHook)
    }
}
