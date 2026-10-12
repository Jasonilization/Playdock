import Foundation

/// JSON-on-disk CRUD for custom (manually-imported) games - same pattern as
/// `GameSettingsStore`/`CompatibilityCache`. Stores only the `CustomGame` records themselves
/// (metadata, the exe path as a reference); never touches the actual game files. Every write is
/// atomic, and the storage path is injectable so the full CRUD surface is unit-testable.
enum CustomGameStore {
    static let path = ("~/Library/Application Support/ExeDock/CustomGames.json" as NSString).expandingTildeInPath

    static func loadAll(from path: String = CustomGameStore.path) -> [CustomGame] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([CustomGame].self, from: data)) ?? []
    }

    static func add(_ game: CustomGame, to path: String = CustomGameStore.path) {
        var games = loadAll(from: path)
        games.append(game)
        save(games, to: path)
    }

    static func update(_ game: CustomGame, to path: String = CustomGameStore.path) {
        var games = loadAll(from: path)
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index] = game
        save(games, to: path)
    }

    /// Only removes the library record - the referenced exe/folder on disk is never touched.
    static func remove(id: String, at path: String = CustomGameStore.path) {
        var games = loadAll(from: path)
        games.removeAll { $0.id == id }
        save(games, to: path)
    }

    /// Atomic on purpose: this is the one store whose contents can't be re-derived by rescanning
    /// anything, and a plain write can leave a truncated file behind if the app dies mid-save -
    /// a half-written file then fails decode on the next launch, silently wiping every imported
    /// game. A failed save is logged rather than swallowed for the same reason.
    static func save(_ games: [CustomGame], to path: String = CustomGameStore.path) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(games) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            DiagnosticsLog.log("CustomGameStore: couldn't save \(games.count) game(s) - \(error.localizedDescription)")
        }
    }
}
