import Foundation

/// "Hard Refresh Game Info" (Settings → Games & Data). Wipes every copy of downloadable game
/// metadata Playdock manages itself - the short description, header/background/screenshot art, and
/// the aggregated compatibility recommendation - both on disk and in memory, so the next time a
/// card or detail view asks for a game's info it goes all the way back to Steam's public store API
/// for a fresh copy.
///
/// Deliberately does **not** touch `~/Library/Application Support/Steam/appcache/librarycache/`.
/// That's the real Steam client's own cache - Playdock only ever reads it (`SteamLibraryCache`,
/// live, off disk each call), never wrote it, and deleting another app's cache to fix a display
/// glitch in this one would be the wrong trade. Steam repopulates its own art on its own schedule;
/// this refresh just re-reads whatever's there.
enum GameInfoCacheReset {
    private static var appSupport: String {
        ("~/Library/Application Support/ExeDock" as NSString).expandingTildeInPath
    }

    /// Downloaded store metadata + art (`SteamStoreInfoCache`'s own on-disk directory).
    static var storeInfoDir: String { (appSupport as NSString).appendingPathComponent("StoreInfoCache") }

    /// Aggregated per-game compatibility recommendations (`CompatibilityCache`'s own directory).
    static var compatibilityDir: String { (appSupport as NSString).appendingPathComponent("CompatibilityCache") }

    static func run() async {
        await SteamStoreInfoCache.shared.clearMemoryCache()
        LocalImageCache.clear()
        GameArtColor.clearCache()

        let fileManager = FileManager.default
        var removed = 0
        for directory in [storeInfoDir, compatibilityDir] where fileManager.fileExists(atPath: directory) {
            do {
                try fileManager.removeItem(atPath: directory)
                removed += 1
            } catch {
                DiagnosticsLog.log("Hard refresh: couldn't remove \(directory) - \(error.localizedDescription)")
            }
        }
        DiagnosticsLog.log("Hard refresh: cleared in-memory art/color caches and \(removed) on-disk cache folder(s)")
    }
}
