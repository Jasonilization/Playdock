import Foundation

/// One item in the unified games grid - either a Steam game or a manually-imported custom game.
/// Keeps `GameModeView`'s grid, search, sort, and controller-focus logic working uniformly across
/// both kinds without either one needing to know about the other's concrete type.
enum LibraryEntry: Identifiable, Equatable {
    case steam(SteamGame)
    case custom(CustomGame)

    var id: String {
        switch self {
        case .steam(let game): return game.appID
        case .custom(let game): return game.id
        }
    }

    var name: String {
        switch self {
        case .steam(let game): return game.name
        case .custom(let game): return game.effectiveName
        }
    }

    /// Used for the "Recently Updated" sort - Steam's own last-update timestamp for Steam games
    /// (missing for a handful of older manifests, hence the `.distantPast` fallback), the date a
    /// custom game was added for custom ones - the closest analogous "when did this change" signal
    /// each kind actually has.
    var sortDate: Date {
        switch self {
        case .steam(let game): return game.lastUpdated ?? .distantPast
        case .custom(let game): return game.addedAt
        }
    }

    /// Used for the "Recently Added" sort. Steam's manifests carry no install date, so the
    /// closest real ground truth is the install folder's own filesystem creation date (the moment
    /// Steam finished downloading into it); a custom game simply reports its imported date.
    var addedDate: Date {
        switch self {
        case .steam(let game): return Self.creationDate(ofFolder: game.installFolderPath) ?? .distantPast
        case .custom(let game): return game.addedAt
        }
    }

    /// Folder-creation lookups get memoized so a sort's O(n log n) comparisons don't re-stat the
    /// same paths dozens of times over.
    private static var creationDateCache: [String: Date?] = [:]

    private static func creationDate(ofFolder path: String) -> Date? {
        if let cached = creationDateCache[path] { return cached }
        let result = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        creationDateCache[path] = result
        return result
    }
}
