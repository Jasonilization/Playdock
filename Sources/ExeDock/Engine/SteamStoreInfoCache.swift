import Foundation

/// Looks up a short description and header image for a game the user already has installed, from
/// Steam's public storefront API - no login, no API key, just the numeric appID (which is not
/// sensitive - it's the same ID visible in the game's own store URL). Purely cosmetic: every card
/// already works without this, so any failure here (offline, API hiccup) is silently ignored.
///
/// Everything is cached to disk after the first successful fetch, so this only ever hits the network
/// once per game, ever - opening Game Mode again, or relaunching ExeDock, reads straight from disk.
actor SteamStoreInfoCache {
    static let shared = SteamStoreInfoCache()

    private var memoryCache: [String: SteamStoreInfo?] = [:]
    private let cacheDir = ("~/Library/Application Support/ExeDock/StoreInfoCache" as NSString).expandingTildeInPath

    /// Drops every in-memory result so the next `info(for:)` re-reads disk (or, after the on-disk
    /// cache has also been wiped, re-fetches from Steam). Used by Settings' "Hard Refresh Game
    /// Info" - clearing the disk files alone wouldn't be enough while a stale copy still sits here.
    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    func info(for appID: String) async -> SteamStoreInfo? {
        if let cached = memoryCache[appID] {
            return cached
        }
        // A cache file written by an older version of SteamStoreInfo decodes fine (its own lenient
        // init just leaves newer fields empty) but should still be treated as stale rather than
        // trusted forever - otherwise a game looked up once, before some later enrichment shipped,
        // would never pick up the new fields. See SteamStoreInfo.isStale/currentSchemaVersion.
        if let onDisk = readFromDisk(appID), !onDisk.isStale {
            memoryCache[appID] = onDisk
            return onDisk
        }
        let fetched = await fetchFromNetwork(appID)
        memoryCache[appID] = fetched
        if let fetched {
            writeToDisk(appID, fetched)
        }
        return fetched
    }

    private func fetchFromNetwork(_ appID: String) async -> SteamStoreInfo? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english") else {
            DiagnosticsLog.log("Store info [\(appID)]: couldn't build appdetails URL")
            return nil
        }
        let responseResult: (data: Data, response: URLResponse)
        do {
            responseResult = try await URLSession.shared.data(from: url)
        } catch {
            DiagnosticsLog.log("Store info [\(appID)]: request failed - \(error.localizedDescription)")
            return nil
        }
        guard let http = responseResult.response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (responseResult.response as? HTTPURLResponse)?.statusCode
            DiagnosticsLog.log("Store info [\(appID)]: bad HTTP status \(status.map(String.init) ?? "?")")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseResult.data) as? [String: Any],
              let entry = json[appID] as? [String: Any],
              entry["success"] as? Bool == true,
              let appData = entry["data"] as? [String: Any] else {
            DiagnosticsLog.log("Store info [\(appID)]: response didn't parse as expected (app may be delisted, or Steam changed the response shape)")
            return nil
        }

        let description = (appData["short_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutTheGame = (appData["about_the_game"] as? String).map(SteamStoreInfo.plainText(fromHTML:))
        var headerImagePath: String?
        if let headerImageURLString = appData["header_image"] as? String, let headerImageURL = URL(string: headerImageURLString) {
            headerImagePath = await downloadImage(headerImageURL, appID: appID, suffix: "header")
        }
        var backgroundImagePath: String?
        if let backgroundURLString = appData["background_raw"] as? String ?? appData["background"] as? String,
           let backgroundURL = URL(string: backgroundURLString) {
            backgroundImagePath = await downloadImage(backgroundURL, appID: appID, suffix: "background")
        }

        // Thumbnails only, and only the first handful - a screenshot strip doesn't need the whole
        // gallery (some games ship dozens), and full-resolution shots aren't worth the bandwidth for
        // what's still just a supporting visual, not the main event.
        var screenshotPaths: [String] = []
        let screenshots = (appData["screenshots"] as? [[String: Any]]) ?? []
        for (index, screenshot) in screenshots.prefix(6).enumerated() {
            guard let thumbURLString = screenshot["path_thumbnail"] as? String, let thumbURL = URL(string: thumbURLString) else { continue }
            if let path = await downloadImage(thumbURL, appID: appID, suffix: "screenshot-\(index)") {
                screenshotPaths.append(path)
            }
        }

        let genres = ((appData["genres"] as? [[String: Any]]) ?? []).compactMap { $0["description"] as? String }
        let categories = ((appData["categories"] as? [[String: Any]]) ?? []).compactMap { $0["description"] as? String }
        let releaseDate = (appData["release_date"] as? [String: Any])?["date"] as? String
        let developers = (appData["developers"] as? [String]) ?? []
        let publishers = (appData["publishers"] as? [String]) ?? []
        let metacritic = appData["metacritic"] as? [String: Any]
        let metacriticScore = metacritic?["score"] as? Int
        let metacriticURL = metacritic?["url"] as? String

        let hasAnyMetadata = description?.isEmpty == false || headerImagePath != nil || !genres.isEmpty
            || !developers.isEmpty || releaseDate != nil
        guard hasAnyMetadata else {
            DiagnosticsLog.log("Store info [\(appID)]: fetched OK but had no usable metadata at all")
            return nil
        }
        DiagnosticsLog.log("Store info [\(appID)]: OK (description: \(description?.isEmpty == false), headerImage: \(headerImagePath != nil), screenshots: \(screenshotPaths.count), genres: \(genres.count), metacritic: \(metacriticScore.map(String.init) ?? "-"))")
        return SteamStoreInfo(
            shortDescription: (description?.isEmpty == false) ? description : nil,
            aboutTheGame: (aboutTheGame?.isEmpty == false) ? aboutTheGame : nil,
            headerImagePath: headerImagePath,
            backgroundImagePath: backgroundImagePath,
            screenshotPaths: screenshotPaths,
            genres: genres,
            releaseDate: releaseDate,
            developers: developers,
            publishers: publishers,
            metacriticScore: metacriticScore,
            metacriticURL: metacriticURL,
            categories: categories
        )
    }

    private func downloadImage(_ url: URL, appID: String, suffix: String) async -> String? {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let destination = (cacheDir as NSString).appendingPathComponent("\(appID)-\(suffix).jpg")
        let downloadResult: (url: URL, response: URLResponse)
        do {
            downloadResult = try await URLSession.shared.download(from: url)
        } catch {
            DiagnosticsLog.log("Store info [\(appID)]: \(suffix) art download failed - \(error.localizedDescription)")
            return nil
        }
        guard let http = downloadResult.response as? HTTPURLResponse, http.statusCode == 200 else {
            DiagnosticsLog.log("Store info [\(appID)]: \(suffix) art request returned a bad HTTP status")
            return nil
        }
        try? FileManager.default.removeItem(atPath: destination)
        guard (try? FileManager.default.moveItem(at: downloadResult.url, to: URL(fileURLWithPath: destination))) != nil else {
            DiagnosticsLog.log("Store info [\(appID)]: couldn't move downloaded \(suffix) art into place")
            return nil
        }
        return destination
    }

    private func metadataPath(for appID: String) -> String {
        (cacheDir as NSString).appendingPathComponent("\(appID).json")
    }

    private func readFromDisk(_ appID: String) -> SteamStoreInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath(for: appID))) else { return nil }
        return try? JSONDecoder().decode(SteamStoreInfo.self, from: data)
    }

    private func writeToDisk(_ appID: String, _ info: SteamStoreInfo) {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: URL(fileURLWithPath: metadataPath(for: appID)))
    }
}
