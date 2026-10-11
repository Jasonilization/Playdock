import Foundation
import AppKit

@MainActor
final class AppModel: ObservableObject {
    enum SidebarSection: Hashable, CaseIterable {
        case gameMode
        case cDrive
    }

    enum SteamStatus: Equatable {
        case notInstalled
        case installing(String)
        case installed
        case failed(String)
    }

    /// What (if anything) is currently being launched - tracked per-target rather than one blanket
    /// flag so only the control someone actually clicked shows a spinner, not every game card at once.
    enum LaunchTarget: Equatable {
        case steam
        case game(String)
        case custom(String)
    }

    @Published var detectedApps: [DetectedApp] = []
    @Published var bottles: [Bottle] = []
    // Steam-first: gamers land straight on the dashboard, not a generic file browser.
    @Published var selectedSection: SidebarSection = .gameMode
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var steamStatus: SteamStatus = .notInstalled
    // didSet (not a separate save call) so every mutation persists automatically, including direct
    // bindings from the settings UI ($model.gameModeConfig.dxvk, etc.) - not just `setOverride`.
    @Published var gameModeConfig = GameModeConfig() { didSet { persistGameSettings() } }
    @Published var perGameConfigs: [String: GameModeConfig] = [:] { didSet { persistGameSettings() } }
    @Published var isGameModeUnlocked = false
    @Published var steamGames: [SteamGame] = []
    @Published var isLoadingSteamGames = false
    @Published var steamProfile: SteamProfile?
    /// Manually-imported games (see `CustomGameStore`) - loaded once at startup, kept in sync with
    /// disk by the add/update/remove methods below rather than a blanket `didSet` save, since
    /// `CustomGameStore`'s own API is per-record CRUD, not "rewrite everything every mutation."
    @Published var customGames: [CustomGame] = []
    /// Non-nil while a Steam/game launch is in flight - drives the spinner on whichever control
    /// started it, and blocks a second launch from starting until this clears (see `launchSteam`).
    @Published var launchingTarget: LaunchTarget?
    /// Debug-only: appends a handful of real, well-known games (with real appIDs, so their genuine
    /// Steam art/rating/description come through the normal metadata pipeline) so the grid's layout
    /// - especially the dynamic card sizing - can be checked with more than whatever's actually
    /// installed. Purely additive to `steamGames`; never written to disk, never touches the real
    /// Steam library, and toggling it off removes every sample entry immediately.
    @Published private(set) var isPreviewingSampleGames = false

    var isInstallingSteam: Bool {
        if case .installing = steamStatus { return true }
        return false
    }

    // Deliberately does nothing but set defaults above. Mutating @Published properties from inside
    // an ObservableObject's own init() (which SwiftUI can invoke mid-render for a @StateObject) is a
    // known trigger for "Publishing changes from within view updates is not allowed" - real symptoms
    // observed here included whole panes of the UI going blank. All initial loading instead happens
    // in `onSetupReady()`, called from an `.onChange`/`.onAppear`, safely outside any view's body.
    init() {}

    /// Called once launch-time setup finishes (see `SetupCoordinator`) - safe to publish freely here.
    func onSetupReady() {
        isGameModeUnlocked = SteamInstaller.isSteamInstalled
        if isGameModeUnlocked { steamStatus = .installed }
        let saved = GameSettingsStore.load()
        gameModeConfig = saved.defaults
        perGameConfigs = saved.perGame
        refreshBottlesAndApps()
        refreshSteamGames()
        refreshSteamProfile()
        customGames = CustomGameStore.loadAll()
        observeAppActivation()
    }

