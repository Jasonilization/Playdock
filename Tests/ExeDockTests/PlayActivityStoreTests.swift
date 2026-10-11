import Foundation
import Testing
@testable import ExeDock

@Suite("PlayActivityStore")
struct PlayActivityStoreTests {
    @MainActor
    private func makeStore() -> PlayActivityStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-activity-tests-\(UUID().uuidString)")
        return PlayActivityStore(path: dir.appendingPathComponent("PlayActivity.json").path)
    }

    @Test @MainActor func recordsAndAggregates() async {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(gameID: "413150", started: t0, ended: t0.addingTimeInterval(3600))
        store.record(gameID: "413150", started: t0 + 100_000, ended: t0 + 100_000 + 1800)
        store.record(gameID: "105600", started: t0, ended: t0.addingTimeInterval(600))

        #expect(store.sessionCount(for: "413150") == 2)
        #expect(store.totalSeconds(for: "413150") == 5400)
        #expect(store.totalSeconds(for: "105600") == 600)
        #expect(store.sessionCount(for: "never-played") == 0)
        #expect(store.lastPlayed("never-played") == nil)
    }

    @Test @MainActor func subMinimumSessionsAreIgnored() async {
        let store = makeStore()
        let t0 = Date()
        store.record(gameID: "x", started: t0, ended: t0.addingTimeInterval(5))
        #expect(store.sessionCount(for: "x") == 0)
    }

    @Test @MainActor func persistsAcrossInstances() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-activity-tests-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("PlayActivity.json").path
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await MainActor.run {
            let a = PlayActivityStore(path: path)
            a.record(gameID: "g", started: t0, ended: t0.addingTimeInterval(120))
        }
        let b = await MainActor.run { PlayActivityStore(path: path) }
        #expect(b.sessionCount(for: "g") == 1)
    }
}
