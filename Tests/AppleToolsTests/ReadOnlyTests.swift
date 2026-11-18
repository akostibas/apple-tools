import CoreGraphics
import XCTest
@testable import AppleToolsLib

/// The read-only group: each test reads this Mac's real data and changes nothing.
/// Tests find real items once, remember them (`LiveTargets`), and on later runs
/// check they can still be found. Run with `make test`.
class ReadOnlyCase: XCTestCase {
    private(set) var outDir: String!

    override func setUpWithError() throws {
        outDir = NSTemporaryDirectory() + "apple-tools-readonly-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = outDir { try? FileManager.default.removeItem(atPath: d) }
        super.tearDown()
    }

    var host: ToolHost { .test(fileSink: LocalFileSink(outputDir: outDir)) }

    func raw(_ tool: ProbeTool, _ params: [String: Any]) throws -> Any {
        // Off the main thread with the run loop turning, as the CLI does: some frameworks
        // (PhotoKit) answer on the main queue and would deadlock a test that blocks it.
        var answer: (result: String, isError: Bool)?
        let wrapped = params.mapValues { AnyCodable($0) }
        DispatchQueue.global().async {
            let r = tool.handle(params: wrapped)
            DispatchQueue.main.async { answer = r }
        }
        let deadline = Date().addingTimeInterval(120)
        while answer == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard let (out, isError) = answer else {
            throw NSError(domain: tool.definition.name, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no answer within 120s for \(params["action"] ?? "call")"])
        }
        guard !isError else {
            throw NSError(domain: tool.definition.name, code: 1, userInfo: [NSLocalizedDescriptionKey: out])
        }
        return try JSONSerialization.jsonObject(with: Data(out.utf8))
    }

    func call(_ tool: ProbeTool, _ params: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(raw(tool, params) as? [String: Any])
    }

    func rows(_ result: [String: Any], _ key: String) -> [[String: Any]] {
        result[key] as? [[String: Any]] ?? []
    }

    func strings(_ rows: [[String: Any]], _ field: String) -> [String] {
        rows.compactMap { $0[field] as? String }.filter { !$0.isEmpty }
    }

    func count(_ result: [String: Any]) -> Int { result["count"] as? Int ?? 0 }

    /// Runs a slow listing once per test, however many remembered items are checked against it.
    func once(_ list: @escaping () throws -> [String]) -> () throws -> [String] {
        var cached: [String]?
        return {
            if let cached { return cached }
            let fresh = try list()
            cached = fresh
            return fresh
        }
    }

    func requireRunning(_ app: String) throws { try LiveTest.requireRunning(app) }
}

final class CalendarReadOnlyTests: ReadOnlyCase {
    private let tool = CalendarTool()
    private func iso(_ days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(days * 86_400))
    }

    /// Calendars and events say which calendar and account they belong to, and `read` agrees with `list`.
    private func checkIdentityFields() throws {
        let calendars = try XCTUnwrap(raw(tool, ["action": "calendars"]) as? [[String: Any]])
        for cal in calendars {
            XCTAssertNotNil(cal["account"] as? String, "a calendar has no account")
            XCTAssertNotNil(cal["writable"] as? Bool, "a calendar does not say whether it is writable")
        }
        let ids = Set(strings(calendars, "id"))
        XCTAssertEqual(ids.count, calendars.count, "calendar ids must be unique")

        let window: [String: Any] = ["action": "list", "start": iso(-7), "end": iso(7)]
        let events = rows(try call(tool, window), "events")
        for event in events {
            XCTAssertTrue(ids.contains(event["calendar_id"] as? String ?? ""), "an event's calendar_id is not a listed calendar")
            XCTAssertNotNil(event["account"] as? String, "an event has no account")
        }
        if let first = events.first, let id = first["id"] as? String, let start = first["start"] as? String {
            let read = try call(tool, ["action": "read", "id": id, "occurrence": start])
            for field in ["id", "start", "end", "calendar_id", "external_id", "status", "event_timezone"] {
                XCTAssertEqual(read[field] as? String, first[field] as? String, "read and list disagree on \(field)")
            }
        }

        // A calendar's id reaches exactly that calendar; a name two calendars share is refused.
        if let id = events.first?["calendar_id"] as? String {
            let scoped = rows(try call(tool, window.merging(["calendar": id]) { $1 }), "events")
            XCTAssertFalse(scoped.isEmpty)
            XCTAssertEqual(Set(strings(scoped, "calendar_id")), [id])
        }
        let names = strings(calendars, "name").map { $0.lowercased() }
        if let shared = names.first(where: { name in names.filter { $0 == name }.count > 1 }) {
            XCTAssertThrowsError(try raw(tool, window.merging(["calendar": shared]) { $1 })) {
                XCTAssertTrue($0.localizedDescription.contains("Pass the id"), $0.localizedDescription)
            }
        }
    }