    /// Re-scans everything worth re-scanning whenever Playdock comes back to the foreground. A
    /// one-shot scan at launch alone means
    /// installing a Steam game (real or Mac-native), removing a wrapper app, or anything else that
    /// changes on disk while Playdock sits in the background never shows up without a full relaunch.
    /// Registered once; safe to call repeatedly since every refresh method it calls already is.
    private func observeAppActivation() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBottlesAndApps()
                self?.refreshSteamGames()
            }
        }
    }

    func refreshBottlesAndApps() {
        let knownBottles = CDriveScanner.allKnownBottles()
        bottles = knownBottles
        detectedApps = knownBottles.flatMap(CDriveScanner.scan)
    }

    /// Merges ExeDock's own Windows Steam bottle (gated on `isGameModeUnlocked`, since that
    /// reflects whether ExeDock has actually set that bottle up yet) with whatever's installed
    /// through the real, separate macOS Steam client - which isn't gated on that at all, since it's
    /// a completely different Steam install ExeDock doesn't manage or need to unlock anything for.
    func refreshSteamGames() {
        let scanWineBottle = isGameModeUnlocked
        isLoadingSteamGames = true
        Task.detached(priority: .utility) { [weak self] in
            let wineGames = scanWineBottle ? SteamLibrary.installedGames() : []
            let nativeGames = SteamLibrary.installedNativeMacGames()
            let games = wineGames + nativeGames
            await MainActor.run { [weak self] in
                self?.steamGames = games
                self?.isLoadingSteamGames = false
            }
        }
    }

    func refreshSteamProfile() {
        guard isGameModeUnlocked else {
            steamProfile = nil
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let profile = SteamProfileReader.currentProfile()
            await MainActor.run { [weak self] in self?.steamProfile = profile }
        }
    }

    // MARK: - Hard refresh of downloadable game info

    /// True only while `hardRefreshGameInfo()` is doing its cache wipe - drives the Settings
    /// button's spinner and keeps a second tap from stacking.
    @Published private(set) var isHardRefreshingGameInfo = false

    /// Bumped every time a hard refresh finishes. Views that cache a game's resolved art/
    /// description in their own `@State` (keyed on the entry id, which a plain `refreshSteamGames()`
    /// never invalidates) watch this and re-resolve from scratch when it changes.
    @Published private(set) var gameInfoGeneration = 0

    private static let lastHardRefreshKey = "com.exedock.lastGameInfoRefresh"

    /// When "Hard Refresh Game Info" was last run, or `nil` if never - shown in Settings so the
    /// action doesn't feel like it did nothing.
    var lastGameInfoRefresh: Date? {
        let stamp = UserDefaults.standard.double(forKey: Self.lastHardRefreshKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Clears every copy of downloadable game metadata Playdock caches itself (`GameInfoCacheReset`)
    /// and then re-scans the library, so every card and detail view re-fetches art/description/
    /// details straight from Steam. For when a game is showing the wrong art, stale art, or none.
    func hardRefreshGameInfo() {
        guard !isHardRefreshingGameInfo else { return }
        isHardRefreshingGameInfo = true
        Task {
            await GameInfoCacheReset.run()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastHardRefreshKey)
            isHardRefreshingGameInfo = false
            gameInfoGeneration += 1
            refreshSteamGames()
            refreshSteamProfile()
        }
    }

    /// Settings that actually apply to a given library item - its own override if it has one,
    /// otherwise the shared default. Advanced Mode is the only place a user can create an override.
    /// Keyed by plain `id` so the exact same storage/lookup works for both Steam games (appID) and
    /// custom games (their own generated id) - see the `SteamGame`/`CustomGame` overloads below.
    func config(forID id: String) -> GameModeConfig {
        perGameConfigs[id] ?? gameModeConfig
    }

    func setOverride(_ config: GameModeConfig?, forID id: String) {
        perGameConfigs[id] = config
    }

    func config(for game: SteamGame) -> GameModeConfig { config(forID: game.appID) }
    func setOverride(_ config: GameModeConfig?, for game: SteamGame) { setOverride(config, forID: game.appID) }

    func config(for game: CustomGame) -> GameModeConfig { config(forID: game.id) }
    func setOverride(_ config: GameModeConfig?, for game: CustomGame) { setOverride(config, forID: game.id) }

    private func persistGameSettings() {
        GameSettingsStore.save(defaults: gameModeConfig, perGame: perGameConfigs)
    }

    func run(exePath: String, bottle: Bottle, arguments: [String] = [], displayName: String? = nil) {
        let config = gameModeConfig
        let name = displayName ?? (exePath as NSString).lastPathComponent
        statusMessage = "Launching \(name)…"
        // A bottle that isn't initialized yet can take a while (wineboot + a grace period for its
        // background helper processes to finish) - never do that on the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await ExeRunner.run(exePath: exePath, in: bottle, arguments: arguments, config: config)
                await MainActor.run { [weak self] in self?.statusMessage = "Launched \(name)" }
            } catch {
                await MainActor.run { [weak self] in self?.errorMessage = error.localizedDescription }
            }
        }
    }

    /// Games are always started through Steam itself (`-applaunch <appid>`) rather than by running
    /// their executable directly - see `SteamGame.iconExePath` for why. Uses that game's own
    /// settings override if it has one.
    func launchSteamGame(_ game: SteamGame) {
        if game.source == .nativeMac {
            launchNativeMacSteamGame(game)
            return
        }
        launchSteamGame(game, using: config(for: game))
    }

    /// Same launch, but with a specific config rather than the game's saved override - used by the
    /// Experiment wizard to try a variant without touching the player's actual saved settings. Only
    /// meaningful for a `wineBottle` game - the Experiment wizard has no reason to ever be pointed
    /// at a `nativeMac` one, which has no ExeDock-managed config to experiment with in the first
    /// place.
    func launchSteamGame(_ game: SteamGame, using config: GameModeConfig) {
        guard ensureSteamStillInstalled() else { return }
        launchSteam(
            target: .game(game.appID), arguments: ["-applaunch", game.appID], displayName: game.name,
            config: config, recordOutcomeFor: game.appID
        )
    }

    /// Native macOS Steam games are launched by asking the *real*, already-installed macOS Steam
    /// client to run them directly - `steam://rungameid/<appid>` is Steam's own standard, documented
    /// URL scheme for this, handled entirely by that real Steam app (no Wine, no ExeRunner involved
    /// at all) - "make sure I can see my mac steam games and launch it here too, same way," per live
    /// feedback.
    private func launchNativeMacSteamGame(_ game: SteamGame) {
        guard let url = URL(string: "steam://rungameid/\(game.metadataAppID)") else { return }
        statusMessage = "Launching \(game.name)…"
        NSWorkspace.shared.open(url)
    }

    /// Opens the Steam client itself (no specific game) - e.g. to browse the store or install
    /// something new.
    func openSteamClient() {
        guard ensureSteamStillInstalled() else { return }
        launchSteam(target: .steam, arguments: [], displayName: "Steam", config: gameModeConfig)
    }

    /// Steam can vanish out from under ExeDock (uninstalled, a broken update) without anything else
    /// noticing, since nothing polls for it while the app just sits open. Re-check right before
    /// trying to launch it, and if it's gone, flip back to the locked state and kick off a reinstall
    /// automatically - `SteamInstaller.installAndLaunch` already knows to skip the download step if
    /// it turns out Steam actually is there after all.
    @discardableResult
    private func ensureSteamStillInstalled() -> Bool {
        guard SteamInstaller.isSteamInstalled else {
            isGameModeUnlocked = false
            steamStatus = .notInstalled
            errorMessage = "Steam isn't where ExeDock expected it anymore - reinstalling…"
            installAndRunSteam()
            return false
        }
        return true
    }

    /// A single, fire-and-forget launch - deliberately NOT retried. Steam.exe's own singleton
    /// behavior means a second invocation while Steam is already running (or still starting up) just
    /// messages the existing process and exits quickly, often with a non-zero status - that's normal,
    /// not a failure, and retrying with different settings on that signal previously caused ExeDock
    /// to launch a second, competing Steam process on top of a first one that was still legitimately
    /// starting up (confirmed in ~/Library/Logs/ExeDock: two full Steam startups five seconds apart).
    /// The `guard` below is a second line of defense against that - it ignores a launch request while
    /// one is already in flight, on top of the UI disabling launch buttons for the same reason.
    private func launchSteam(target: LaunchTarget, arguments: [String], displayName: String, config: GameModeConfig, recordOutcomeFor appID: String? = nil) {
        guard launchingTarget == nil else { return }
        launchingTarget = target
        statusMessage = "Launching \(displayName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await ExeRunner.run(
                    exePath: SteamInstaller.installedSteamExePath, in: SteamInstaller.steamBottle,
                    arguments: arguments, config: config
                )
                await MainActor.run { [weak self] in self?.statusMessage = "Launched \(displayName)" }
                if let appID { LocalOutcomeTracker.record(appID: appID, config: config, launchErrored: false) }
            } catch {
                await MainActor.run { [weak self] in self?.errorMessage = error.localizedDescription }
                if let appID { LocalOutcomeTracker.record(appID: appID, config: config, launchErrored: true) }
            }
            // Steam's own window can take a while to appear even after the process starts (first
            // launch, or a self-update - real startups seen taking 10+ seconds) - keep the "in
            // progress" indicator up for a bit so it doesn't flash by before anyone notices it.
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run { [weak self] in self?.launchingTarget = nil }
        }
    }

    func runDroppedFile(at path: String) {
        guard path.lowercased().hasSuffix(".exe") else {
            errorMessage = "ExeDock only runs .exe files."
            return
        }
        run(exePath: path, bottle: BottleManager.shared.defaultBottle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshBottlesAndApps()
        }
    }

    func installAndRunSteam() {
        guard !isInstallingSteam else { return }
        steamStatus = .installing("Starting…")
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await SteamInstaller.installAndLaunch { [self] message in
                    Task { @MainActor in self.steamStatus = .installing(message) }
                }
                self.steamStatus = .installed
                self.isGameModeUnlocked = true
                self.selectedSection = .gameMode
                self.openSteamClient()
                self.refreshBottlesAndApps()
                self.refreshSteamGames()
                self.refreshSteamProfile()
            } catch {
                self.steamStatus = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openStorePage(for game: SteamGame) {
        guard let url = URL(string: "https://store.steampowered.com/app/\(game.metadataAppID)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Sample games (debug preview)

    /// Real, well-known appIDs on purpose - so their genuine Steam art/rating/genre/description come
    /// straight through the same `SteamStoreInfoCache` pipeline every real card uses, instead of a
    /// hand-faked placeholder that wouldn't actually exercise (or look like) the real thing.
    private static let sampleGameAppIDs: [(appID: String, name: String)] = [
        ("367520", "Hollow Knight"), ("413150", "Stardew Valley"), ("504230", "Celeste"),
        ("1145360", "Hades"), ("620", "Portal 2"), ("220", "Half-Life 2"),
        ("105600", "Terraria"), ("268910", "Cuphead"), ("588650", "Dead Cells"),
        ("632470", "Disco Elysium"), ("753640", "Outer Wilds"),
    ]

    private static var sampleGames: [SteamGame] {
        sampleGameAppIDs.enumerated().map { index, entry in
            SteamGame(
                appID: "SAMPLE-\(entry.appID)", name: entry.name, installDir: entry.name,
                installFolderPath: "", iconExePath: nil, sizeOnDisk: Int64(300_000_000 * (index + 1)),
                buildID: "sample", lastUpdated: Date()
            )
        }
    }

    func togglePreviewSampleGames() {
        isPreviewingSampleGames.toggle()
        if isPreviewingSampleGames {
            steamGames.append(contentsOf: Self.sampleGames)
        } else {
            steamGames.removeAll { $0.appID.hasPrefix("SAMPLE-") }
        }
    }

    // MARK: - Custom (manually-imported) games

    func addCustomGame(_ game: CustomGame) {
        customGames.append(game)
        CustomGameStore.add(game)
    }

    func updateCustomGame(_ game: CustomGame) {
        guard let index = customGames.firstIndex(where: { $0.id == game.id }) else { return }
        customGames[index] = game
        CustomGameStore.update(game)
    }

    /// Only removes the library record - the referenced exe/folder on disk is never touched, per
    /// spec. Also drops any per-game settings override, which is meaningless once the record itself
    /// is gone.
    func removeCustomGame(_ game: CustomGame) {
        customGames.removeAll { $0.id == game.id }
        CustomGameStore.remove(id: game.id)
        perGameConfigs[game.id] = nil
    }

    /// Custom games are launched by running their own executable directly (unlike Steam games,
    /// which always go through Steam itself - see `SteamGame.iconExePath`), using that game's own
    /// settings override.
    func launchCustomGame(_ game: CustomGame) {
        guard launchingTarget == nil else { return }
        guard FileManager.default.fileExists(atPath: game.exePath) else {
            errorMessage = "\(game.effectiveName)'s executable can't be found anymore - use Locate Game to point Playdock at it again."
            return
        }
        let bottle = resolvedBottle(forExePath: game.exePath)
        let config = config(for: game)
        launchingTarget = .custom(game.id)
        statusMessage = "Launching \(game.effectiveName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // A returned `nil` means the launch was delegated to the wrapper's own Configure
                // app (see `ExeRunner.run`'s own doc comment) rather than ExeDock running the exe
                // itself - a real launch either way, just one this code doesn't hold a Process
                // handle for.
                try await ExeRunner.run(
                    exePath: game.exePath, in: bottle, arguments: game.launchArguments, config: config,
                    preferWrapperEngine: true
                )
                await MainActor.run { [weak self] in self?.statusMessage = "Launched \(game.effectiveName)" }
            } catch {
                await MainActor.run { [weak self] in self?.errorMessage = error.localizedDescription }
            }
            await MainActor.run { [weak self] in self?.launchingTarget = nil }
        }
    }

    /// Finds whichever known bottle (Playdock's own, or a discovered read-only Sikarugir wrapper)
    /// actually contains `exePath`, by path prefix - so a custom game imported from inside an
    /// existing Wine prefix (e.g. something already installed via a Sikarugir wrapper app) launches
    /// inside that same prefix, with whatever that program already has installed there, rather than
    /// Playdock's own separate Default bottle which wouldn't have any of it. Falls back to
    /// Playdock's own Default bottle for anything picked from outside every known bottle - the
    /// common case, since most manually-imported games just sit somewhere plain on disk. (Wine
    /// itself has no requirement that an exe physically live inside the prefix it runs under -
    /// `ExeRunner` already passes an arbitrary host path straight through.) Internal, not private,
    /// so the launch overlay can show which bottle a custom game is actually about to run from.
    func resolvedBottle(forExePath exePath: String) -> Bottle {
        CDriveScanner.allKnownBottles().first { exePath.hasPrefix($0.driveCPath) } ?? BottleManager.shared.defaultBottle
    }
}
