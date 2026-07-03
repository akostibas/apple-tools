import XCTest
@testable import AppleToolsLib

final class EmailToolTests: XCTestCase {
    var tool: EmailTool!

    override func setUp() {
        super.setUp()
        tool = EmailTool(host: .test())
    }

    // MARK: - Tool definition

    func testToolDefinitionName() {
        XCTAssertEqual(tool.definition.name, "email")
    }

    func testToolDefinitionHasRequiredAction() {
        XCTAssertEqual(tool.definition.parameters?.required, ["action"])
    }

    func testToolDefinitionAdvertisesSearchAction() {
        XCTAssertTrue(tool.definition.description.contains("'search'"),
                      "description should list the search action so agents discover it")
    }

    func testToolDefinitionHasSearchProperties() {
        let props = tool.definition.parameters?.properties
        XCTAssertNotNil(props?["query"])
        XCTAssertNotNil(props?["from"])
        XCTAssertNotNil(props?["to"])
        XCTAssertNotNil(props?["after"])
        XCTAssertNotNil(props?["before"])
        XCTAssertNotNil(props?["limit"])
        XCTAssertNotNil(props?["exclude_self"])
    }

    // MARK: - Parameter validation

    func testNilParams() {
        let (result, isError) = tool.handle(params: nil)
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: action"))
    }

