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
        // A miss is not cached. Steam being down once should not make Refresh a no-op forever.
        if let fetched {
            memoryCache[appID] = fetched
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
        // Wide art, best first. A lot of games have no library hero, so the capsule and then
        // the store header are the fallbacks. The first file that actually downloads wins.
        let libraryHeroPath = await firstImage(appID: appID, suffix: "library-hero", urls: [
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero_2x.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero.jpg",
            "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_hero.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/capsule_616x353.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg",
        ])
        let portraitPath = await firstImage(appID: appID, suffix: "portrait", urls: [
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900_2x.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg",
            "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900.jpg",
        ])
        let logoPath = await firstImage(appID: appID, suffix: "logo", urls: [
            "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/logo.png",
            "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(appID)/logo.png",
        ])
        var backgroundImagePath: String?
        if let backgroundURLString = appData["background_raw"] as? String ?? appData["background"] as? String,
           let backgroundURL = URL(string: backgroundURLString) {
            backgroundImagePath = await downloadImage(backgroundURL, appID: appID, suffix: "background")
        }

        // Thumbnails only, and only the first handful - a screenshot strip doesn't need the whole
        // gallery (some games ship dozens), and full-resolution shots aren't worth the bandwidth for
        // what's still just a supporting visual, not the main event.
        var screenshotPaths: [String] = []
        var screenshotFullImageURLs: [String] = []
        let screenshots = (appData["screenshots"] as? [[String: Any]]) ?? []
        for (index, screenshot) in screenshots.prefix(4).enumerated() {
            let fullString = screenshot["path_full"] as? String
            let thumbString = screenshot["path_thumbnail"] as? String
            guard let chosen = fullString ?? thumbString, let imageURL = URL(string: chosen) else { continue }
            screenshotFullImageURLs.append(fullString ?? chosen)
            if let path = await downloadImage(imageURL, appID: appID, suffix: "screenshot-\(index)") {
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
        let achievementBlock = appData["achievements"] as? [String: Any]
        let achievementTotal = achievementBlock?["total"] as? Int
        var highlighted: [SteamAchievementHighlight] = []
        let highlightedRaw = (achievementBlock?["highlighted"] as? [[String: Any]]) ?? []
        for (index, item) in highlightedRaw.prefix(8).enumerated() {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            var iconPath: String?
            if let icon = item["path"] as? String, let iconURL = URL(string: icon) {
                iconPath = await downloadImage(iconURL, appID: appID, suffix: "achievement-\(index)")
            }
            highlighted.append(SteamAchievementHighlight(name: name, iconPath: iconPath))
        }
        let reviews = await reviewSummary(appID: appID)

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
            libraryHeroPath: libraryHeroPath,
            portraitPath: portraitPath,
            logoPath: logoPath,
            backgroundImagePath: backgroundImagePath,
            screenshotPaths: screenshotPaths,
            genres: genres,
            releaseDate: releaseDate,
            developers: developers,
            publishers: publishers,
            metacriticScore: metacriticScore,
            metacriticURL: metacriticURL,
            categories: categories,
            screenshotFullImageURLs: screenshotFullImageURLs,
            reviewSummary: reviews?.summary,
            reviewPercent: reviews?.percent,
            reviewCount: reviews?.count,
            achievementTotal: achievementTotal,
            highlightedAchievements: highlighted
        )
    }

    /// Steam's review words ("Very Positive") are not in appdetails. They come from the public
    /// review summary, which also has the positive count used for the percent.
    private func reviewSummary(appID: String) async -> (summary: String, percent: Int, count: Int)? {
        guard let url = URL(string: "https://store.steampowered.com/appreviews/\(appID)?json=1&language=all&purchase_type=all&num_per_page=0") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = json["query_summary"] as? [String: Any],
              let label = summary["review_score_desc"] as? String, !label.isEmpty,
              let total = summary["total_reviews"] as? Int, total > 0 else { return nil }
        let positive = summary["total_positive"] as? Int ?? 0
        let percent = Int((Double(positive) / Double(total) * 100).rounded())
        return (label, percent, total)
    }

    /// Tries each URL and keeps the first image that is actually a picture.
    private func firstImage(appID: String, suffix: String, urls: [String]) async -> String? {
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            if let path = await downloadImage(url, appID: appID, suffix: suffix) { return path }
        }
        return nil
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
        let rawSize = try? FileManager.default.attributesOfItem(atPath: destination)[.size]
        let byteCount = (rawSize as? NSNumber)?.intValue ?? 0
        if byteCount < 2048 {
            try? FileManager.default.removeItem(atPath: destination)
            return nil
        }
        return destination
    }

    private func metadataPath(for appID: String) -> String {
        (cacheDir as NSString).appendingPathComponent("\(appID).json")
    }

    /// What's already cached for this app (memory or disk), WITHOUT any network. Powers the
    /// "More like this" rail: it must never wake 40 fresh fetches just to decorate one page.
    /// Stale entries still count as cached here - a genre is a genre.
    func cachedSnapshot(for appID: String) -> SteamStoreInfo? {
        if let cached = memoryCache[appID] { return cached }
        if let info = readFromDisk(appID) {
            memoryCache[appID] = info
            return info
        }
        return nil
    }

    private func readFromDisk(_ appID: String) -> SteamStoreInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath(for: appID))) else { return nil }
        return try? JSONDecoder().decode(SteamStoreInfo.self, from: data)
    }

    private func writeToDisk(_ appID: String, _ info: SteamStoreInfo) {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(info) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: metadataPath(for: appID)), options: .atomic)
        } catch {
            // Only a cache (a failed write just means a refetch), but a truncated file would
            // have failed decode on read and looked identical to "no cache" - log the real story.
            DiagnosticsLog.log("SteamStoreInfoCache: couldn't cache info for \(appID) - \(error.localizedDescription)")
        }
    }
}
