import Foundation
import Testing
@testable import ExeDock

@Suite("LibraryCurationStore")
struct LibraryCurationStoreTests {
    @MainActor
    private func makeStore() -> LibraryCurationStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("curation-tests-\(UUID().uuidString)")
        return LibraryCurationStore(path: dir.appendingPathComponent("LibraryCuration.json").path)
    }

    @Test @MainActor func favoriteTogglesRoundtrip() async {
        let store = makeStore()
        #expect(!store.isFavorite("g"))
        store.toggleFavorite("g")
        #expect(store.isFavorite("g"))
        store.toggleFavorite("g")
        #expect(!store.isFavorite("g"))
    }

    @Test @MainActor func hidePreservesFavorites() async {
        let store = makeStore()
        store.toggleFavorite("g")
        store.hide("g")
        #expect(store.isHidden("g"))
        #expect(store.isFavorite("g"))
        store.unhide("g")
        #expect(!store.isHidden("g"))
        #expect(store.isFavorite("g"))
    }

    @Test @MainActor func persistsAcrossInstances() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("curation-tests-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("LibraryCuration.json").path
        await MainActor.run {
            let a = LibraryCurationStore(path: path)
            a.toggleFavorite("g")
            a.hide("h")
        }
        let b = await MainActor.run { LibraryCurationStore(path: path) }
        #expect(b.isFavorite("g"))
        #expect(b.isHidden("h"))
    }
}
