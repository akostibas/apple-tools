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
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            predicates.append(NSPredicate(format: "creationDate <= %@", endOfDay as NSDate))
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
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            predicates.append(NSPredicate(format: "creationDate <= %@", endOfDay as NSDate))
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

    /// Search Photos using the ML label index in psi.sqlite. Returns nil when
    /// the database is unavailable, the schema doesn't match, or there are
    /// no label matches — the caller should fall back to other modes.
    public static func searchByPSI(query: String, start: Date?, end: Date?, limit: Int) -> PSIResult? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(psiDatabasePath, &db, flags, nil) == SQLITE_OK, let db = db else {
            return nil
        }
        defer { sqlite3_close(db) }

        guard validatePSISchema(db) else { return nil }

        // Match labels in categories that cover people, keywords, and ML content.
        let searchPattern = "%\(query.lowercased())%"
        let groupSQL = """
            SELECT rowid, content_string, category FROM groups
            WHERE normalized_string LIKE ?1 AND category BETWEEN 1200 AND 1899
            ORDER BY
                CASE WHEN length(normalized_string) = length(?2) THEN 0 ELSE 1 END,
                length(normalized_string)
            LIMIT 20
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, groupSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
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

        if groupIDs.isEmpty { return nil }

        let fetchMultiplier = 3
        let placeholders = groupIDs.map { _ in "?" }.joined(separator: ",")
        let assetSQL = """
            SELECT DISTINCT a.uuid_0, a.uuid_1
            FROM ga JOIN assets a ON a.rowid = ga.assetid
            WHERE ga.groupid IN (\(placeholders))
            ORDER BY a.creationDate DESC
            LIMIT ?
            """

        var assetStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, assetSQL, -1, &assetStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(assetStmt) }

        for (i, gid) in groupIDs.enumerated() {
            sqlite3_bind_int64(assetStmt, Int32(i + 1), gid)
        }
        sqlite3_bind_int(assetStmt, Int32(groupIDs.count + 1), Int32(limit * fetchMultiplier))

        var localIdentifiers: [String] = []
        while sqlite3_step(assetStmt) == SQLITE_ROW {
            let uuid0 = sqlite3_column_int64(assetStmt, 0)
            let uuid1 = sqlite3_column_int64(assetStmt, 1)
            if let uuidStr = decodePhotosUUID(uuid0: uuid0, uuid1: uuid1) {
                localIdentifiers.append("\(uuidStr)/L0/001")
            }
        }

        if localIdentifiers.isEmpty { return nil }

        let fetchOptions = PHFetchOptions()
        var predicates: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let start = start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = end {
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            predicates.append(NSPredicate(format: "creationDate <= %@", endOfDay as NSDate))
        }
        fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: fetchOptions)
        return PSIResult(assets: assets, matchedLabels: matchedLabels)
    }

    private static var psiDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Photos Library.photoslibrary/database/search/psi.sqlite"
    }

    /// Validate that psi.sqlite has the expected schema. Returns false if anything is unexpected.
    private static func validatePSISchema(_ db: OpaquePointer) -> Bool {
        let expectations: [(table: String, columns: Set<String>)] = [
            ("groups", ["category", "content_string", "normalized_string"]),
            ("ga", ["groupid", "assetid"]),
            ("assets", ["uuid_0", "uuid_1", "creationDate"]),
        ]

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

        var checkStmt: OpaquePointer?
        let checkSQL = "SELECT 1 FROM groups WHERE category = 1500 LIMIT 1"
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(checkStmt) }

        return sqlite3_step(checkStmt) == SQLITE_ROW
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
