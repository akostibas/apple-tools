import Foundation
import Photos

public struct PhotosTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "photos",
        description: "Access the Apple Photos library. Actions: 'search' (find photos by keyword, date, or album), 'fetch' (export a photo into the local output dir; returns its path).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "search or fetch"),
                "query": PropertySchema(type_: "string", description: "Search keyword — matches ML-recognized content (car, dog, beach), people, and filenames (for search)"),
                "album": PropertySchema(type_: "string", description: "Album name to filter by (for search)"),
                "start_date": PropertySchema(type_: "string", description: "Start date, ISO 8601 e.g. 2026-01-15 (for search)"),
                "end_date": PropertySchema(type_: "string", description: "End date, ISO 8601 (for search)"),
                "limit": PropertySchema(type_: "integer", description: "Max results to return (for search, default 20)"),
                "id": PropertySchema(type_: "string", description: "Photo local identifier from search results (for fetch)"),
                "full_resolution": PropertySchema(type_: "boolean", description: "Export at full resolution instead of LLM-optimized size (for fetch, default false)"),
            ],
            required: ["action"]
        )
    )

    public let fileSink: FileSink

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "search": .read,
        "fetch":  .read,
    ])

    public init(fileSink: FileSink) {
        self.fileSink = fileSink
    }

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard PhotosIntegration.requestAccess() else {
            return ("Photos access denied. Grant permission in System Settings → Privacy & Security → Photos.", true)
        }

        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "search":
            let query = params?["query"]?.value as? String
            let album = params?["album"]?.value as? String
            let startDate = params?["start_date"]?.value as? String
            let endDate = params?["end_date"]?.value as? String
            let limit = params?["limit"]?.value as? Int ?? 20
            return search(query: query, album: album, startDate: startDate, endDate: endDate, limit: limit)
        case "fetch":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            let fullRes = params?["full_resolution"]?.value as? Bool ?? false
            return fetch(id: id, fullResolution: fullRes)
        default:
            return ("unknown action: \(action) (use search or fetch)", true)
        }
    }

    public func preflight() -> (ok: Bool, message: String) {
        return PhotosIntegration.preflight()
    }

    // MARK: - Search

    private func search(query: String?, album: String?, startDate: String?, endDate: String?, limit: Int) -> (String, Bool) {
        if let albumName = album {
            return searchInAlbum(albumName: albumName, query: query, startDate: startDate, endDate: endDate, limit: limit)
        }

        // PSI (ML-label) search first when there's a keyword.
        if let query = query, !query.isEmpty {
            // Validate dates before touching PSI so format errors come back quickly.
            var startDateObj: Date?
            var endDateObj: Date?
            if let startStr = startDate {
                guard let d = PhotosIntegration.parseDate(startStr) else {
                    return ("invalid start_date format (use ISO 8601, e.g. 2026-01-15 or 2026-01-15T09:00:00Z)", true)
                }
                startDateObj = d
            }
            if let endStr = endDate {
                guard let d = PhotosIntegration.parseDate(endStr) else {
                    return ("invalid end_date format", true)
                }
                endDateObj = d
            }

            if let psi = PhotosIntegration.searchByPSI(query: query, start: startDateObj, end: endDateObj, limit: limit) {
                var results: [[String: Any]] = []
                psi.assets.enumerateObjects { asset, _, stop in
                    if results.count >= limit {
                        stop.pointee = true
                        return
                    }
                    results.append(self.assetMetadata(asset))
                }
                let response: [String: Any] = [
                    "count": results.count,
                    "matched_labels": Array(psi.matchedLabels.prefix(5)),
                    "search_method": "ml_labels",
                    "photos": results,
                ]
                return (jsonEncode(response), false)
            }
            // Fall through to filename search.
        }

        return searchViaPhotoKit(query: query, startDate: startDate, endDate: endDate, limit: limit)
    }

    private func searchViaPhotoKit(query: String?, startDate: String?, endDate: String?, limit: Int) -> (String, Bool) {
        var startDateObj: Date?
        var endDateObj: Date?
        if let startStr = startDate {
            guard let d = PhotosIntegration.parseDate(startStr) else {
                return ("invalid start_date format (use ISO 8601, e.g. 2026-01-15 or 2026-01-15T09:00:00Z)", true)
            }
            startDateObj = d
        }
        if let endStr = endDate {
            guard let d = PhotosIntegration.parseDate(endStr) else {
                return ("invalid end_date format", true)
            }
            endDateObj = d
        }

        // When filtering client-side by keyword, scan more assets than the limit
        // but cap the work so a no-match query can't walk the entire library.
        let hasQuery = !(query?.isEmpty ?? true)
        let scanCap = max(limit * 50, 500)
        let fetchLimit: Int? = hasQuery ? scanCap : limit
        let assets = PhotosIntegration.searchAllPhotos(start: startDateObj, end: endDateObj, fetchLimit: fetchLimit)

        var results: [[String: Any]] = []
        var examined = 0
        var hitScanCap = false
        let queryLower = query?.lowercased()

        assets.enumerateObjects { asset, _, stop in
            if results.count >= limit {
                stop.pointee = true
                return
            }
            if hasQuery && examined >= scanCap {
                hitScanCap = true
                stop.pointee = true
                return
            }
            examined += 1
            let metadata = self.assetMetadata(asset)
            if let q = queryLower {
                let filename = (metadata["filename"] as? String ?? "").lowercased()
                if !filename.contains(q) { return }
            }
            results.append(metadata)
        }

        var response: [String: Any] = [
            "count": results.count,
            "photos": results,
        ]
        if hasQuery {
            response["search_method"] = "filename"
            if hitScanCap {
                response["truncated"] = true
                response["scanned"] = examined
            }
        }
        return (jsonEncode(response), false)
    }

    private func searchInAlbum(albumName: String, query: String?, startDate: String?, endDate: String?, limit: Int) -> (String, Bool) {
        guard let album = PhotosIntegration.findAlbum(name: albumName) else {
            return ("no album found with name: \(albumName)", true)
        }

        var startDateObj: Date?
        var endDateObj: Date?
        if let startStr = startDate {
            guard let d = PhotosIntegration.parseDate(startStr) else {
                return ("invalid start_date format (use ISO 8601, e.g. 2026-01-15 or 2026-01-15T09:00:00Z)", true)
            }
            startDateObj = d
        }
        if let endStr = endDate {
            guard let d = PhotosIntegration.parseDate(endStr) else {
                return ("invalid end_date format", true)
            }
            endDateObj = d
        }

        let assets = PhotosIntegration.searchInAlbum(album, start: startDateObj, end: endDateObj)

        var results: [[String: Any]] = []
        var examined = 0
        var hitScanCap = false
        let hasQuery = !(query?.isEmpty ?? true)
        let scanCap = max(limit * 50, 500)
        let queryLower = query?.lowercased()

        assets.enumerateObjects { asset, _, stop in
            if results.count >= limit {
                stop.pointee = true
                return
            }
            if hasQuery && examined >= scanCap {
                hitScanCap = true
                stop.pointee = true
                return
            }
            examined += 1
            let metadata = self.assetMetadata(asset)
            if let q = queryLower {
                let filename = (metadata["filename"] as? String ?? "").lowercased()
                let description = (metadata["description"] as? String ?? "").lowercased()
                if !filename.contains(q) && !description.contains(q) { return }
            }
            results.append(metadata)
        }

        var response: [String: Any] = [
            "count": results.count,
            "album": albumName,
            "photos": results,
        ]
        if hasQuery && hitScanCap {
            response["truncated"] = true
            response["scanned"] = examined
        }
        return (jsonEncode(response), false)
    }

    // MARK: - Fetch

    private func fetch(id: String, fullResolution: Bool) -> (String, Bool) {
        guard let asset = PhotosIntegration.findAsset(id: id) else {
            return ("no photo found with id: \(id)", true)
        }

        let export = fullResolution
            ? PhotosIntegration.requestFullResImage(asset)
            : PhotosIntegration.requestResizedImage(asset, maxDimension: 1568)

        guard let data = export.data else {
            return ("failed to export photo", true)
        }

        let result = fileSink.deliver(filename: export.filename, data: data)
        switch result {
        case .success(let path):
            var response: [String: Any] = [
                "path": path,
                "filename": export.filename,
            ]
            if !fullResolution {
                response["note"] = "Resized to max 1568px. Use full_resolution: true for the original."
            }
            return (jsonEncode(response), false)
        case .failure(let error):
            return ("upload failed: \(error)", true)
        }
    }

    // MARK: - LLM payload formatting

    private func assetMetadata(_ asset: PHAsset) -> [String: Any] {
        let fmt = ISO8601DateFormatter()
        var entry: [String: Any] = [
            "id": asset.localIdentifier,
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "media_subtype": mediaSubtypeLabels(asset.mediaSubtypes),
        ]

        if let created = asset.creationDate {
            entry["created"] = fmt.string(from: created)
        }

        if let modified = asset.modificationDate {
            entry["modified"] = fmt.string(from: modified)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        if let primary = resources.first {
            entry["filename"] = primary.originalFilename
        }

        if let location = asset.location {
            entry["location"] = [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
            ]
        }

        if asset.isFavorite {
            entry["favorite"] = true
        }

        return entry
    }

    private func mediaSubtypeLabels(_ subtypes: PHAssetMediaSubtype) -> [String] {
        var labels: [String] = []
        if subtypes.contains(.photoPanorama) { labels.append("panorama") }
        if subtypes.contains(.photoHDR) { labels.append("hdr") }
        if subtypes.contains(.photoScreenshot) { labels.append("screenshot") }
        if subtypes.contains(.photoLive) { labels.append("live") }
        if subtypes.contains(.photoDepthEffect) { labels.append("depth") }
        return labels
    }

    private func jsonEncode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