    func testCalendarsAndEventsAreStillFound() throws {
        try LiveTest.reads("calendar", "calendars", "list", "search", "read")
        try checkIdentityFields()
        let calendars = once { self.strings(try XCTUnwrap(self.raw(self.tool, ["action": "calendars"]) as? [[String: Any]]), "name") }
        try LiveTargets.check("calendar.calendars", settle: .slowTest(tool: "calendar"),
            discover: calendars, find: { try calendars().contains($0) })
        // Search window is wider than the discovery window so remembered events stay in range.
        try LiveTargets.check("calendar.events", settle: .slowTest(tool: "calendar"),
            discover: {
                self.strings(self.rows(try self.call(self.tool, ["action": "list", "start": self.iso(-60), "end": self.iso(60)]), "events"), "title")
            },
            find: { title in
                self.count(try self.call(self.tool, ["action": "search", "query": title,
                                                     "start": self.iso(-800), "end": self.iso(400)])) > 0
            })
    }
}

final class ClipboardReadOnlyTests: ReadOnlyCase {
    func testReadAnswers() throws {
        try LiveTest.reads("clipboard", "read")
        XCTAssertNotNil(try call(ClipboardTool(host: host), ["action": "read"])["type"])
    }
}

final class ContactsReadOnlyTests: ReadOnlyCase {
    private let tool = ContactsTool()

    func testKnownContactsAreStillFoundAndReadable() throws {
        try LiveTest.reads("contacts", "search", "read")
        func hits(_ q: String) throws -> [[String: Any]] {
            rows(try call(tool, ["action": "search", "query": q, "limit": 5]), "contacts")
        }
        try LiveTargets.check("contacts.names", settle: .slowTest(tool: "contacts"),
            discover: { self.strings(try hits("a"), "name") },
            find: { name in
                guard let id = try hits(name).first?["id"] as? String else { return false }
                return try self.call(self.tool, ["action": "read", "id": id])["id"] as? String == id
            })
    }
}

final class DocumentsReadOnlyTests: ReadOnlyCase {
    private var tool: DocumentsTool { DocumentsTool(host: host, roots: [.documents]) }

    private func files() throws -> [String] {
        strings(rows(try call(tool, ["action": "list", "path": "Documents", "limit": 50]), "results")
            .filter { ($0["type"] as? String) == "file" }, "name")
    }

