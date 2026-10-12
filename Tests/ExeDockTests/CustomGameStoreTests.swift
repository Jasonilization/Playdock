import Foundation
import Testing
@testable import ExeDock

/// Full CRUD round-trips for the one store whose contents can't be re-derived by rescanning
/// anything - plus the corrupt-file behavior that previously turned a truncated write into
/// silent, total data loss.
@Suite("CustomGameStore")
struct CustomGameStoreTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-game-store-tests-\(UUID().uuidString)/CustomGames.json").path
    }

    @Test func addUpdateRemoveRoundTrip() {
        let path = tempPath()

        var game = CustomGame(exePath: "/Games/Example/Game.exe")
        game.discovered.productName = "Example"
        CustomGameStore.add(game, to: path)
        #expect(CustomGameStore.loadAll(from: path).count == 1)

        game.overrides.name = "Renamed"
        CustomGameStore.update(game, to: path)
        let loaded = CustomGameStore.loadAll(from: path)
        #expect(loaded.count == 1)
        #expect(loaded.first?.effectiveName == "Renamed")
        #expect(loaded.first?.exePath == "/Games/Example/Game.exe")

        CustomGameStore.remove(id: game.id, at: path)
        #expect(CustomGameStore.loadAll(from: path).isEmpty)
    }

    @Test func updateOfUnknownIDIsANoOp() {
        let path = tempPath()
        let game = CustomGame(exePath: "/Games/Example/Game.exe")
        CustomGameStore.add(game, to: path)
        let stranger = CustomGame(exePath: "/Games/Other/Other.exe")
        CustomGameStore.update(stranger, to: path)
        #expect(CustomGameStore.loadAll(from: path).count == 1)
    }

    @Test func corruptFileYieldsEmptyRatherThanCrashing() {
        let path = tempPath()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A file truncated mid-write (the failure mode the atomic save now prevents) or
        // otherwise undecodable must degrade to "no games", never take the app down.
        FileManager.default.createFile(atPath: path, contents: Data("[{\"id\": \"1".utf8))
        #expect(CustomGameStore.loadAll(from: path).isEmpty)
    }
}
