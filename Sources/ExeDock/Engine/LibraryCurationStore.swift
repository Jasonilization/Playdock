import Foundation

/// Two tiny persistent sets - "favorited" and "hidden" - keyed by the same id the dashboard uses
/// everywhere (`SteamGame.appID` / `CustomGame.id`). One file because they're the same *kind* of
/// state (per-game user curation), needed atomically by the same UI, and separate because they'd
/// otherwise end up inconsistently implemented per surface - the exact thing that created the
/// badge mess the queue's first ten upgrades cleaned up.
@MainActor
final class LibraryCurationStore: ObservableObject {
    static let shared = LibraryCurationStore()

    static let defaultPath =
        ("~/Library/Application Support/ExeDock/LibraryCuration.json" as NSString).expandingTildeInPath

    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var hidden: Set<String> = []

    @Published private(set) var hiddenTimestamps: [String: Date] = [:]

    private let path: String

    init(path: String = LibraryCurationStore.defaultPath) {
        self.path = path
        reload()
    }

    struct OnDisk: Codable {
        var favorites: [String]
        var hidden: [String]
        var hiddenTimestamps: [String: Date]
    }

    func reload() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let disk = try? JSONDecoder().decode(OnDisk.self, from: data) else { return }
        favorites = Set(disk.favorites)
        hidden = Set(disk.hidden)
        hiddenTimestamps = disk.hiddenTimestamps
    }

    private func save() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let disk = OnDisk(favorites: favorites.sorted(), hidden: hidden.sorted(), hiddenTimestamps: hiddenTimestamps)
        if let data = try? JSONEncoder().encode(disk) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }
    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        save()
    }

    /// Hiding preserves every other record (sessions, outcomes, configs) untouched - it's purely
    /// a visibility flip the user can undo from Settings.
    func hide(_ id: String) {
        hidden.insert(id)
        hiddenTimestamps[id] = Date()
        save()
    }

    func unhide(_ id: String) {
        hidden.remove(id)
        hiddenTimestamps.removeValue(forKey: id)
        save()
    }
}
