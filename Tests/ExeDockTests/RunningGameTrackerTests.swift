import Foundation
import Testing
@testable import ExeDock

/// Guards the watch-list entry point against a library quirk that used to be a hard crash:
/// the same game installed in two Steam library folders yields two manifests with the same
/// appid, and the old `Dictionary(uniqueKeysWithValues:)` trapped on that.
@Suite("RunningGameTracker")
struct RunningGameTrackerTests {
    @Test @MainActor func duplicateWatchedIDsKeepFirstFragmentInsteadOfCrashing() {
        let tracker = RunningGameTracker.shared
        let fragment = "steamapps/common/Half-Life 2"
        let items: [(id: String, matchFragment: String)] = [
            (id: "220", matchFragment: fragment),
            (id: "220", matchFragment: fragment), // same appid from a second library folder
        ]
        tracker.syncWatchedGames(items)
        // Clearing the watch list also cancels the poller this test briefly started, leaving
        // the shared singleton exactly as it was found.
        let clear: [(id: String, matchFragment: String)] = []
        tracker.syncWatchedGames(clear)
        #expect(tracker.runningGames.isEmpty)
    }
}
