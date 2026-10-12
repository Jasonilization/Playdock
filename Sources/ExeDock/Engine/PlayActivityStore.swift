import Foundation

/// One contiguous play session, as observed by `RunningGameTracker` (a game process appeared at
/// `startedAt` and was gone again by `endedAt`). Deliberately just three fields - anything fancier
/// (notes, idle detection) can be derived later from a v1 file without a migration.
struct PlaySession: Codable, Equatable {
    /// The same key the rest of the dashboard uses: `SteamGame.appID` for Steam games,
    /// `CustomGame.id` for manually-imported ones. Names would break on a rename; ids don't.
    let gameID: String
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// Local, ground-truth answer to "how much have I actually played this, and when last" - the one
/// stat every.launcher.leads.with (Steam's Playtime, Playnite's Play Time) that Playdock had no
/// answer for at all (`SkinWebGridEntry.hours` literally shipped `nil` for every card). No Steam
/// API key, no network: `RunningGameTracker` already observes every running game process; this
/// just writes down what it sees. The honest limitation lives in the polling itself (see the
/// tracker's own doc comment) and is why sessions shorter than `minimumDuration` are ignored -
/// a one-cycle ps flicker must not become "you played for 4 seconds".
@MainActor
final class PlayActivityStore: ObservableObject {
    static let shared = PlayActivityStore()

    /// Same support folder convention `LocalOutcomeTracker` already uses. `nonisolated` because
    /// it is read as an init default argument, which is evaluated in the caller's isolation -
    /// a pure path constant needs no MainActor guarantee (and under Swift 6 the isolated form
    /// would be a hard error from every nonisolated caller).
    nonisolated static let defaultPath =
        ("~/Library/Application Support/ExeDock/PlayActivity.json" as NSString).expandingTildeInPath

    /// Sessions under 30s are process noise (the 5s poll can double-count a fast exit/re-check
    /// flicker), not play. Long real sessions are never affected; nothing else is heuristically
    /// trimmed anywhere - the raw record stays trustworthy.
    static let minimumDuration: TimeInterval = 30

    @Published private(set) var sessions: [PlaySession] = []

    private let path: String

    init(path: String = PlayActivityStore.defaultPath) {
        self.path = path
        reload()
    }

    /// Append one completed session. Called by `RunningGameTracker` at the moment a watched game
    /// stops appearing in `ps`. Fine to call for a game that was never watched long - filtering on
    /// `minimumDuration` means recordNothingInteresting stays cheap.
    func record(gameID: String, started: Date, ended: Date) {
        guard ended.timeIntervalSince(started) >= Self.minimumDuration else { return }
        sessions.append(PlaySession(gameID: gameID, startedAt: started, endedAt: ended))
        save()
    }

    // MARK: - Queries (raw - presentation formatting belongs to callers, skins included)

    func totalSeconds(for gameID: String) -> TimeInterval {
        sessions.filter { $0.gameID == gameID }.reduce(0) { $0 + $1.duration }
    }

    func sessionCount(for gameID: String) -> Int {
        sessions.count { $0.gameID == gameID }
    }

    func lastPlayed(_ gameID: String) -> Date? {
        sessions.filter { $0.gameID == gameID }.map(\.endedAt).max()
    }

    /// Every game with at least one real recorded session, for "did anything get recorded"
    /// checks in settings/diagnostics.
    var recordedGameIDs: Set<String> { Set(sessions.map(\.gameID)) }

    // MARK: - persistence

    func reload() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        sessions = (try? JSONDecoder().decode([PlaySession].self, from: data)) ?? []
    }

    private func save() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