    func testUnknownAction() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("bogus")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("unknown action"))
        XCTAssertTrue(result.contains("search"), "unknown-action error should list search as valid")
    }

    func testSearchRequiresAtLeastOneCriterion() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("search")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("at least one"),
                      "empty search should explain the requirement, got: \(result)")
    }

    func testSearchRejectsUnparseableAfter() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "after": AnyCodable("not-a-date"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("after"))
        XCTAssertTrue(result.contains("ISO 8601"))
    }

    func testFetchAttachmentRequiresID() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("fetch_attachment")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    func testReadRequiresID() {
        let (result, isError) = tool.handle(params: ["action": AnyCodable("read")])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("missing required parameter: id"))
    }

    // MARK: - Draft attachments

    func testDraftAdvertisesAttachmentsProperty() {
        let prop = tool.definition.parameters?.properties?["attachments"]
        XCTAssertNotNil(prop, "draft should advertise an 'attachments' parameter")
        XCTAssertEqual(prop?.type_, "array")
        XCTAssertEqual(prop?.items?.type_, "string")
    }

    func testDraftRejectsMissingAttachmentPath() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("draft"),
            "to": AnyCodable("alice@example.com"),
            "attachments": AnyCodable(["/tmp/apple-tools-test-does-not-exist-\(UUID().uuidString).bin"]),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("not found"), "missing-path error should mention 'not found': \(result)")
    }

    func testDraftRejectsDirectoryAttachment() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("draft"),
            "to": AnyCodable("alice@example.com"),
            "attachments": AnyCodable([NSTemporaryDirectory()]),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("directory"), "directory error should say so: \(result)")
    }

    func testDraftRejectsTooManyAttachments() {
        // 11 path strings — count check fires before existence check, so the
        // paths don't need to exist.
        let paths = (1...11).map { "/tmp/apple-tools-cap-\($0).bin" }
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("draft"),
            "to": AnyCodable("alice@example.com"),
            "attachments": AnyCodable(paths),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("too many"), "count cap error should mention 'too many': \(result)")
    }

    func testDraftRejectsOversizedAttachment() throws {
        // Create a 36MB sparse-ish file and verify the size cap rejects it.
        let tmp = NSTemporaryDirectory() + "apple-tools-oversized-\(UUID().uuidString).bin"
        let fh = FileManager.default.createFile(atPath: tmp, contents: nil)
        XCTAssertTrue(fh, "could not create temp file at \(tmp)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let handle = FileHandle(forWritingAtPath: tmp)!
        try handle.seek(toOffset: 36 * 1_048_576)
        handle.write(Data([0]))
        try handle.close()

        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("draft"),
            "to": AnyCodable("alice@example.com"),
            "attachments": AnyCodable([tmp]),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("exceeds"), "size cap error should mention 'exceeds': \(result)")
    }

    func testDraftExpandsTildeInAttachmentPath() throws {
        // Validation should expand ~ before existence-checking. Point at a
        // path that does NOT exist via its tilde form; the not-found error
        // should reference the expanded $HOME path, proving expansion ran.
        // Using a missing path keeps the call from reaching AppleScript /
        // Mail.app (which would create a real draft on the developer's Mac).
        let home = NSHomeDirectory()
        let name = "apple-tools-tilde-missing-\(UUID().uuidString).txt"
        let tildePath = "~/" + name

        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("draft"),
            "to": AnyCodable("alice@example.com"),
            "attachments": AnyCodable([tildePath]),
        ])
        XCTAssertTrue(isError, "missing file should fail validation: \(result)")
        XCTAssertTrue(result.contains("not found"), "error should be not-found: \(result)")
        XCTAssertTrue(result.contains(home + "/" + name),
                      "not-found message should reference the expanded path: \(result)")
        XCTAssertFalse(result.contains("~/"),
                       "expanded path should no longer contain '~/': \(result)")
    }

    func testSearchRejectsUnparseableBefore() {
        let (result, isError) = tool.handle(params: [
            "action": AnyCodable("search"),
            "before": AnyCodable("yesterday"),
        ])
        XCTAssertTrue(isError)
        XCTAssertTrue(result.contains("before"))
    }

    // MARK: - EmailSearch direct API

    func testSearchCriteriaRejectsAllEmpty() {
        // Calling EmailSearch.run with nothing should fail cleanly with noCriteria,
        // independent of whether an Envelope Index exists on the test machine.
        let criteria = EmailSearch.Criteria()
        XCTAssertThrowsError(try EmailSearch.run(criteria, dbPath: "/nonexistent/does-not-matter")) { err in
            guard let e = err as? EmailSearch.SearchError else {
                return XCTFail("expected SearchError, got \(err)")
            }
            if case .noCriteria = e { return }
            XCTFail("expected noCriteria, got \(e)")
        }
    }

    func testSearchReportsMissingDatabase() {
        var criteria = EmailSearch.Criteria()
        criteria.query = "anything"
        XCTAssertThrowsError(try EmailSearch.run(criteria, dbPath: "/nonexistent/Envelope Index")) { err in
            guard let e = err as? EmailSearch.SearchError else {
                return XCTFail("expected SearchError, got \(err)")
            }
            if case .dbMissing = e { return }
            XCTFail("expected dbMissing, got \(e)")
        }
    }

    // MARK: - Query tokenization

    func testTokenizeSingleWord() {
        XCTAssertEqual(EmailSearch.tokenize("Aegean"), ["aegean"])
    }

    func testTokenizeMultipleWords() {
        XCTAssertEqual(EmailSearch.tokenize("Greece itinerary"), ["greece", "itinerary"])
    }

    func testTokenizeStripsStopwords() {
        XCTAssertEqual(EmailSearch.tokenize("the Greece itinerary email"), ["greece", "itinerary"])
    }

    func testTokenizeAllStopwordsYieldsEmpty() {
        XCTAssertEqual(EmailSearch.tokenize("the email message"), [])
    }

    func testTokenizeEmptyString() {
        XCTAssertEqual(EmailSearch.tokenize(""), [])
    }

    func testTokenizeWhitespaceOnly() {
        XCTAssertEqual(EmailSearch.tokenize("   \t  \n "), [])
    }

    func testTokenizeCollapsesRunsOfWhitespace() {
        XCTAssertEqual(EmailSearch.tokenize("  Greece   \t itinerary  "), ["greece", "itinerary"])
    }

    func testQueryThatTokenizesToEmptyTreatedAsNoCriteria() {
        // "the email" → all stopwords, no other criteria → noCriteria.
        var criteria = EmailSearch.Criteria()
        criteria.query = "the email"
        XCTAssertThrowsError(try EmailSearch.run(criteria, dbPath: "/nonexistent/does-not-matter")) { err in
            guard let e = err as? EmailSearch.SearchError else {
                return XCTFail("expected SearchError, got \(err)")
            }
            if case .noCriteria = e { return }
            XCTFail("expected noCriteria, got \(e)")
        }
    }

    // MARK: - Sender prefix matching

    func testSenderMatchesNamePrefix() {
        // "sam" must match display name "Samira Quinn" — a full word
        // boundary previously rejected this, returning 0 results for
        // `from: "sam"` on mail from Samira.
        let wb = WordBoundary()
        XCTAssertTrue(wb.senderMatches("sam", address: "samiraquinn@example.com", name: "Samira Quinn"))
    }

    func testSenderLocalPartIsWholeWordNotPrefix() {
        // Local-part keeps full-word matching: a prefix with no display name
        // does NOT match. This is the deliberate cost of keeping role
        // addresses (marketing@…) out of name searches.
        let wb = WordBoundary()
        XCTAssertFalse(wb.senderMatches("saman", address: "samiraquinn@example.com", name: nil))
    }

    func testSenderLocalPartFullWordMatches() {
        // A full word in the local-part still matches (e.g. mark@…).
        let wb = WordBoundary()
        XCTAssertTrue(wb.senderMatches("mark", address: "mark@example.com", name: nil))
    }

    func testSenderRoleAddressDoesNotLeak() {
        // The documented anti-noise case: "mark" must NOT match marketing@….
        let wb = WordBoundary()
        XCTAssertFalse(wb.senderMatches("mark", address: "marketing@engage.canva.com", name: "Canva"))
    }

    func testSenderNamePrefixStillMatchesRolePrefix() {
        // …but a real person named Mark matches via the display name.
        let wb = WordBoundary()
        XCTAssertTrue(wb.senderMatches("mark", address: "mferlatte@example.com", name: "Mark Ferlatte"))
    }

    func testSenderMatchesSecondWordPrefix() {
        // Prefix of a later word in a multi-word display name.
        let wb = WordBoundary()
        XCTAssertTrue(wb.senderMatches("qui", address: "samiraquinn@example.com", name: "Samira Quinn"))
    }

    func testSenderDoesNotMatchMidWord() {
        // Word-START boundary, not bare substring: "antha" is mid-word.
        let wb = WordBoundary()
        XCTAssertFalse(wb.senderMatches("antha", address: "samiraquinn@example.com", name: "Samira Quinn"))
    }

    func testSenderMatchIgnoresDomain() {
        // Domain is never considered — "yahoo" must not match.
        let wb = WordBoundary()
        XCTAssertFalse(wb.senderMatches("yahoo", address: "samiraquinn@example.com", name: "Samira Quinn"))
    }

    func testSenderFullWordStillMatches() {
        let wb = WordBoundary()
        XCTAssertTrue(wb.senderMatches("samira", address: "samiraquinn@example.com", name: "Samira Quinn"))
    }

    // MARK: - Schema: from_email / spam filter

    func testSchemaAdvertisesFromEmail() {
        XCTAssertNotNil(tool.definition.parameters?.properties?["from_email"],
                        "search should advertise an exact from_email scalpel")
    }

    func testSchemaAdvertisesSpamFilter() {
        XCTAssertNotNil(tool.definition.parameters?.properties?["exclude_spam"])
        XCTAssertEqual(tool.definition.parameters?.properties?["exclude_spam"]?.type_, "boolean")
    }

    // MARK: - from_email is a recognized criterion

    func testFromEmailCountsAsCriterion() {
        // from_email alone must satisfy the "at least one criterion" guard —
        // it should reach the DB (and fail on a missing DB path), not noCriteria.
        var criteria = EmailSearch.Criteria()
        criteria.fromEmail = "pinbot@pinterest.com"
        XCTAssertThrowsError(try EmailSearch.run(criteria, dbPath: "/nonexistent/Envelope Index")) { err in
            guard let e = err as? EmailSearch.SearchError else {
                return XCTFail("expected SearchError, got \(err)")
            }
            if case .dbMissing = e { return }
            XCTFail("expected dbMissing (criterion accepted), got \(e)")
        }
    }

    // MARK: - BulkSenderClassifier

    func testClassifierFlagsPostmaster() {
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "postmaster@matrixmail.ntreismls.com"))
    }

    func testClassifierFlagsBot() {
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "pinbot@pinterest.com", name: "Pinterest"))
    }

    func testClassifierFlagsNoReplyVariants() {
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "noreply@github.com"))
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "no-reply@github.com"))
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "do-not-reply@example.com"))
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "bounce-123@mail.example.com"))
    }

    func testClassifierClearsHumanSender() {
        // A real person on an apex domain must NOT be flagged.
        XCTAssertFalse(BulkSenderClassifier.isLikelyBulk(
            address: "leonel.miranda@example.org", name: "Leonel Miranda"))
        XCTAssertFalse(BulkSenderClassifier.isLikelyBulk(
            address: "samiraquinn@example.net", name: "Samira Quinn"))
    }

    func testClassifierDoesNotFlagGmailApex() {
        // Regression: `mail.` substring must not flag `gmail.com`.
        XCTAssertFalse(BulkSenderClassifier.isLikelyBulk(address: "alice@gmail.com", name: "Alice"))
    }

    func testClassifierFlagsMarketingSubdomain() {
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "hello@email.brand.com"))
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "team@engage.canva.com"))
    }

    // MARK: - Distinct-sender rollup grouping

    private func makeHit(_ address: String, _ name: String?, _ iso8601: String) -> EmailSearch.Hit {
        let f = ISO8601DateFormatter()
        let d = f.date(from: iso8601) ?? Date(timeIntervalSince1970: 0)
        return EmailSearch.Hit(
            messageID: "id-\(address)-\(iso8601)", rowID: 1, date: d,
            senderAddress: address, senderName: name, subject: "s",
            mailboxURL: "", snippet: nil, aiSummary: nil)
    }

    func testRollupEmptyForSingleDistinctAddress() {
        let hits = [
            makeHit("sandy@a.com", "Sandy", "2025-01-01T00:00:00Z"),
            makeHit("sandy@a.com", "Sandy", "2025-02-01T00:00:00Z"),
        ]
        XCTAssertTrue(EmailSearch.senderRollup(hits).isEmpty,
                      "one distinct address → no rollup (no clutter)")
    }

    func testRollupGroupsAndSortsByCount() {
        let hits = [
            makeHit("leonel@example.org", "Sandy Ford", "2025-05-03T00:00:00Z"),
            makeHit("pinbot@pinterest.com", "Sandy Ford", "2014-10-01T00:00:00Z"),
            makeHit("pinbot@pinterest.com", "Sandy Ford", "2014-11-01T00:00:00Z"),
            makeHit("postmaster@x.com", "Sandy Ford", "2015-06-01T00:00:00Z"),
        ]
        let r = EmailSearch.senderRollup(hits)
        XCTAssertEqual(r.count, 3, "three distinct addresses")
        XCTAssertEqual(r.first?.address, "pinbot@pinterest.com", "dominant sender leads")
        XCTAssertEqual(r.first?.count, 2)
        // Span of the dominant sender spans its two dates.
        let f = ISO8601DateFormatter()
        XCTAssertEqual(r.first?.first, f.date(from: "2014-10-01T00:00:00Z"))
        XCTAssertEqual(r.first?.last, f.date(from: "2014-11-01T00:00:00Z"))
    }

    func testRollupIsCaseInsensitiveOnAddress() {
        let hits = [
            makeHit("Foo@Bar.com", "Foo", "2025-01-01T00:00:00Z"),
            makeHit("foo@bar.com", "Foo", "2025-01-02T00:00:00Z"),
        ]
        XCTAssertTrue(EmailSearch.senderRollup(hits).isEmpty,
                      "case-variant addresses collapse to one distinct sender")
    }

    func testClassifierHeadersStrengthenSignal() {
        // Even an innocuous local-part is bulk when List-Unsubscribe is present.
        let h = BulkSenderClassifier.Headers(listUnsubscribe: "<mailto:unsub@list.com>")
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(
            address: "hello@somebrand.com", name: "Some Brand", headers: h))
        let p = BulkSenderClassifier.Headers(precedence: "bulk")
        XCTAssertTrue(BulkSenderClassifier.isLikelyBulk(address: "hello@somebrand.com", headers: p))
    }
}