    func testKnownFilesAreStillListedAndFetchable() throws {
        try LiveTest.reads("documents", "list", "info", "fetch")
        var found: String?
        try LiveTargets.check("documents.files", settle: .lookIn(app: "Finder (your Documents folder)"),
            discover: files,
            find: { name in
                guard (try? self.call(self.tool, ["action": "info", "path": "Documents/\(name)"])) != nil else { return false }
                found = found ?? name
                return true
            })
        let name = try XCTUnwrap(found)
        let fetched = try call(tool, ["action": "fetch", "path": "Documents/\(name)"])
        let path = try XCTUnwrap(fetched["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "fetch reported \(path) but nothing is there")
    }

    func testSpotlightSearchStillFindsKnownFiles() throws {
        try LiveTest.reads("documents", "search")
        func total(_ q: String) throws -> Int { try call(tool, ["action": "search", "query": q, "limit": 5])["total"] as? Int ?? 0 }
        try LiveTargets.check("documents.search", settle: .lookIn(app: "Spotlight"),
            discover: { try self.files().filter { try total($0) > 0 } },
            find: { try total($0) > 0 })
    }
}

final class EmailReadOnlyTests: ReadOnlyCase {
    private var tool: EmailTool { EmailTool(host: host) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try LiveTest.reads("email", "inbox", "search", "read", "headers", "mailboxes")
    }

    func testAccountsAreStillListed() throws {
        let accounts = once { self.strings(self.rows(try self.call(self.tool, ["action": "mailboxes"]), "accounts"), "account") }
        try LiveTargets.check("email.accounts", settle: .lookIn(app: "Mail"),
            discover: accounts, find: { try accounts().contains($0) })
    }

    func testKnownMessagesAreStillReadable() throws {
        try LiveTargets.check("email.messages", settle: .lookIn(app: "Mail"),
            discover: { self.strings(self.rows(try self.call(self.tool, ["action": "inbox", "limit": 20]), "messages"), "id") },
            find: { id in
                guard (try? self.call(self.tool, ["action": "read", "id": id]))?["id"] != nil else { return false }
                return (try? self.call(self.tool, ["action": "headers", "id": id]))?["headers"] != nil
            })
    }

    func testSearchStillFindsKnownSenders() throws {
        func hits(_ address: String) -> Int {
            (try? raw(tool, ["action": "search", "from_email": address, "exclude_self": false, "limit": 1]) as? [String: Any])
                .map(count) ?? 0
        }
        func address(_ from: String) -> String? {
            from.range(of: #"[\w.+-]+@[\w.-]+"#, options: .regularExpression).map { String(from[$0]) }
        }
        try LiveTargets.check("email.senders", settle: .lookIn(app: "Mail"),
            discover: {
                let senders = self.strings(self.rows(try self.call(self.tool, ["action": "inbox", "limit": 20]), "messages"), "from")
                return Array(Set(senders.compactMap(address))).sorted().filter { hits($0) > 0 }
            },
            find: { hits($0) > 0 })
    }
}

final class IMessageReadOnlyTests: ReadOnlyCase {
    private var tool: IMessageTool { IMessageTool(host: host) }

    func testKnownConversationsAreStillReadable() throws {
        try LiveTest.reads("imessage", "list", "read", "stats")
        try LiveTargets.check("imessage.chats", settle: .slowTest(tool: "imessage"),
            discover: { self.strings(self.rows(try self.call(self.tool, ["action": "list", "limit": 10]), "conversations"), "chat_id") },
            find: { chat in self.count((try? self.call(self.tool, ["action": "read", "chat": chat, "limit": 1])) ?? [:]) > 0 })
        XCTAssertGreaterThan(count(try call(tool, ["action": "stats", "limit": 5])), 0,
                             "conversations are readable, so stats cannot be empty")
    }

    func testSearchStillFindsKnownWords() throws {
        try LiveTest.reads("imessage", "search")
        func hits(_ word: String) throws -> Int { count(try call(tool, ["action": "search", "query": word, "limit": 1])) }
        // Fixed common words, so no message text is ever written to the targets file.
        try LiveTargets.check("imessage.words", settle: .slowTest(tool: "imessage"),
            discover: { try ["the", "you", "and", "ok", "yes", "thanks"].filter { try hits($0) > 0 } },
            find: { try hits($0) > 0 })
    }
}

final class MediaReadOnlyTests: ReadOnlyCase {
    func testKnownEpisodesAndBooksAreStillListed() throws {
        try LiveTest.reads("media", "list")
        let tool = MediaTool()
        // Ten years: a remembered item must not age out of the window.
        let titles = once { self.strings(self.rows(try self.call(tool, ["action": "list", "hours": 87_600]), "items"), "title") }
        try LiveTargets.check("media.titles", settle: .lookIn(app: "Podcasts and Books"),
            discover: titles, find: { try titles().contains($0) })
    }
}

final class MusicReadOnlyTests: ReadOnlyCase {
    private let tool = MusicTool()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try LiveTest.reads("music", "now-playing", "search", "stats", "mix", "airplay-list")
        try requireRunning("Music")
    }

    func testKnownTracksAreStillFound() throws {
        try LiveTargets.check("music.tracks", settle: .lookIn(app: "Music"),
            discover: { self.strings(self.rows(try self.call(self.tool, ["action": "stats", "by": "most-played", "limit": 5]), "tracks"), "name") },
            find: { name in self.count(try self.call(self.tool, ["action": "search", "query": name, "field": "title", "limit": 1])) > 0 })
    }

    func testPlayerStateMixAndOutputsAnswer() throws {
        XCTAssertNotNil(try call(tool, ["action": "now-playing"])["state"])
        XCTAssertNotNil(try call(tool, ["action": "mix", "by": "fresh", "limit": 1])["count"])
        XCTAssertGreaterThan(count(try call(tool, ["action": "airplay-list"])), 0, "this Mac itself is always an output")
    }
}

final class NotesReadOnlyTests: ReadOnlyCase {
    private let tool = NotesTool()

    func testKnownNotesAndFoldersAreStillFound() throws {
        try LiveTest.reads("notes", "folders", "list", "search")
        let folders = once { self.strings(self.rows(try self.call(self.tool, ["action": "folders"]), "folders"), "path") }
        try LiveTargets.check("notes.folders", settle: .slowTest(tool: "notes"),
            discover: folders, find: { try folders().contains($0) })
        try LiveTargets.check("notes.titles", settle: .slowTest(tool: "notes"),
            discover: { self.strings(self.rows(try self.call(self.tool, ["action": "list", "limit": 5]), "notes"), "title") },
            find: { title in
                self.strings(self.rows(try self.call(self.tool, ["action": "search", "query": title, "limit": 50]), "notes"), "title")
                    .contains(title)
            })
    }
}

final class PhotosReadOnlyTests: ReadOnlyCase {
    private var tool: PhotosTool { PhotosTool(host: host) }
    /// Keyword search can't be discovered by listing, so try common subjects and keep what hits.
    private let subjects = ["person", "dog", "cat", "car", "tree", "food", "beach", "sky", "water", "building"]

    func testKeywordSearchStillFindsKnownSubjects() throws {
        try LiveTest.reads("photos", "search", "fetch")
        var photoID: String?
        func hits(_ word: String) throws -> Int {
            let r = try call(tool, ["action": "search", "query": word, "match": "content", "limit": 1])
            photoID = photoID ?? (rows(r, "photos").first?["id"] as? String)
            return count(r)
        }
        try LiveTargets.check("photos.subjects", settle: .lookIn(app: "Photos"),
            discover: { try self.subjects.filter { try hits($0) > 0 } },
            find: { try hits($0) > 0 })
        let path = try XCTUnwrap(try call(tool, ["action": "fetch", "id": try XCTUnwrap(photoID)])["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "fetch reported \(path) but nothing is there")
    }

    func testKnownPeopleAreStillFound() throws {
        try LiveTest.reads("photos", "search")
        try LiveTargets.check("photos.people", settle: .lookIn(app: "Photos"),
            discover: { try self.call(self.tool, ["action": "search", "match": "people"])["people"] as? [String] ?? [] },
            find: { self.count(try self.call(self.tool, ["action": "search", "person": $0, "limit": 1])) > 0 })
    }
}

final class RemindersReadOnlyTests: ReadOnlyCase {
    private let tool = RemindersTool()

    func testKnownListsAndRemindersAreStillFound() throws {
        try LiveTest.reads("reminders", "lists", "search", "read")
        let lists = once { self.strings(try XCTUnwrap(self.raw(self.tool, ["action": "lists"]) as? [[String: Any]]), "name") }
        try LiveTargets.check("reminders.lists", settle: .slowTest(tool: "reminders"),
            discover: lists, find: { try lists().contains($0) })
        func inList(_ list: String) throws -> [[String: Any]] {
            rows(try call(tool, ["action": "search", "list": list, "show_completed": true]), "reminders")
        }
        try LiveTargets.check("reminders.items", settle: .slowTest(tool: "reminders"),
            discover: { try lists().flatMap { self.strings(try inList($0), "id") } },
            find: { id in (try? self.call(self.tool, ["action": "read", "id": id]))?["id"] != nil })
    }
}

final class ScreenshotReadOnlyTests: ReadOnlyCase {
    func testCaptureProducesAnImage() throws {
        try LiveTest.reads("screenshot")
        // Asking without permission would put a system prompt in front of the user.
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(),
                          "Screen Recording is not granted to this terminal, so a capture would prompt. Grant it in System Settings and re-run.")
        _ = try raw(ScreenshotTool(host: host), [:])
        let made = try FileManager.default.contentsOfDirectory(atPath: outDir)
        XCTAssertFalse(made.isEmpty, "capture reported success but delivered no file")
    }
}
