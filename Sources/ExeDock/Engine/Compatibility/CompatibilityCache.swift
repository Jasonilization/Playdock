import Foundation

/// Disk cache for a game's aggregated compatibility recommendation, keyed by appID - same
/// JSON-on-disk pattern as `GameSettingsStore`/`SteamStoreInfoCache`. Never hit automatically on a
/// timer; only read on open, written after a fetch, and bypassed by an explicit Refresh.
enum CompatibilityCache {
    private static var cacheDir: String { SikarugirEngine.supportFile("CompatibilityCache") }

    static func load(appID: String) -> CompatibilityRecommendation? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path(for: appID))) else { return nil }
        return try? JSONDecoder().decode(CompatibilityRecommendation.self, from: data)
    }

    static func save(_ recommendation: CompatibilityRecommendation, appID: String) {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(recommendation) else { return }
        try? data.write(to: URL(fileURLWithPath: path(for: appID)))
    }

    private static func path(for appID: String) -> String {
        (cacheDir as NSString).appendingPathComponent("\(appID).json")
    }
}
