import AppKit
import Foundation

struct RunningProcessInfo: Equatable {
    let pid: Int32
    let startedAt: Date
}

/// Best-effort detection of whether a specific Steam game's process is actually running right now,
/// and since when - Playdock has no real Wine/Steam IPC hook into a game Steam itself launched, so
/// this greps `ps` for a command line containing the game's own install-dir fragment. Windows
/// processes running under Wine show their full Windows command line in `ps` output - confirmed
/// live earlier this session (ordinary `ps aux` lines like
/// `C:\Program Files (x86)\Steam\bin\cef\...\steamwebhelper.exe`) - so this is real, not
/// theoretical, but it's still a heuristic: two games sharing an install-dir fragment could
/// collide, and a game launched under an unexpected child-process name won't be seen.
///
/// One shared poller (not four separate ones) backs the live game-card status, the launch
/// overlay's dismiss trigger, dashboard theming, and Inspect mode. `syncWatchedGames` is called
/// once from the dashboard with whatever's currently in `model.steamGames`, so this only polls
/// while there's actually something worth watching (nothing running while Game Mode is locked, or
/// before the library has loaded).
@MainActor
final class RunningGameTracker: ObservableObject {
    static let shared = RunningGameTracker()

    @Published private(set) var runningGames: [String: RunningProcessInfo] = [:]

    private var pollTask: Task<Void, Never>?
    private var watchedGames: [String: String] = [:] // id -> matchFragment
    private var knownStartTimes: [String: Date] = [:]

    private init() {
        // A quit mid-session is still a real session: if the app is terminating while a game is
        // running, record what we know (start = first seen, end = now) rather than dropping the
        // whole session on the floor.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flushOpenSessions() }
        }
    }

    /// Writes one `PlayActivityStore` record for every game currently tracked as running. Called
    /// when a watched game disappears from `ps`, and once from the will-terminate observer.
    private func flushOpenSessions(only endedIDs: Set<String>? = nil) {
        for (id, info) in runningGames where endedIDs?.contains(id) ?? true {
            PlayActivityStore.shared.record(gameID: id, started: info.startedAt, ended: Date())
        }
    }

    /// Replaces the full watch list - call with every library item currently on the dashboard
    /// (Steam and custom games alike). `id` is whatever that item is keyed by elsewhere
    /// (`SteamGame.appID` / `CustomGame.id`); `matchFragment` is the path text `findRunningPIDs`
    /// looks for in each process's command line, tried with both `/` and `\` separators - Steam
    /// call sites pass `"steamapps/common/<installDir>"` (identical to this tracker's previous,
    /// Steam-only behavior), custom games pass their exe's own containing folder name, since they
    /// aren't necessarily installed anywhere near a `steamapps` folder at all. Games no longer
    /// present are dropped from `runningGames` immediately rather than waiting for the next poll.
    func syncWatchedGames(_ items: [(id: String, matchFragment: String)]) {
        let newWatch = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.matchFragment) })
        watchedGames = newWatch
        runningGames = runningGames.filter { newWatch[$0.key] != nil }
        knownStartTimes = knownStartTimes.filter { newWatch[$0.key] != nil }

        if watchedGames.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        } else {
            ensurePolling()
        }
    }

    /// Convenience for the common Steam-only case (still used wherever custom games aren't in play
    /// yet) - identical behavior to calling `syncWatchedGames` with each game's own
    /// `steamapps/common/<installDir>` fragment.
    func syncWatchedGames(_ games: [SteamGame]) {
        syncWatchedGames(games.map { (id: $0.appID, matchFragment: "steamapps/common/\($0.installDir)") })
    }

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func pollOnce() async {
        let targets = watchedGames
        guard !targets.isEmpty else { return }
        let matches = await Task.detached(priority: .utility) {
            Self.findRunningPIDs(for: targets)
        }.value
        guard !Task.isCancelled else { return }

        var ended: Set<String> = []
        for (id, _) in targets {
            if let pid = matches[id] {
                let startedAt = knownStartTimes[id] ?? Date()
                knownStartTimes[id] = startedAt
                runningGames[id] = RunningProcessInfo(pid: pid, startedAt: startedAt)
            } else {
                if runningGames[id] != nil { ended.insert(id) }
                runningGames.removeValue(forKey: id)
                knownStartTimes.removeValue(forKey: id)
            }
        }
        if !ended.isEmpty { flushOpenSessions(only: ended) }
    }

    /// Off the main actor: shells out to `ps`, same pattern `ExeRunner`/`SikarugirEngine` already
    /// use for `tar`/`cp`. Each `matchFragment` (e.g. "steamapps/common/Hollow Knight" for a Steam
    /// game, or an exe's own filename stem like "Dreamcore-Win64-Shipping" for a custom game) is
    /// checked three ways: with both path separators (Wine's own command lines can show either,
    /// depending on how the path was passed through) *and* as a bare substring with no separator
    /// required at all - needed for a plain filename fragment, which sits at the very end of a path
    /// followed by ".exe", not a directory separator.
    nonisolated private static func findRunningPIDs(for targets: [String: String]) -> [String: Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var results: [String: Int32] = [:]
        for (id, matchFragment) in targets {
            let backslashFragment = (matchFragment.replacingOccurrences(of: "/", with: "\\") + "\\").lowercased()
            let slashFragment = (matchFragment + "/").lowercased()
            let bareFragment = matchFragment.lowercased()
            guard let line = lines.first(where: {
                let lower = $0.lowercased()
                return lower.contains(backslashFragment) || lower.contains(slashFragment) || lower.contains(bareFragment)
            }) else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[trimmed.startIndex..<spaceIndex]) else { continue }
            results[id] = pid
        }
        return results
    }
}
