import AppKit
import Foundation
import Photos
import SQLite3
import UniformTypeIdentifiers

/// Shared Apple Photos integration. PhotoKit access, ML-label search via
/// psi.sqlite, image export and resize all live here.
///
/// Consumers: PhotosTool (LLM tool wrapper) and any future Photos integration
/// point.
///
/// Design: stateless enum with static methods.
public enum PhotosIntegration {

    // MARK: - Types

    public struct PSIResult {
        public let assets: PHFetchResult<PHAsset>
        public let matchedLabels: [String]
    }

    /// A named, recognized person from the Photos face-recognition database.
    public struct NamedPerson: Equatable {
        public let pk: Int64
        public let fullName: String?
        public let displayName: String?

        public init(pk: Int64, fullName: String?, displayName: String?) {
            self.pk = pk
            self.fullName = fullName
            self.displayName = displayName
        }

        /// Best human-readable label for the person.
        public var label: String {
            if let f = fullName, !f.isEmpty { return f }
            if let d = displayName, !d.isEmpty { return d }
            return "Unknown"
        }
    }

    public struct PersonResult {
        public let assets: PHFetchResult<PHAsset>
        public let matchedPeople: [String]
    }

    public struct ImageExport {
        public let data: Data?
        public let filename: String
    }

    // MARK: - Access

    public static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            granted = (status == .authorized || status == .limited)
            semaphore.signal()
        }

        semaphore.wait()
        return granted
    }

    public static func preflight() -> (ok: Bool, message: String) {
        let granted = requestAccess()
        return (granted, granted ? "photos access granted" : "photos access denied")
    }

    // MARK: - Date parsing

    public static func parseDate(_ str: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }

        let fmtBasic = ISO8601DateFormatter()
        if let d = fmtBasic.date(from: str) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = format
            if let d = df.date(from: str) { return d }
        }
        return nil
    }

    /// Parse an end-of-range date. A **date-only** string (no time component,
    /// e.g. `2019-12-31`) means "through the end of that day", so it's widened
    /// to local 23:59:59; a full timestamp (e.g. `2019-12-31T15:00:00Z`) is
    /// taken as the exact instant. Returns nil for unparseable input.
    public static func parseEndDate(_ str: String) -> Date? {
        guard let d = parseDate(str) else { return nil }
        let hasTime = str.contains("T") || str.contains(":")
        if hasTime { return d }
        return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d) ?? d
    }

    // MARK: - Search (PhotoKit)

    /// Fetch image-type assets in a date range. If `fetchLimit` is provided
    /// and no client-side filtering is needed, the fetch is bounded.
    public static func searchAllPhotos(start: Date?, end: Date?, fetchLimit: Int?) -> PHFetchResult<PHAsset> {
        let fetchOptions = PHFetchOptions()
        var predicates: [NSPredicate] = []

        if let start = start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = end {
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }
        predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit = fetchLimit {
            fetchOptions.fetchLimit = limit
        }

        return PHAsset.fetchAssets(with: fetchOptions)
    }

    /// Find an album by exact localized title. Checks user albums first, then
    /// smart albums.
    public static func findAlbum(name: String) -> PHAssetCollection? {
        let albumOptions = PHFetchOptions()
        albumOptions.predicate = NSPredicate(format: "localizedTitle == %@", name)

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumOptions)
        if let first = userAlbums.firstObject { return first }
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: albumOptions)
        return smartAlbums.firstObject
    }

    /// Fetch image-type assets in a specific album, optionally filtered by date.
    public static func searchInAlbum(_ album: PHAssetCollection, start: Date?, end: Date?) -> PHFetchResult<PHAsset> {
        let fetchOptions = PHFetchOptions()
        var predicates: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]

        if let start = start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = end {
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        return PHAsset.fetchAssets(in: album, options: fetchOptions)
    }

    /// Find a single asset by local identifier.
    public static func findAsset(id: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        return result.firstObject
    }

    // MARK: - PSI (ML label) search

    /// Why a content search produced no results. "The index says no photos of
    /// dogs" and "there is no index" look identical to a caller unless we say
    /// which — and the second must never be reported as the first.
    public enum ContentSearchOutcome {
        case matched(PSIResult)
        /// Index read successfully; the library genuinely has no such photos.
        case noMatch
        /// Could not consult an index at all. Carries a human-readable reason.
        case unavailable(String)
    }

    /// Search Photos by ML label, probing for whichever index this macOS ships:
    /// `psi.sqlite` through macOS 26, `leo.sqlite` from 27. Probed by presence
    /// and schema rather than by OS version, because Apple moves these stores in
    /// point releases and an iCloud sync can migrate one under an older OS
    /// (ADR-0004).
    public static func searchByContentLabels(query: String, start: Date?, end: Date?, limit: Int) -> ContentSearchOutcome {
        let fm = FileManager.default
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX

        if fm.isReadableFile(atPath: psiDatabasePath) {
            var db: OpaquePointer?
            guard sqlite3_open_v2(psiDatabasePath, &db, flags, nil) == SQLITE_OK, let db = db else {
                return .unavailable("the Photos search index could not be opened for reading")
            }
            defer { sqlite3_close(db) }

            guard validatePSISchema(db) else {
                return .unavailable("the Photos search index is in an unrecognized format")
            }
            return searchPSI(db: db, query: query, start: start, end: end, limit: limit)
        }

        if fm.isReadableFile(atPath: leoDatabasePath) {
            var db: OpaquePointer?
            guard sqlite3_open_v2(leoDatabasePath, &db, flags, nil) == SQLITE_OK, let db = db else {
                return .unavailable("the Photos search index could not be opened for reading")
            }
            defer { sqlite3_close(db) }

            guard validateLeoSchema(db) else {
                return .unavailable("the Photos search index is in an unrecognized format")
            }
            return searchLeo(db: db, query: query, start: start, end: end, limit: limit)
        }

        return .unavailable("the Photos search index is not present on this Mac")
    }

    /// Legacy entry point: collapses the outcome back to an optional. Prefer
    /// `searchByContentLabels` — this cannot distinguish empty from broken.
    public static func searchByPSI(query: String, start: Date?, end: Date?, limit: Int) -> PSIResult? {
        if case .matched(let result) = searchByContentLabels(query: query, start: start, end: end, limit: limit) {
            return result
        }
        return nil
    }

    private static func searchPSI(db: OpaquePointer, query: String, start: Date?, end: Date?, limit: Int) -> ContentSearchOutcome {

        // Match labels in categories that cover people, keywords, and ML content.
        // Escape LIKE wildcards so a query like `100%` matches literally rather
        // than every label (paired with `ESCAPE '\'`).
        let searchPattern = "%\(SQLEscaping.escapeLIKE(query.lowercased()))%"
        let groupSQL = """
            SELECT rowid, content_string, category FROM groups
            WHERE normalized_string LIKE ?1 ESCAPE '\\' AND category BETWEEN 1200 AND 1899
            ORDER BY
                CASE WHEN length(normalized_string) = length(?2) THEN 0 ELSE 1 END,
                length(normalized_string)
            LIMIT 20
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, groupSQL, -1, &stmt, nil) == SQLITE_OK else {
            return .unavailable("the Photos search index could not be queried")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, searchPattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, query.lowercased(), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var groupIDs: [Int64] = []
        var matchedLabels: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            groupIDs.append(sqlite3_column_int64(stmt, 0))
            if let cStr = sqlite3_column_text(stmt, 1) {
                var label = String(cString: cStr)
                if label.hasSuffix("\0") { label = String(label.dropLast()) }
                matchedLabels.append(label)
            }
        }

        // Index consulted fine, no label matched: a real "no such photos".
        if groupIDs.isEmpty { return .noMatch }

        let placeholders = groupIDs.map { _ in "?" }.joined(separator: ",")

        // Collect every asset UUID for the matched labels, unfiltered and
        // unordered. Date filtering, newest-first ordering, and the final limit
        // are ALL done by the PhotoKit fetch below against the real
        // `creationDate`. We deliberately do NOT filter or order on
        // psi.sqlite's `assets.creationDate`: despite the name it is not the
        // photo's capture time (values are a quantized index timestamp — a
        // 2026 asset reads ~25M, and the column min maps to ~Oct 2025 even
        // though the library's oldest photo is 2007). Binding an Apple-epoch
        // range against it returned zero rows for every date-scoped query
        // (issue #32 regression); ordering by it sorts by index age, not photo
        // age.
        let assetSQL = """
            SELECT DISTINCT a.uuid_0, a.uuid_1
            FROM ga JOIN assets a ON a.rowid = ga.assetid
            WHERE ga.groupid IN (\(placeholders))
            """

        var assetStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, assetSQL, -1, &assetStmt, nil) == SQLITE_OK else {
            return .unavailable("the Photos search index could not be queried")
        }
        defer { sqlite3_finalize(assetStmt) }

        var bindIdx: Int32 = 1
        for gid in groupIDs {
            sqlite3_bind_int64(assetStmt, bindIdx, gid)
            bindIdx += 1
        }

        var localIdentifiers: [String] = []
        while sqlite3_step(assetStmt) == SQLITE_ROW {
            let uuid0 = sqlite3_column_int64(assetStmt, 0)
            let uuid1 = sqlite3_column_int64(assetStmt, 1)
            if let uuidStr = decodePhotosUUID(uuid0: uuid0, uuid1: uuid1) {
                localIdentifiers.append("\(uuidStr)/L0/001")
            }
        }

        return resolveAssets(localIdentifiers: localIdentifiers, matchedLabels: matchedLabels,
                             start: start, end: end, limit: limit)
    }

    /// Turn index-derived UUIDs into assets. Date filtering, newest-first
    /// ordering and the limit all happen HERE, against PhotoKit's real
    /// `creationDate` — never against an index's own timestamp column, which in
    /// both psi and leo is an indexing time, not a capture time (issue #32).
    private static func resolveAssets(localIdentifiers: [String], matchedLabels: [String],
                                      start: Date?, end: Date?, limit: Int) -> ContentSearchOutcome {
        if localIdentifiers.isEmpty { return .noMatch }

        let fetchOptions = PHFetchOptions()
        var predicates: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let start = start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = end {
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // PhotoKit sorts by true creationDate before applying the limit, so
        // this yields the newest `limit` matches within the date range.
        fetchOptions.fetchLimit = limit

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: fetchOptions)
        return .matched(PSIResult(assets: assets, matchedLabels: matchedLabels))
    }

    // MARK: - leo (macOS 27 ML label index)

    /// Scene labels in `lexicon`: category 4000, keyed `scene/N`, canonical term
    /// (type 1) plus synonyms (type 2) sharing one lexeme_id — "Dog"/"Dogs"/"Doggy".
    ///
    /// Deliberately NOT 4120, which is OCR'd text from inside the image. Mixing
    /// it in means "dog" matches a billboard reading DOG, and "the" matches half
    /// the library — that is a text search wearing a content search's label.
    /// Worth having as its own match mode; it is not this one.
    private static let leoLabelCategories = "4000"

    /// macOS 27's index inverts psi's layout: instead of a `ga` join table,
    /// each item carries a packed list of the lexeme ids that describe it.
    private static func searchLeo(db: OpaquePointer, query: String, start: Date?, end: Date?, limit: Int) -> ContentSearchOutcome {
        guard let match = leoMatches(db: db, query: query) else {
            return .unavailable("the Photos search index could not be queried")
        }
        return resolveAssets(localIdentifiers: match.identifiers, matchedLabels: match.labels,
                             start: start, end: end, limit: limit)
    }

    /// The index half of a leo search: query in, asset UUIDs out. Split from
    /// PhotoKit resolution so the schema assumptions can be tested against a
    /// fixture. Returns nil only when the index itself could not be queried —
    /// an empty result means the library genuinely has no such photos.
    static func leoMatches(db: OpaquePointer, query: String) -> (identifiers: [String], labels: [String])? {
        let searchPattern = "%\(SQLEscaping.escapeLIKE(query.lowercased()))%"
        let lexiconSQL = """
            SELECT DISTINCT lexeme_id, content FROM lexicon
            WHERE content LIKE ?1 ESCAPE '\\' AND category IN (\(leoLabelCategories))
            ORDER BY
                CASE WHEN length(content) = length(?2) THEN 0 ELSE 1 END,
                length(content)
            LIMIT 20
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, lexiconSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, searchPattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, query.lowercased(), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var wanted = Set<UInt32>()
        var matchedLabels: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lexemeID = sqlite3_column_int64(stmt, 0)
            guard lexemeID >= 0, lexemeID <= Int64(UInt32.max) else { continue }
            wanted.insert(UInt32(lexemeID))
            if let cStr = sqlite3_column_text(stmt, 1) {
                matchedLabels.append(String(cString: cStr))
            }
        }

        // Index consulted fine, no label matched: a real "no such photos".
        if wanted.isEmpty { return ([], []) }

        var itemStmt: OpaquePointer?
        let itemSQL = "SELECT identifier, lexeme_ids FROM items WHERE lexeme_ids IS NOT NULL"
        guard sqlite3_prepare_v2(db, itemSQL, -1, &itemStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(itemStmt) }

        // ponytail: full scan, decoding each item's blob. There is no index on
        // blob contents, so SQL cannot do this for us. ~2k items here; if a
        // library ever makes this slow, cache lexeme_id -> identifiers.
        var localIdentifiers: [String] = []
        while sqlite3_step(itemStmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(itemStmt, 0) else { continue }
            guard let blob = sqlite3_column_blob(itemStmt, 1) else { continue }
            let byteCount = Int(sqlite3_column_bytes(itemStmt, 1))
            guard byteCount >= 4 else { continue }

            if lexemeBlob(blob, byteCount: byteCount, intersects: wanted) {
                localIdentifiers.append("\(String(cString: idStr))/L0/001")
            }
        }

        return (localIdentifiers, matchedLabels)
    }

    /// `items.lexeme_ids` is a packed array of little-endian UInt32 lexeme ids.
    /// Read unaligned: SQLite makes no alignment promise about blob storage.
    private static func lexemeBlob(_ blob: UnsafeRawPointer, byteCount: Int, intersects wanted: Set<UInt32>) -> Bool {
        for offset in stride(from: 0, to: byteCount - (byteCount % 4), by: 4) {
            let id = UInt32(littleEndian: blob.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            if wanted.contains(id) { return true }
        }
        return false
    }

    /// Validate leo.sqlite's shape before trusting it.
    static func validateLeoSchema(_ db: OpaquePointer) -> Bool {
        validateSchema(db, expectations: [
            ("lexicon", ["lexeme_id", "category", "content"]),
            ("items", ["identifier", "lexeme_ids"]),
        ])
    }

    private static var psiDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Photos Library.photoslibrary/database/search/psi.sqlite"
    }

    /// Non-nil when keyword/content search cannot work on this Mac, describing
    /// why. Permissions can be fully granted and this still be broken.
    public static func contentSearchDegradation() -> String? {
        switch searchByContentLabels(query: "_probe_", start: nil, end: nil, limit: 1) {
        case .unavailable(let reason):
            return "photo keyword/content search unavailable: \(reason)"
        case .matched, .noMatch:
            return nil
        }
    }

    /// macOS 27's replacement for psi.sqlite.
    private static var leoDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Photos Library.photoslibrary/database/search/leo.sqlite"
    }

    /// Validate that psi.sqlite has the expected schema. Returns false if anything is unexpected.
    private static func validatePSISchema(_ db: OpaquePointer) -> Bool {
        guard validateSchema(db, expectations: [
            ("groups", ["category", "content_string", "normalized_string"]),
            ("ga", ["groupid", "assetid"]),
            ("assets", ["uuid_0", "uuid_1", "creationDate"]),
        ]) else { return false }

        var checkStmt: OpaquePointer?
        let checkSQL = "SELECT 1 FROM groups WHERE category = 1500 LIMIT 1"
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(checkStmt) }

        return sqlite3_step(checkStmt) == SQLITE_ROW
    }

    /// Every required column must be present. Only ever add a column here when a
    /// result WITHOUT it is worthless — an optional field in the required set is
    /// what silently killed the whole podcast source on macOS 27 (ADR-0004).
    private static func validateSchema(_ db: OpaquePointer, expectations: [(table: String, columns: Set<String>)]) -> Bool {
        for (table, requiredColumns) in expectations {
            var stmt: OpaquePointer?
            let sql = "PRAGMA table_info(\(table))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            var foundColumns: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    foundColumns.insert(String(cString: name))
                }
            }
            if !requiredColumns.isSubset(of: foundColumns) { return false }
        }
        return true
    }

    private static func decodePhotosUUID(uuid0: Int64, uuid1: Int64) -> String? {
        // Little-endian pack of two signed Int64s produces the UUID bytes.
        var u0 = uuid0.littleEndian
        var u1 = uuid1.littleEndian
        let data = withUnsafeBytes(of: &u0) { b0 in
            withUnsafeBytes(of: &u1) { b1 in
                Data(b0) + Data(b1)
            }
        }
        guard data.count == 16 else { return nil }

        let uuid = data.withUnsafeBytes { ptr -> UUID in
            NSUUID(uuidBytes: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)) as UUID
        }
        return uuid.uuidString.uppercased()
    }

    // MARK: - People (face recognition) search

    /// Normalize a person name for comparison: trimmed, lowercased, internal
    /// whitespace collapsed. Pure and testable.
    public static func normalizePersonName(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = lowered.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Select recognized people matching a query name. Pure (no DB) so it is
    /// unit-testable. Strategy: prefer exact (normalized) matches on full or
    /// display name; if none, fall back to substring matches on either name.
    /// This makes "Sandy Ford" pick exactly that person while "John" can match
    /// several recognized Johns ("photos of John").
    public static func matchPeople(_ people: [NamedPerson], query: String) -> [NamedPerson] {
        let q = normalizePersonName(query)
        guard !q.isEmpty else { return [] }

        func names(_ p: NamedPerson) -> [String] {
            [p.fullName, p.displayName].compactMap { $0 }.map(normalizePersonName).filter { !$0.isEmpty }
        }

        let exact = people.filter { names($0).contains(q) }
        if !exact.isEmpty { return exact }
        return people.filter { p in names(p).contains { $0.contains(q) } }
    }

    /// Read all named, recognized people from the Photos database. Returns nil
    /// when the database is unavailable or the schema doesn't match.
    public static func fetchNamedPeople() -> [NamedPerson]? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(photosDatabasePath, &db, flags, nil) == SQLITE_OK, let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }
        guard validatePhotosPersonSchema(db) else { return nil }

        let sql = """
            SELECT Z_PK, ZFULLNAME, ZDISPLAYNAME FROM ZPERSON
            WHERE (ZFULLNAME IS NOT NULL AND ZFULLNAME <> '')
               OR (ZDISPLAYNAME IS NOT NULL AND ZDISPLAYNAME <> '')
            ORDER BY ZFACECOUNT DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var people: [NamedPerson] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let full = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let display = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            people.append(NamedPerson(pk: pk, fullName: full, displayName: display))
        }
        return people
    }

    /// Find assets that contain a recognized person matching `name`. Returns nil
    /// when the database is unavailable, the schema doesn't match, the name
    /// matches no recognized person, or no assets are found — callers should
    /// surface that explicitly rather than falling back to a blended search.
    public static func searchByPerson(name: String, start: Date?, end: Date?, limit: Int) -> PersonResult? {
        guard let people = fetchNamedPeople() else { return nil }
        let matched = matchPeople(people, query: name)
        if matched.isEmpty { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(photosDatabasePath, &db, flags, nil) == SQLITE_OK, let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = matched.map { _ in "?" }.joined(separator: ",")
        // The old query applied an unordered `LIMIT max(limit*10, 200)` and then
        // date-filtered the arbitrary query-plan-dependent slice in PhotoKit — so
        // a person with thousands of photos could return an empty result for a
        // valid date range. When a date range is present, drop the SQL LIMIT
        // entirely so PhotoKit's date filter + newest-first sort sees every one
        // of the person's assets; otherwise keep the bound to cap total scan.
        let hasDateRange = start != nil || end != nil
        let uuidCap = max(limit * 10, 200)
        var sql = """
            SELECT DISTINCT a.ZUUID
            FROM ZASSET a JOIN ZDETECTEDFACE f ON f.ZASSETFORFACE = a.Z_PK
            WHERE f.ZPERSONFORFACE IN (\(placeholders)) AND a.ZUUID IS NOT NULL
            """
        if !hasDateRange { sql += "\n            LIMIT ?" }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        for (i, person) in matched.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), person.pk)
        }
        if !hasDateRange {
            sqlite3_bind_int(stmt, Int32(matched.count + 1), Int32(uuidCap))
        }

        var localIdentifiers: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                localIdentifiers.append("\(String(cString: cStr))/L0/001")
            }
        }
        if localIdentifiers.isEmpty { return nil }

        let fetchOptions = PHFetchOptions()
        var predicates: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let start = start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = end {
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: fetchOptions)
        return PersonResult(assets: assets, matchedPeople: matched.map { $0.label })
    }

    private static var photosDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"
    }

    /// Validate the Photos database exposes the face-recognition tables/columns
    /// we depend on. Returns false if anything is unexpected (e.g. an OS that
    /// reorganized the schema), so callers can degrade gracefully.
    private static func validatePhotosPersonSchema(_ db: OpaquePointer) -> Bool {
        let expectations: [(table: String, columns: Set<String>)] = [
            ("ZPERSON", ["Z_PK", "ZFULLNAME", "ZDISPLAYNAME"]),
            ("ZDETECTEDFACE", ["ZASSETFORFACE", "ZPERSONFORFACE"]),
            ("ZASSET", ["Z_PK", "ZUUID"]),
        ]
        for (table, requiredColumns) in expectations {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            var found: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) { found.insert(String(cString: name)) }
            }
            if !requiredColumns.isSubset(of: found) { return false }
        }
        return true
    }

    // MARK: - Image export

    /// Request the original full-resolution image data, transcoding HEIC/HEIF
    /// to JPEG so downstream consumers don't need HEIF support.
    public static func requestFullResImage(_ asset: PHAsset) -> ImageExport {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultFilename = "photo.jpg"

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.version = .current

        let resources = PHAssetResource.assetResources(for: asset)
        if let primary = resources.first {
            resultFilename = primary.originalFilename
        }

        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
            if let data = data, let uti = uti,
               let utType = UTType(uti), utType.conforms(to: .heic) || utType.conforms(to: .heif),
               let nsImage = NSImage(data: data),
               let tiffData = nsImage.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData) {
                resultData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
                let base = (resultFilename as NSString).deletingPathExtension
                resultFilename = "\(base).jpg"
            } else {
                resultData = data
                if let uti = uti, let utType = UTType(uti), let ext = utType.preferredFilenameExtension {
                    let base = (resultFilename as NSString).deletingPathExtension
                    resultFilename = "\(base).\(ext)"
                }
            }
            semaphore.signal()
        }

        semaphore.wait()
        return ImageExport(data: resultData, filename: resultFilename)
    }

    /// Request a resized JPEG suitable for LLM vision input.
    public static func requestResizedImage(_ asset: PHAsset, maxDimension: Int) -> ImageExport {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?

        let originalWidth = asset.pixelWidth
        let originalHeight = asset.pixelHeight
        let targetSize: CGSize
        if originalWidth >= originalHeight {
            let scale = CGFloat(maxDimension) / CGFloat(originalWidth)
            targetSize = CGSize(width: maxDimension, height: Int(CGFloat(originalHeight) * scale))
        } else {
            let scale = CGFloat(maxDimension) / CGFloat(originalHeight)
            targetSize = CGSize(width: Int(CGFloat(originalWidth) * scale), height: maxDimension)
        }

        let finalSize: CGSize
        if originalWidth <= maxDimension && originalHeight <= maxDimension {
            finalSize = CGSize(width: originalWidth, height: originalHeight)
        } else {
            finalSize = targetSize
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        PHImageManager.default().requestImage(for: asset, targetSize: finalSize, contentMode: .aspectFit, options: options) { image, _ in
            if let nsImage = image, let tiffData = nsImage.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData) {
                resultData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }
            semaphore.signal()
        }

        semaphore.wait()

        let resources = PHAssetResource.assetResources(for: asset)
        let baseName: String
        if let primary = resources.first {
            baseName = (primary.originalFilename as NSString).deletingPathExtension
        } else {
            baseName = "photo"
        }
        return ImageExport(data: resultData, filename: "\(baseName).jpg")
    }
}
