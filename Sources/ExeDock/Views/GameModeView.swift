import SwiftUI
import AppKit

/// The games grid's own measured available width, propagated up from the GeometryReader that
/// measures it - see that measurement's own doc comment for why a PreferenceKey rather than a raw
/// `.onChange` on the geometry value.
private struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Every controller-focusable spot on the main dashboard lives in `LibraryControl` — the controls
/// that are already on screen, not a separate mode.

/// A rectangle rounded only on its leading (left) side, flat on the trailing side - the collapsed
/// Steam icon's own real "docked to the edge" shape (`steamIconEdgeTab`). `RoundedRectangle` alone
/// can't express per-corner radii on this toolchain's minimum macOS target (that convenience API
/// is macOS 14+; this project's own `LSMinimumSystemVersion` is 13), so this is a plain `Path`.
private struct LeftRoundedRect: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Storage key for the floating Settings launcher's shown/minimized state - namespaced here rather
/// than on `GameModeView` (which owns the launcher view) so `SettingsPanelView`'s own
/// "Show Floating Settings Button" toggle can bind the same `@AppStorage` without importing the
/// whole dashboard view.
enum SettingsLauncher {
    static let showLauncherKey = "com.exedock.showSettingsButton"
}

struct GameModeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    /// Play-session records - observed so a just-finished session re-sorts "Recently / Most
    /// Played" (and re-renders card activity chips) the moment the tracker writes it.
    @ObservedObject private var playActivity = PlayActivityStore.shared
    @ObservedObject private var curation = LibraryCurationStore.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("com.exedock.advancedMode") private var isAdvancedMode = false
    @AppStorage("com.exedock.uiScale") private var uiScale = 1.0
    @AppStorage(LibraryLayoutStyle.storageKey) private var libraryLayoutRaw = LibraryLayoutStyle.grid.rawValue
    private var libraryLayout: LibraryLayoutStyle { LibraryLayoutStyle(rawValue: libraryLayoutRaw) ?? .grid }
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    /// "add a hide steam icon launcher option," per live feedback - the floating icon also kept
    /// grabbing controller focus unexpectedly (see `moveFocus`'s own doc comment on the real bug
    /// that came from), so letting someone turn it off entirely addresses both complaints, not just
    /// the visual one.
    static let showSteamIconKey = "com.exedock.showSteamIcon"
    @AppStorage(GameModeView.showSteamIconKey) private var showSteamIcon = false
    /// "a setting to hide labels" - one global switch for every Custom/Mac/Windows badge, native
    /// layouts and the WebView-rendered ones alike, rather than a per-badge-kind toggle nobody
    /// asked for. Nothing reads this yet - a separate, later piece wires it into the actual badge
    /// display sites.
    static let hideBadgesKey = "com.exedock.hideLibraryBadges"
    @AppStorage(GameModeView.hideBadgesKey) private var hideLibraryBadges = false
    /// The floating Settings launcher's shown/minimized state - `true` is the full pill, `false`
    /// collapses it to an edge tab, exactly the way `showSteamIcon` works for the Steam icon.
    @AppStorage(SettingsLauncher.showLauncherKey) private var showSettingsLauncher = false
    @LocalState private var search = ""
    /// Drives the full-window `SettingsPanelView` overlay (it used to be a small `.sheet`).
    @LocalState private var showingSettings = false
    @LocalState private var showingAddGameSheet = false
    @LocalState private var sortOption: GameSortOption = .name
    /// Narrow the grid to favorites only. Off by default; a heart toggle in the header.
    @LocalState private var favoritesOnly = false
    @LocalState private var launchOverlayGame: SteamGame?
    @LocalState private var launchOverlayCustomGame: CustomGame?
    @LocalState private var detailGame: SteamGame?
    @LocalState private var detailCustomGame: CustomGame?
    /// Catalog ids whose client is actually in a bottle. Empty means the edge shows the ? guide.
    @LocalState private var installedLauncherIDs: [String] = []
    /// Which installed launcher the top-right name and picture belong to.
    @LocalState private var accountLauncherID = "steam"
    @LocalState private var showingLauncherGuide = false
    /// Everywhere a controller's D-pad can currently be focused on the dashboard - the toolbar
    /// (Refresh/Settings), a card in the grid, or the floating Steam icon. `nil` until the first
    /// D-pad press (mouse-only browsing shows no ring at all).
    /// The grid's own measured width - used only for controller D-pad row math (`columnCount`), not
    /// the grid's actual rendering (that's plain `.adaptive`, handled natively by SwiftUI). See
    /// `gridColumns`'s own doc comment for why this split matters.
    @LocalState private var gridWidth: CGFloat = 0
    /// Resolved art/genre/description per entry, feeding the real WebView-rendered grid
    /// (`SkinWebGridView`) - kept independently of the native layouts' own per-tile resolution so a
    /// game's info only ever needs to be fetched once regardless of which structure is on screen.
    @LocalState private var libraryPresentations: [String: LibraryPresentation] = [:]
    /// The hard-refresh generation these presentations were loaded for. A newer one means the
    /// cache was wiped and every card has to fetch again.
    @LocalState private var resolvedInfoGeneration = 0

    private enum GameSortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case recentlyUpdated = "Recently Updated"
        case recentlyPlayed = "Recently Played"
        case mostPlayed = "Most Played"
        case recentlyAdded = "Recently Added"
        var id: String { rawValue }
    }

    private var filteredGames: [SteamGame] {
        let filtered = search.isEmpty ? model.steamGames : model.steamGames.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyUpdated:
            return filtered.sorted { ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast) }
        case .recentlyPlayed:
            // Never-played games sink to the bottom (dated distantPast), then by name within ties.
            return filtered.sorted {
                let a = playActivity.lastPlayed($0.appID) ?? .distantPast
                let b = playActivity.lastPlayed($1.appID) ?? .distantPast
                return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .mostPlayed:
            return filtered.sorted {
                playActivity.totalSeconds(for: $0.appID) != playActivity.totalSeconds(for: $1.appID)
                    ? playActivity.totalSeconds(for: $0.appID) > playActivity.totalSeconds(for: $1.appID)
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .recentlyAdded:
            return filtered.sorted { LibraryEntry.steam($0).addedDate > LibraryEntry.steam($1).addedDate }
        }
    }

    /// The unified grid content - Steam games plus manually-imported custom games, searched and
    /// sorted together. Steam-only concerns (the launch overlay, dashboard backdrop theming) stay
    /// keyed off `model.steamGames`/`filteredGames` directly; this is specifically what the grid
    /// itself, and controller focus over it, iterate.
    private var libraryEntries: [LibraryEntry] {
        // Hidden games are *gone* from the library entirely (settings offers unhide); favorites
        // filtering is the cheap positive selection on what's left.
        let all = (model.steamGames.map(LibraryEntry.steam) + model.customGames.map(LibraryEntry.custom))
            .filter { !curation.isHidden($0.id) }
        var filtered = search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
        if favoritesOnly { filtered = filtered.filter { curation.isFavorite($0.id) } }
        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyUpdated:
            return filtered.sorted { $0.sortDate > $1.sortDate }
        case .recentlyPlayed:
            return filtered.sorted { (playActivity.lastPlayed($0.id) ?? .distantPast) > (playActivity.lastPlayed($1.id) ?? .distantPast) }
        case .mostPlayed:
            return filtered.sorted { playActivity.totalSeconds(for: $0.id) > playActivity.totalSeconds(for: $1.id) }
        case .recentlyAdded:
            return filtered.sorted { $0.addedDate > $1.addedDate }
        }
    }

    /// The one place a library entry's id (as reported by a tap - a native SwiftUI gesture in every
    /// other layout, a JS bridge message from `SkinWebGridView`) turns into actually opening its
    /// detail view - shared so every structure's "open" routes through identical logic.
    private func openLibraryEntry(id: String) {
        guard let entry = libraryEntries.first(where: { $0.id == id }) else { return }
        switch entry {
        case .steam(let game): detailGame = game
        case .custom(let game): detailCustomGame = game
        }
    }

    /// `libraryEntries`, resolved into what the real WebView-rendered grid needs to paint an
    /// authentic card: real fetched art (as a data URI - see `SkinWebArt`), genre, description, and
    /// live running state. Resolution itself happens in `resolveLibraryPresentations()`, called from
    /// a `.task` alongside the grid; this just assembles whatever's already been resolved so far,
    /// so cards can render immediately with placeholders and fill in as fetches complete.
    private var webGridEntries: [SkinWebGridEntry] {
        libraryEntries.map { entry in
            let presentation = libraryPresentations[entry.id]
            let isCustom: Bool
            let isMac: Bool
            let sizeText: String?
            switch entry {
            case .steam(let game):
                isCustom = false
                isMac = game.source == .nativeMac
                sizeText = game.sizeOnDisk.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            case .custom:
                isCustom = true
                isMac = false
                sizeText = nil
            }
            // Cards show local recorded play time ("7.5 h") instead of the permanent `nil` the
            // grid used to ship with - ground truth from PlayActivityStore, nil (chip hidden) for
            // a game with no recorded session yet.
            let totalSecondsPlayed = playActivity.totalSeconds(for: entry.id)
            return SkinWebGridEntry(
                id: entry.id,
                title: entry.name,
                genre: presentation?.genre ?? "",
                desc: presentation?.description ?? "",
                art: SkinWebArt.dataURI(forImagePath: presentation?.artPath),
                custom: isCustom,
                mac: isMac,
                windows: !isCustom && !isMac,
                running: runningTracker.runningGames[entry.id] != nil,
                size: sizeText,
                hours: totalSecondsPlayed > 0 ? Self.playHoursText(totalSecondsPlayed) : nil,
                favorite: curation.isFavorite(entry.id),
                downloading: {
                    if case .steam(let game) = entry { return game.isDownloading }
                    return false
                }()
            )
        }
    }

    /// "5 m" / "2.5 h" - one decimal under 10h, whole hours above; minutes are rounded UP so any
    /// real session at all shows at least "1 m" rather than a confusing "0 m".
    private static func playHoursText(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded(.up)))) m" }
        let hours = seconds / 3600
        if hours < 10 { return String(format: "%.1f h", hours) }
        return "\(Int(hours.rounded())) h"
    }

    /// Resolves every entry currently in the library concurrently (already-resolved entries are
    /// skipped, so this stays cheap on repeat calls) - driven by a `.task(id:)` keyed on the actual
    /// set of entry ids, so adding/removing a game re-resolves only what's actually new.
    /// Changes when the library membership changes or Settings/Refresh wipes the store cache.
    private var presentationRefreshToken: String {
        libraryEntries.map(\.id).joined(separator: ",") + "#\(model.gameInfoGeneration)"
    }

    private func resolveLibraryPresentations() async {
        let generation = model.gameInfoGeneration
        let replace = generation != resolvedInfoGeneration
        if replace {
            libraryPresentations = [:]
            resolvedInfoGeneration = generation
        }
        await withTaskGroup(of: (String, LibraryPresentation).self) { group in
            for entry in libraryEntries where replace || libraryPresentations[entry.id] == nil {
                group.addTask { (entry.id, await LibraryPresentation.resolve(entry)) }
            }
            var resolved: [String: LibraryPresentation] = [:]
            for await (id, presentation) in group {
                resolved[id] = presentation
            }
            guard model.gameInfoGeneration == generation, !resolved.isEmpty else { return }
            libraryPresentations.merge(resolved) { _, new in new }
        }
    }

    var body: some View {
        dashboard
    }

    // MARK: - Locked

    private var steamInstallBanner: some View {
        HStack(spacing: 14) {
            if model.isInstallingSteam {
                ProgressView()
                Text(installingMessage)
                    .font(.callout)
            } else {
                Text("Install official Steam to add Windows games. Games already here stay in the library.")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Install Steam") { model.selectedSection = .install }
                    .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.accent.opacity(0.12))
    }

    private var installingMessage: String {
        if case .installing(let message) = model.steamStatus { return message }
        return "Installing Steam…"
    }

    // MARK: - Dashboard

    /// The game to theme the dashboard's own backdrop after - not hover/selection (constantly
    /// re-theming while just browsing the grid would be distracting), but whichever game is
    /// actually running right now, so the effect means something. The launch overlay covers this at
    /// full intensity while starting up; this is the subtler version that lingers behind the normal
    /// dashboard once that overlay dismisses.
    private var themedGame: SteamGame? {
        guard let runningAppID = runningTracker.runningGames.keys.first else { return nil }
        return model.steamGames.first { $0.appID == runningAppID }
    }

    /// Everything `RunningGameTracker` should watch for "is it running" - Steam games (their own
    /// install-dir fragment, unchanged) plus custom games (their exe's own containing folder name,
    /// since they aren't necessarily installed anywhere near a `steamapps` folder at all).
    private var watchTargets: [(id: String, matchFragment: String)] {
        model.steamGames.map { (id: $0.appID, matchFragment: "steamapps/common/\($0.installDir)") }
            // The exe's own filename (no extension) rather than its containing folder - a build
            // folder is often something generic like "Win64" or "bin" shared by many different
            // games, while the exe's own name (e.g. "Dreamcore-Win64-Shipping") is virtually always
            // distinctive enough on its own to actually identify the right process.
            + model.customGames.map { (id: $0.id, matchFragment: (($0.exePath as NSString).lastPathComponent as NSString).deletingPathExtension) }
    }

    private var dashboard: some View {
        ZStack {
            SkinBackground(skin: skin)
                .ignoresSafeArea()

            if let themedGame {
                DashboardBackdropView(game: themedGame)
                    .transition(.opacity)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                if !model.isGameModeUnlocked {
                    steamInstallBanner
                }
                header
                // No separate Divider() here anymore - header's own new skin-accent bottom border
                // (see header's doc comment) already does this row's job, and a plain gray divider
                // right underneath it doubled the seam.
                // The width measurement comes from a GeometryReader wrapping the ScrollView itself,
                // not from measuring the grid (or any of its scrollable content) directly - two
                // earlier attempts both measured something *downstream* of the grid's own sizing
                // decision instead (the padded container around it, then the grid's own rendered
                // size), and both were self-defeating in the same way: whatever wraps an overflowing
                // child always measures back a value *at least* as large as the overflow itself,
                // hiding the very thing this needed to detect. This GeometryReader instead measures
                // what its own parent (this VStack) actually proposes to it - fixed by the outer
                // layout, never inflated by anything inside it - a true, honest reading of the
                // available space. Propagated back up via the standard PreferenceKey mechanism
                // (`GridWidthKey`), not a raw `.onChange` on the captured `geometry` value, for the
                // same reason: it's the far more standard, battle-tested way to communicate a
                // descendant's measured size back up a SwiftUI view tree - the fix for a repeated
                // library-cards-overlap bug.
                if libraryLayout == .grid {
                    // The real per-skin HTML/CSS from the mockups, rendered by an actual WKWebView
                    // for genuine 1:1 fidelity rather than a SwiftUI approximation. GeometryReader
                    // gives it a real, finite frame the same way the earlier Sidebar fix needed - a
                    // WKWebView with no explicit size proposal from its own SwiftUI ancestor
                    // doesn't reliably size itself at all. Search now lives inside the page itself
                    // (each skin's own topbar field, made real) rather than a native field
                    // competing with it for the same visual real estate the mockups already
                    // designed.
                    GeometryReader { geometry in
                        SkinWebGridView(
                            skin: skin,
                            entries: webGridEntries,
                            userName: model.steamProfile?.personaName ?? "Player",
                            // Every skin now has a real, separately-designed light *and* dark
                            // identity in skins.css (not just the six the original mockups already
                            // had), so this always reflects the Mac's actual current appearance
                            // rather than a skin-pinned choice.
                            isDark: systemColorScheme == .dark,
                            // The real, confirmed gap behind "can't navigate right now": Grid's
                            // cards render inside this WebView, which has no idea a controller
                            // exists - `focusedTarget`'s own .card(index) case was already tracked
                            // correctly (moveFocus/activateFocusedTarget below), it just had nowhere
                            // to draw a visible ring. See window.PlaydockSetFocus in skins.js.
                            focusedID: focusedCardID,
                            searchFocused: controllerObserver.libraryFocus == .search,
                            hideBadges: hideLibraryBadges,
                            onOpen: openLibraryEntry
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // Real, measured width for controller D-pad row math (`columnCount`) below -
                        // a genuine, previously-unfinished gap: `gridWidth` was declared and read but
                        // never actually *set* anywhere, so Up/Down always fell back to moving by
                        // exactly one card (column count stuck at 1) instead of jumping a full visual
                        // row - confusing on any grid wider than one column. This GeometryReader
                        // already measures the real content width the WebView itself is sized to, so
                        // it's the correct, direct source - no separate PreferenceKey plumbing needed
                        // since nothing sits between this closure and the state it's updating.
                        .onAppear { gridWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { gridWidth = $0 }
                    }
                    .task(id: presentationRefreshToken) {
                        await resolveLibraryPresentations()
                    }
                } else if libraryLayout == .steam || libraryLayout == .spotlight {
                    // These two embed a real, WKWebView-rendered card grid for their own
                    // grid-shaped region (see SkinWebGridFragmentView) rather than a native
                    // SwiftUI approximation - it needs the same real presentations Grid's own
                    // webGridEntries reads from.
                    alternateLayout
                        .task(id: presentationRefreshToken) {
                            await resolveLibraryPresentations()
                        }
                } else {
                    // Every non-grid layout is a genuinely different structure - some own their
                    // own sidebar/scrolling entirely (Sidebar, Steam-style), so they render full-
                    // bleed here rather than being squeezed into the grid's own padded ScrollView
                    // wrapper. "Search actual game design... maybe just dont have cards," per live
                    // feedback - these are real, distinct navigation models, not the grid reskinned.
                    alternateLayout
                }
            }
            // "make sure when controller there, the UI goes up a bit" - real room for the legend
            // bar below instead of it floating on top of the last row of cards/content. Matches
            // exactly the condition the legend bar itself renders under (isDashboardTheActive-
            // ControllerLayer *and* actually connected) - this padding with no controller attached
            // would just be a permanent, pointless gap at the bottom of the grid.
            .padding(.bottom, gridBottomInset)
            .padding(.trailing, cornerReserve)
            .animation(.easeInOut(duration: 0.2), value: controllerObserver.isConnected)

            // The two bottom-right floating controls - the Steam icon and (stacked just above it)
            // the Settings launcher - kept in their own nested container so this outer ZStack
            // doesn't grow past what Swift's type-checker will solve in one pass.
            cornerFloaters

            if isDashboardTheActiveControllerLayer {
                ControllerLegendBar(hints: dashboardControllerHints)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            // Animated on their own, not on the library underneath. An animation on the
            // whole dashboard was redrawing the game grid on every frame of the transition.
            Group {
                if let detailGame {
                    GameDetailView(game: detailGame, isAdvancedMode: isAdvancedMode) {
                        self.detailGame = nil
                    } onLaunch: {
                        // Stay on the page. Launch already flips the button to "Launching…".
                        // Covering the window here is what left people stuck on the launch screen.
                    } onOpenSimilar: { similar in
                        self.detailGame = similar
                    }
                    .transition(.playdockPage)
                    .zIndex(1)
                }

                if let detailCustomGame {
                    CustomGameDetailView(game: detailCustomGame, isAdvancedMode: isAdvancedMode) {
                        self.detailCustomGame = nil
                    } onLaunch: {
                        // Stay on the page. The Launch button already shows progress.
                    }
                    .transition(.playdockPage)
                    .zIndex(1)
                }

                if let launchOverlayGame {
                    LaunchOverlayView(game: launchOverlayGame, config: model.config(for: launchOverlayGame)) {
                        self.launchOverlayGame = nil
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }

                if let launchOverlayCustomGame {
                    CustomLaunchOverlayView(
                        game: launchOverlayCustomGame,
                        statusLine: "Launching via \(model.bottle(for: launchOverlayCustomGame).name)…"
                    ) {
                        self.launchOverlayCustomGame = nil
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .animation(PlaydockMotion.page, value: detailGame?.appID)
            .animation(PlaydockMotion.page, value: detailCustomGame?.id)
            .animation(PlaydockMotion.page, value: launchOverlayGame?.appID)
            .animation(PlaydockMotion.page, value: launchOverlayCustomGame?.id)

            settingsOverlay
        }
        .skinned()
        // Used to pin every skin to one fixed appearance here (see git history for why - a real
        // Color.primary-vs-Dark-Mode bug this was the first fix for). Superseded now: "make sure
        // they all support dark mode and light mode. follow system for dark/light," per live
        // feedback - every skin's `SkinBackground` and card border/shadow logic is genuinely
        // light/dark-aware on its own now (see `SkinBackground.swift`), so the dashboard just
        // follows the Mac's real current appearance like everything else in the app already does.
        // Settings is no longer a small `.sheet` - it's the full-window `SettingsPanelView`
        // overlay added inside the ZStack above, opened from the floating launcher or the header
        // gear.
        .sheet(isPresented: $showingAddGameSheet) {
            AddGameSheet()
        }
        .onChange(of: model.steamGames) { _ in
            runningTracker.syncWatchedGames(watchTargets)
        }
        .onChange(of: model.customGames) { games in
            runningTracker.syncWatchedGames(watchTargets)
            if let current = detailCustomGame, let updated = games.first(where: { $0.id == current.id }) {
                detailCustomGame = updated
            }
        }
        .onAppear {
            runningTracker.syncWatchedGames(watchTargets)
            refreshInstalledLaunchers()
        }
        .onChange(of: model.steamStatus) { _ in refreshInstalledLaunchers() }
        .onChange(of: model.programInstallMessage) { _ in refreshInstalledLaunchers() }
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard isDashboardTheActiveControllerLayer, let direction = controllerObserver.directionPress?.direction else { return }
            moveFocus(direction)
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            guard isDashboardTheActiveControllerLayer else { return }
            activateFocusedTarget()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            if launchOverlayGame != nil || launchOverlayCustomGame != nil {
                launchOverlayGame = nil
                launchOverlayCustomGame = nil
                return
            }
            guard isDashboardTheActiveControllerLayer, libraryLayout != .grid else { return }
            if case .card = controllerObserver.libraryFocus {
                controllerObserver.libraryFocus = .settings
            }
        }
        .onChange(of: runningTracker.runningGames) { running in
            // The overlay's honest dismiss signal: the game process actually showed up. Playdock
            // can't know when a Steam-mediated game *closes* (Steam owns that child process), so
            // there's no equivalent "and disappears" trigger here - see RunningGameTracker's own
            // doc comment for why this is a best-effort heuristic, not a real IPC hook.
            if let launchOverlayGame, running[launchOverlayGame.appID] != nil {
                self.launchOverlayGame = nil
            }
            if let launchOverlayCustomGame, running[launchOverlayCustomGame.id] != nil {
                self.launchOverlayCustomGame = nil
            }
        }
        .onChange(of: launchOverlayGame?.appID) { appID in
            guard let appID else { return }
            Task {
                try? await Task.sleep(for: .seconds(20))
                if launchOverlayGame?.appID == appID {
                    launchOverlayGame = nil
                }
            }
        }
        .onChange(of: launchOverlayCustomGame?.id) { id in
            guard let id else { return }
            Task {
                try? await Task.sleep(for: .seconds(20))
                if launchOverlayCustomGame?.id == id {
                    launchOverlayCustomGame = nil
                }
            }
        }
    }

    /// Deliberately tiny and unobtrusive, so the games grid gets as much of the window as
    /// possible. Just enough to identify whose library this is and
    /// offer Refresh/Settings; everything else (art, ratings, controller navigation) lives in the
    /// grid and the Game Detail view instead of competing for space up here.
    private var header: some View {
        HStack(spacing: 12) {
            headerTools
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 168)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        // Opaque fill so the library backdrop (blurred art, skin grids) cannot show through
        // this row, including while the section changes.
        .background(skin.topBarBackground)
        .overlay(alignment: .trailing) {
            accountChip
                .fixedSize()
                .padding(.trailing, 20)
        }
        .overlay(alignment: .bottom) {
            if let borderColor = skin.topBarBorderColor {
                Rectangle()
                    .fill(borderColor)
                    .frame(height: skin.topBarBorderWidth)
                    .shadow(color: skin.topBarHasGlow ? skin.accent.opacity(0.7) : .clear, radius: 6, y: 2)
            }
        }
        .zIndex(2)
        .animation(.easeInOut(duration: 0.25), value: skinRaw)
    }

    /// Search and the library actions share one field. The icons use the same fill and border
    /// as the text, instead of a second bar beside it.
    private var headerTools: some View {
        HStack(spacing: 2) {
            librarySearchField
                .frame(maxWidth: 260)
            favoritesToggle
                .focusRing(isControlFocused(.favorites))
            sortMenu
                .focusRing(isControlFocused(.sort))
            headerIconButton(systemImage: "plus", help: L("Add Game"), isFocused: isControlFocused(.add)) {
                showingAddGameSheet = true
            }
            .keyboardShortcut("n", modifiers: .command)
            headerIconButton(systemImage: "arrow.clockwise", help: L("Refresh"), isFocused: isControlFocused(.refresh)) {
                model.hardRefreshGameInfo()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoadingSteamGames || model.isHardRefreshingGameInfo)
            headerIconButton(systemImage: "gearshape", help: L("Settings"), isFocused: isControlFocused(.settings)) {
                openSettings()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(skin.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: skin.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: skin.cardRadius, style: .continuous)
                .strokeBorder(skin.accent.opacity(0.18), lineWidth: skin.borderWidth)
        )
    }

    /// The top-right account. Steam uses the signed-in picture and persona. Every other
    /// installed launcher uses that client's own icon and name. A menu switches among them.
    private var accountChip: some View {
        let launchers = installedLaunchers
        let current = launchers.first { $0.id == accountLauncherID } ?? launchers.first
        return Group {
            if launchers.count > 1, let current {
                Menu {
                    ForEach(launchers) { item in
                        Button {
                            accountLauncherID = item.id
                        } label: {
                            if item.id == current.id {
                                Label(accountTitle(item), systemImage: "checkmark")
                            } else {
                                Text(accountTitle(item))
                            }
                        }
                    }
                } label: {
                    accountLabel(current)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                accountLabel(current)
            }
        }
    }

    private func accountTitle(_ item: CatalogInstaller) -> String {
        if item.isSteam, let name = model.steamProfile?.personaName, !name.isEmpty { return name }
        return item.name
    }

    private func accountLabel(_ item: CatalogInstaller?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                SkinTitleText(text: item.map(accountTitle) ?? L("Playdock"), size: 15, lineLimit: 1)
                Text(installedGameCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            accountImage(item)
        }
    }

    @ViewBuilder
    private func accountImage(_ item: CatalogInstaller?) -> some View {
        if item?.isSteam == true, let avatarPath = model.steamProfile?.avatarPath, let image = LocalImageCache.image(atPath: avatarPath) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let item {
            CatalogIcon(name: item.name, host: item.pageURL.host, bundleID: item.macBundleID, side: 32)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }

    /// Heart toggles the favorites-only filter. It sits in the search row, so it stays an icon.
    private var favoritesToggle: some View {
        Button {
            withAnimation(PlaydockMotion.chrome) { favoritesOnly.toggle() }
        } label: {
            Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                .font(.callout.weight(.semibold))
                .foregroundStyle(favoritesOnly ? .pink : skin.accent)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .help(L(favoritesOnly ? "Show all games" : "Show only favorites"))
        .accessibilityLabel(L("Favorites filter"))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(GameSortOption.allCases) { option in
                Button {
                    sortOption = option
                } label: {
                    if option == sortOption {
                        Label(L(option.rawValue), systemImage: "checkmark")
                    } else {
                        Text(L(option.rawValue))
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.callout.weight(.semibold))
                .foregroundStyle(skin.accent)
                .frame(width: 32, height: 28)
        }
        .help(L(sortOption.rawValue))
        .menuStyle(.borderlessButton)
        .fixedSize()
        .animation(PlaydockMotion.chrome, value: sortOption)
    }

    /// A soft rounded-square, icon-only button - used for the header's secondary actions
    /// (Refresh/Settings), and generally sized big enough to be an easy, unambiguous target for a
    /// controller cursor as well as a mouse.
    private func headerIconButton(systemImage: String, help: String, isFocused: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(skin.accent)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .focusRing(isFocused)
        .help(help)
    }

    /// Installed store clients, in catalog order. A client with no installed program stays off
    /// this edge. Steam is included only when its bottle actually has Steam.
    private var installedLaunchers: [CatalogInstaller] {
        installedLauncherIDs.compactMap { id in CatalogInstaller.all.first { $0.id == id } }
    }

    private func refreshInstalledLaunchers() {
        installedLauncherIDs = CatalogInstaller.all.compactMap { item in
            item.installedExePath() == nil ? nil : item.id
        }
        if !installedLauncherIDs.contains(accountLauncherID) {
            accountLauncherID = installedLauncherIDs.first ?? "steam"
        }
    }

    /// The minimized edge tabs, stacked. Names show only while the settings toggle is on.
    private var launcherDockHeight: CGFloat {
        if installedLaunchers.isEmpty { return 78 }
        let row: CGFloat = showSteamIcon ? 44 : 58
        let count = CGFloat(installedLaunchers.count)
        // The chevron tab sits above the icons and is how the whole column minimizes.
        return 28 + 8 + count * row + max(0, count - 1) * 8
    }

    /// Same minimized edge tab Steam already used, once per installed launcher. Nothing here
    /// when a client was never installed. With none at all, one ? tab explains how to add one.
    private var launcherDock: some View {
        VStack(spacing: 8) {
            if installedLaunchers.isEmpty {
                missingLauncherTab
            } else {
                launcherMinimizeTab
                ForEach(installedLaunchers) { item in
                    launcherTab(item)
                }
            }
        }
        .padding(.bottom, 40)
        .animation(PlaydockMotion.chrome, value: showSteamIcon)
        .animation(PlaydockMotion.chrome, value: installedLauncherIDs)
    }

    /// The same edge chevron the Steam tab used. It minimizes or shows the names for every
    /// installed launcher at once.
    private var launcherMinimizeTab: some View {
        let shape = LeftRoundedRect(radius: 10)
        let width: CGFloat = showSteamIcon ? 168 : 34
        return Button {
            showSteamIcon.toggle()
        } label: {
            Image(systemName: showSteamIcon ? "chevron.right" : "chevron.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(skin.accent)
                .frame(width: width, height: 28)
        }
        .buttonStyle(.plain)
        .help(showSteamIcon ? "Minimize the launcher icons" : "Show launcher names")
        .frame(width: width, height: 28)
        .background(skin.topBarBackground, in: shape)
        .overlay(shape.stroke(skin.accent.opacity(0.4), lineWidth: max(skin.borderWidth, 1)))
        .clipShape(shape)
    }

    private func launcherTab(_ item: CatalogInstaller) -> some View {
        let collapsed = !showSteamIcon
        let launching = (item.isSteam && model.launchingTarget == .steam) || model.launchingTarget == .launcher(item.id)
        let width: CGFloat = collapsed ? 34 : 168
        let height: CGFloat = collapsed ? 58 : 44
        let shape = LeftRoundedRect(radius: 14)
        return Button {
            guard model.launchingTarget == nil else { return }
            accountLauncherID = item.id
            model.openCatalogItem(item)
        } label: {
            HStack(spacing: 8) {
                CatalogIcon(name: item.name, host: item.pageURL.host, bundleID: item.macBundleID, side: collapsed ? 22 : 26)
                    .opacity(launching ? 0.35 : 1)
                if !collapsed {
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(skin.accent)
                }
            }
            .frame(width: width, height: height)
            .overlay { if launching { ProgressView().controlSize(.small) } }
        }
        .buttonStyle(.plain)
        .help(launching ? "Launching \(item.name)…" : "Open \(item.name)")
        .frame(width: width, height: height)
        .background(skin.topBarBackground, in: shape)
        .overlay(shape.stroke(skin.accent.opacity(0.4), lineWidth: max(skin.borderWidth, 1)))
        .clipShape(shape)
        .shadow(color: skin.hasShadow ? .black.opacity(0.3) : .clear, radius: 12, x: -2, y: 0)
    }

    /// No store client is installed. The ? stays on the edge; the guide says what a launcher is
    /// and opens the Install tab.
    private var missingLauncherTab: some View {
        let shape = LeftRoundedRect(radius: 14)
        return Button {
            showingLauncherGuide = true
        } label: {
            Image(systemName: "questionmark")
                .font(.callout.weight(.bold))
                .foregroundStyle(skin.accent)
                .frame(width: 34, height: 78)
        }
        .buttonStyle(.plain)
        .help("No launcher installed")
        .frame(width: 34, height: 78)
        .background(skin.topBarBackground, in: shape)
        .overlay(shape.stroke(skin.accent.opacity(0.4), lineWidth: max(skin.borderWidth, 1)))
        .clipShape(shape)
        .popover(isPresented: $showingLauncherGuide, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                Text("No launcher installed")
                    .font(.headline)
                Text("A launcher is the store client a game runs from, like Steam or the Epic Games Store. Install one and its icon shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                Button("Open Install") {
                    showingLauncherGuide = false
                    model.selectedSection = .install
                }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
            }
            .padding(16)
        }
    }

    // MARK: - Floating corner controls

    /// Neither floating control should take clicks while any full-screen overlay (a game's detail
    /// view, a launch overlay, Controller Mode) is up over the dashboard.
    private var noDashboardOverlayActive: Bool {
        detailGame == nil && detailCustomGame == nil && launchOverlayGame == nil
            && launchOverlayCustomGame == nil
    }

    /// The Steam icon and the Settings launcher, both docked bottom-right, kept in their own
    /// container so the main `body` ZStack stays inside the Swift type-checker's budget. Not wired
    /// into `body` yet - see the follow-up commit that replaces the old `steamFloatingIcon` call
    /// site with this.
    private var cornerFloaters: some View {
        ZStack(alignment: .bottomTrailing) {
            launcherDock
                .allowsHitTesting(noDashboardOverlayActive)
            settingsFloatingLauncher
                .allowsHitTesting(noDashboardOverlayActive && !showingSettings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(PlaydockMotion.chrome, value: showSteamIcon)
        .animation(PlaydockMotion.chrome, value: showSettingsLauncher)
    }

    @ViewBuilder
    private var settingsOverlay: some View {
        if showingSettings {
            SettingsPanelView {
                withAnimation(PlaydockMotion.page) { showingSettings = false }
            }
            .transition(.playdockPage)
            .zIndex(3)
        }
    }

    private func openSettings() {
        withAnimation(PlaydockMotion.page) { showingSettings = true }
    }

    /// A floating Settings launcher that mirrors `steamFloatingIcon`: one continuous view that is
    /// either a full pill (gear + "Settings") or, minimized, a small tab docked flush to the
    /// window's right edge - "a button that can be minimalized, just like the launch steam icon,"
    /// per live feedback. Tapping the pill opens the full-window `SettingsPanelView`; the chevron
    /// tucks it to the edge; the edge tab brings it back. Sits above the Steam icon so the two
    /// stack in the same corner without overlapping, in whichever state each one is in.
    private var settingsFloatingLauncher: some View {
        let collapsed = !showSettingsLauncher
        let width: CGFloat = collapsed ? 30 : 148
        let height: CGFloat = collapsed ? 92 : 46
        // Clear the Steam icon whatever state it's in: expanded it's a 200pt icon 24pt off the
        // bottom, collapsed a 116pt edge tab starting 40pt up. Sit just above either.
        let bottomInset: CGFloat = 40 + launcherDockHeight + 12
        let shape: AnyShape = collapsed ? AnyShape(LeftRoundedRect(radius: 14)) : AnyShape(Capsule())

        return ZStack(alignment: .topLeading) {
            Button {
                openSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                    Text(L("Settings")).fontWeight(.semibold).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(skin.accent)
                .frame(width: width, height: height)
            }
            .buttonStyle(.plain)
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .help(L("Settings"))

            if !collapsed {
                Button {
                    showSettingsLauncher = false
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(skin.accent)
                        .frame(width: 17, height: 17)
                        .background(skin.accent.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(L("Show Floating Settings Button"))
            }

            Button {
                showSettingsLauncher = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    Image(systemName: "gearshape.fill").font(.body)
                }
                .foregroundStyle(skin.accent)
                .frame(width: width, height: height)
            }
            .buttonStyle(.plain)
            .opacity(collapsed ? 1 : 0)
            .allowsHitTesting(collapsed)
            .help(L("Settings"))
        }
        .frame(width: width, height: height)
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(skin.accent.opacity(0.35), lineWidth: skin.borderWidth))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: collapsed ? 10 : 16, x: collapsed ? -2 : 0, y: collapsed ? 0 : 6)
        .focusRing(isControlFocused(.settingsLauncher))
        .padding(.trailing, collapsed ? 0 : 22)
        .padding(.bottom, bottomInset)
        .animation(PlaydockMotion.chrome, value: showSettingsLauncher)
    }

    /// One search field for every layout, including the grid. The page itself no longer draws a second one.
    private var librarySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Search your games"), text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .focusRing(controllerObserver.libraryFocus == .search)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search your games"), text: $search)
                    .textFieldStyle(.plain)
                    .font(.title3)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Playdock.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Playdock.Radius.control, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )

            Picker(L("Sort"), selection: $sortOption) {
                ForEach(GameSortOption.allCases) { option in
                    Text(L(option.rawValue)).tag(option)
                }
            }
            .frame(maxWidth: 220)
        }
    }

    /// The card size a few-vs-many-games count alone picks - big, prominent cards for a small
    /// library instead of sitting tiny in a corner of a mostly-empty window; a large library steps
    /// down to a denser grid so more fits per screen.
    private var idealCardSizeTier: (minWidth: CGFloat, maxWidth: CGFloat, artworkHeight: CGFloat) {
        switch libraryEntries.count {
        case 0...2: return (480, 640, 260)
        case 3...6: return (360, 440, 190)
        case 7...15: return (280, 340, 150)
        default: return (240, 280, 130)
        }
    }

    private static let gridSpacing: CGFloat = Playdock.Spacing.grid
    /// `ControllerLegendBar`'s own real rendered height (8pt vertical padding on each side + one
    /// line of `.caption`/`.callout` text) - kept as one shared constant so the bottom padding that
    /// makes room for it and the bar's own size can't quietly drift apart.
    private static let legendBarHeight: CGFloat = 40

    /// The controller legend is the only thing that needs the library to step up. The size
    /// slider and the launcher tabs float on top of the page, so they don't leave a blank band.
    private var gridBottomInset: CGFloat {
        isDashboardTheActiveControllerLayer && controllerObserver.isConnected ? Self.legendBarHeight : 0
    }

    /// Launcher names, when shown, sit on top of the right edge. The page itself stays full width.
    private var cornerReserve: CGFloat { 0 }

    /// Non-hidden Steam plus custom games - what the header count should reflect, not Steam alone.
    private var installedVisibleGameCount: Int {
        model.steamGames.filter { !curation.isHidden($0.appID) }.count
            + model.customGames.filter { !curation.isHidden($0.id) }.count
    }

    private var installedGameCountLabel: String {
        let count = installedVisibleGameCount
        if count == 0 { return L("No games installed") }
        return Localization.plural(count, singular: "%lld game", plural: "%lld games")
    }

    /// The grid's own column layout, back to plain `.adaptive(minimum:maximum:)` - SwiftUI works
    /// out how many columns actually fit *natively*, using the grid's own real proposed width
    /// directly, with no external measurement of any kind needed. A self-computed column count/
    /// width (an earlier version of this) needed `gridWidth` - measured via a GeometryReader
    /// elsewhere in this view - to be correct and current at the moment the grid renders, and in
    /// practice that measurement didn't reliably arrive: confirmed live via a screenshot showing
    /// the grid stuck rendering a single narrow column with a large empty area beside it - the
    /// exact fallback behavior of a stale/zero measurement, not a sizing-math error. `.adaptive`
    /// sidesteps the whole dependency by not needing that value at all. Card *width enforcement*
    /// (`.frame(maxWidth: idealCardSizeTier.maxWidth)` at each call site, below) still fixes the
    /// real, separately-confirmed overlap cause (a card rendering wider than its own column) - with
    /// a real, static ceiling this time, not `.infinity`, after a second screenshot showed genuine
    /// z-index stacking on a *partial* last row, where nothing stopped a card from growing
    /// arbitrarily wide with no upper bound at all.
    private var gridColumns: [GridItem] {
        let tier = idealCardSizeTier
        return [GridItem(.adaptive(minimum: tier.minWidth, maximum: tier.maxWidth), spacing: Self.gridSpacing)]
    }

    /// Best-effort column count for controller D-pad row math only (`moveFocus`) - *not* used for
    /// the grid's own rendering anymore, so an imprecise `gridWidth` measurement here can make
    /// D-pad up/down jump the "wrong" number of cards at worst, never break the actual visual
    /// layout the way it did when this same measurement was load-bearing for column count itself.
    /// Grid's real, live layout is the WebView's own CSS - `.grid{grid-template-columns:repeat(
    /// auto-fill,minmax(280px,1fr));gap:36px;}` in skins.css, a fixed 280px/36px regardless of how
    /// many entries there are - not `idealCardSizeTier` (a *different*, count-dependent sizing table
    /// that only ever applied to the native `GameCardView` grid, which nothing renders anymore).
    /// Using the wrong constants here doesn't break the actual grid, but it does make the D-pad ring
    /// jump to a visually wrong row - exactly the kind of thing that reads as "navigation is broken"
    /// even though the mechanism underneath works.
    private static let webCardMinWidth: CGFloat = 280
    private static let webCardGap: CGFloat = 36
    private var columnCount: Int {
        guard gridWidth > 0 else { return 1 }
        return max(1, Int((gridWidth + Self.webCardGap) / (Self.webCardMinWidth + Self.webCardGap)))
    }

    private var artworkHeight: CGFloat { idealCardSizeTier.artworkHeight }

    /// Only active while nothing's covering the dashboard. A game's detail page and Settings own
    /// the same D-pad/A stream the instant they're shown.
    private var isDashboardTheActiveControllerLayer: Bool {
        detailGame == nil && detailCustomGame == nil && !showingSettings
    }

    private func isControlFocused(_ control: LibraryControl) -> Bool {
        controllerObserver.isConnected && controllerObserver.libraryFocus == control
    }

    /// `focusedTarget`'s own `.card` index, resolved to that entry's real id, for `SkinWebGridView`'s
    /// `focusedID` - `nil` for every other target (toolbar, Steam icon) or while no controller is
    /// connected, so the WebView only ever shows a ring while there's a real card focused for it to
    /// show.
    private var focusedCardID: String? {
        guard controllerObserver.isConnected, case .card(let index) = controllerObserver.libraryFocus else { return nil }
        return libraryEntries[safe: index]?.id
    }

    private var headerRow: [LibraryControl] { [.favorites, .sort, .add, .refresh, .settings] }

    private var bottomRow: [LibraryControl] {
        var row: [LibraryControl] = [.uiScale]
        if showSettingsLauncher { row.append(.settingsLauncher) }
        if showSteamIcon { row.append(.steamIcon) }
        return row
    }

    /// The control directly under the header: the page's search field on the grid, otherwise the
    /// games themselves, otherwise the corner controls.
    private var belowHeader: LibraryControl {
        .search
    }

    private var aboveBottom: LibraryControl {
        if !libraryEntries.isEmpty { return .card(max(0, libraryEntries.count - 1)) }
        if libraryLayout == .grid { return .search }
        return .settings
    }

    /// The real on-screen control legend for whichever layout is actually showing - "markers for
    /// how to control," per live feedback. LT/RT only get a hint on the three layouts that actually
    /// have one game singled out for them to step through (Carousel, Shelves, Spotlight); Grid,
    /// Sidebar, and Steam-style don't claim a button that does nothing there.
    private var dashboardControllerHints: [ControllerHint] {
        var hints = controllerObserver.moveSelectBackHints
        hints.append(controllerObserver.switchTabHint)
        if libraryLayout == .carousel || libraryLayout == .shelves || libraryLayout == .spotlight {
            hints.append(controllerObserver.switchGameHint)
        }
        return hints
    }

    /// Real 2D movement across every focusable spot on the dashboard: the toolbar row above the
    /// grid, the grid itself (up/down jump a full row via `columnCount`, left/right stop at row
    /// edges instead of wrapping into the row above/below), and the floating Steam icon beyond the
    /// grid's last row.
    private func moveFocus(_ direction: ControllerDirection) {
        guard let current = controllerObserver.libraryFocus else {
            controllerObserver.libraryFocus = libraryEntries.isEmpty ? .favorites : .card(0)
            return
        }
        if current == .uiScale, direction == .left || direction == .right {
            nudgeUIScale(direction == .right ? 1 : -1)
            return
        }
        switch current {
        case .section(let index):
            switch direction {
            case .left: controllerObserver.libraryFocus = .section(max(0, index - 1))
            case .right: controllerObserver.libraryFocus = .section(min(AppModel.SidebarSection.allCases.count - 1, index + 1))
            case .down: controllerObserver.libraryFocus = .favorites
            case .up: break
            }
        case .favorites, .sort, .add, .refresh, .settings:
            moveHorizontal(headerRow, current: current, direction: direction, up: .section(0), down: belowHeader)
        case .search:
            switch direction {
            case .up: controllerObserver.libraryFocus = .settings
            case .down: controllerObserver.libraryFocus = libraryEntries.isEmpty ? (bottomRow.last ?? .uiScale) : .card(0)
            case .left, .right: break
            }
        case .card(let index):
            // Other layouts own their own stick movement while a card is selected. Up is how
            // the grid gets back to search; B (handled above) leaves those other layouts.
            guard libraryLayout == .grid else { return }
            moveGridFocus(index, direction)
        case .settingsLauncher, .steamIcon, .uiScale:
            moveHorizontal(bottomRow, current: current, direction: direction, up: aboveBottom, down: nil)
        }
    }

    private func moveHorizontal(_ row: [LibraryControl], current: LibraryControl, direction: ControllerDirection, up: LibraryControl?, down: LibraryControl?) {
        guard let index = row.firstIndex(of: current) else { return }
        switch direction {
        case .left where index > 0:
            controllerObserver.libraryFocus = row[index - 1]
        case .right where index + 1 < row.count:
            controllerObserver.libraryFocus = row[index + 1]
        case .up:
            if let up { controllerObserver.libraryFocus = up }
        case .down:
            if let down { controllerObserver.libraryFocus = down }
        default:
            break
        }
    }

    private func moveGridFocus(_ index: Int, _ direction: ControllerDirection) {
        let columns = columnCount
        switch direction {
        case .left:
            guard index % columns != 0 else { return }
            controllerObserver.libraryFocus = .card(index - 1)
        case .right:
            guard index % columns != columns - 1, index + 1 < libraryEntries.count else { return }
            controllerObserver.libraryFocus = .card(index + 1)
        case .up:
            controllerObserver.libraryFocus = index < columns ? .search : .card(index - columns)
        case .down:
            // Only the genuine last card can step down onto the corner controls. Every other
            // card in a short last row stays put.
            let next = index + columns
            if next < libraryEntries.count {
                controllerObserver.libraryFocus = .card(next)
            } else if index == libraryEntries.count - 1 {
                controllerObserver.libraryFocus = bottomRow.last ?? .uiScale
            }
        }
    }

    private func nudgeUIScale(_ step: Int) {
        let stops = [0.75, 0.9375, 1.125, 1.3125, 1.5]
        let current = stops.min(by: { abs($0 - uiScale) < abs($1 - uiScale) }) ?? uiScale
        guard let index = stops.firstIndex(of: current) else { return }
        let next = min(max(0, index + step), stops.count - 1)
        uiScale = stops[next]
    }

    private func cycleSort() {
        let all = GameSortOption.allCases
        guard let index = all.firstIndex(of: sortOption) else { return }
        sortOption = all[(index + 1) % all.count]
    }

    private func activateFocusedTarget() {
        switch controllerObserver.libraryFocus {
        case .section(let index):
            let sections = AppModel.SidebarSection.allCases
            guard sections.indices.contains(index) else { return }
            model.selectedSection = sections[index]
        case .favorites:
            withAnimation(PlaydockMotion.chrome) { favoritesOnly.toggle() }
        case .sort:
            cycleSort()
        case .add:
            showingAddGameSheet = true
        case .refresh:
            guard !model.isLoadingSteamGames, !model.isHardRefreshingGameInfo else { return }
            model.hardRefreshGameInfo()
        case .settings, .settingsLauncher:
            openSettings()
        case .card(let index):
            guard libraryLayout == .grid, libraryEntries.indices.contains(index) else { return }
            switch libraryEntries[index] {
            case .steam(let game): detailGame = game
            case .custom(let game): detailCustomGame = game
            }
        case .steamIcon:
            guard showSteamIcon, model.launchingTarget == nil else { return }
            model.openSteamClient()
        case .search, .uiScale, nil:
            break
        }
    }

    @ViewBuilder
    private var gamesGrid: some View {
        if model.isLoadingSteamGames && model.steamGames.isEmpty && model.customGames.isEmpty {
            // Shimmering placeholders in the exact grid the real cards will land in - reads as a
            // proper dashboard loading in, not just "something, somewhere, is thinking."
            LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
                ForEach(0..<6, id: \.self) { _ in GameCardSkeleton().frame(maxWidth: idealCardSizeTier.maxWidth) }
            }
        } else if model.steamGames.isEmpty && model.customGames.isEmpty {
            emptyGamesState
        } else if libraryEntries.isEmpty {
            Text("No games match \u{201C}\(search)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
                ForEach(Array(libraryEntries.enumerated()), id: \.element.id) { index, entry in
                    let isFocused = isControlFocused(.card(index))
                    switch entry {
                    case .steam(let game):
                        GameCardView(
                            game: game, isAdvancedMode: isAdvancedMode, artworkHeight: artworkHeight,
                            isFocused: isFocused
                        ) {
                            model.launchSteamGame(game)
                        } onOpenDetail: {
                            detailGame = game
                        }
                        // Explicit, not left to the grid cell alone: real evidence (a screenshot)
                        // showed each card's *artwork* bleeding edge-to-edge into its neighbor with
                        // zero visible gap, while the text/button area below it was genuinely
                        // spaced apart correctly - a `GridItem(.adaptive(...))` column apparently
                        // only governs *positioning*, not an enforced content-width ceiling, so a
                        // card with no width ceiling of its own can render wider than its column and
                        // overlap the next one. `maxWidth: .infinity` (an earlier version of this
                        // fix) turned out to have no real ceiling at all - fine for a full row, but
                        // a real, second, separately-confirmed overlap (this time genuine z-index
                        // stacking, via another screenshot) showed up specifically on a *partial*
                        // last row, where nothing was left to stop a card from growing arbitrarily
                        // wide. `idealCardSizeTier.maxWidth` is a real, static ceiling - not tied to
                        // any measurement - matching the exact same maximum `.adaptive` itself
                        // already uses for this same tier, so it can never disagree with the grid's
                        // own column math.
                        .frame(maxWidth: idealCardSizeTier.maxWidth)
                    case .custom(let customGame):
                        CustomGameCardView(
                            game: customGame, isAdvancedMode: isAdvancedMode, artworkHeight: artworkHeight,
                            isFocused: isFocused
                        ) {
                            model.launchCustomGame(customGame)
                        } onOpenDetail: {
                            detailCustomGame = customGame
                        }
                        .frame(maxWidth: idealCardSizeTier.maxWidth)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.steamGames)
            .animation(.easeInOut(duration: 0.2), value: model.customGames)
            // Deliberately NOT animated on column size - `LazyVGrid` doesn't reflow smoothly when
            // its own column count/width changes, and this grid's own sizing changes often (every
            // resize, every count-driven tier change), so an implicit animation on it means near-
            // constant transitions with real potential to visibly overlap mid-flight.
        }
    }

    /// Routes to whichever real, structurally distinct layout is picked in Settings - all of them
    /// share the same `libraryEntries` (so search/sort still apply) and the same "open detail" path
    /// the grid's own cards already use, so the actual game data, launch flow, and detail view are
    /// identical no matter which structure is on screen; only how entries are arranged differs.
    @ViewBuilder
    private var alternateLayout: some View {
        let openDetail: (LibraryEntry) -> Void = { openLibraryEntry(id: $0.id) }
        let launchEntry: (LibraryEntry) -> Void = { entry in
            switch entry {
            case .steam(let game):
                model.launchSteamGame(game)
            case .custom(let game):
                model.launchCustomGame(game)
            }
        }
        switch libraryLayout {
        case .grid: EmptyView() // unreachable - handled above
        case .shelves: LibraryShelvesLayout(entries: libraryEntries, onOpenDetail: openDetail, onLaunch: launchEntry)
        case .sidebar: LibrarySidebarLayout(entries: libraryEntries, onOpenDetail: openDetail, onLaunch: launchEntry)
        case .steam: LibrarySteamStyleLayout(entries: libraryEntries, webGridEntries: webGridEntries, skin: skin, isDark: systemColorScheme == .dark, focusedID: focusedCardID, onOpenDetail: openDetail)
        case .carousel: LibraryCarouselLayout(entries: libraryEntries, onOpenDetail: openDetail)
        case .spotlight: LibrarySpotlightLayout(entries: libraryEntries, webGridEntries: webGridEntries, skin: skin, isDark: systemColorScheme == .dark, focusedID: focusedCardID, onOpenDetail: openDetail, onLaunch: launchEntry)
        }
    }

    private var emptyGamesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(L("No games installed yet"))
                .font(.title3).bold()
            Text(L("Install something from the Steam store, or use \u{201C}+\u{201D} above to add a game you already have."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Game card

private struct GameCardView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    let game: SteamGame
    let isAdvancedMode: Bool
    let artworkHeight: CGFloat
    let isFocused: Bool
    let onLaunch: () -> Void
    let onOpenDetail: () -> Void
    @LocalState private var storeInfo: SteamStoreInfo?
    @LocalState private var showingSettings = false
    @LocalState private var isHoveringArtwork = false
    @LocalState private var isHoveringCard = false

    private var hasCustomSettings: Bool { model.perGameConfigs[game.appID] != nil }
    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[game.appID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 4) {
                    SkinTitleText(text: game.name, size: 20)
                        .help(developerHelpText)
                    Spacer()
                    if isAdvancedMode && game.source == .wineBottle {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: hasCustomSettings ? "slider.horizontal.3" : "gearshape")
                                .font(.title2)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .help(hasCustomSettings ? "Custom settings" : "Game settings")
                        .popover(isPresented: $showingSettings) {
                            GameSettingsPopover(game: game)
                        }
                    }
                }
                if let description = storeInfo?.shortDescription {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                detailsRow
                if runningInfo != nil {
                    RunningBadge()
                } else {
                    openDetailHint
                }
            }
            .padding(20)
        }
        .cardSurface(isHovering: isHoveringCard)
        .focusRing(isFocused)
        // Tapping the card opens the full Game Detail view rather than launching straight away -
        // launching should always be a deliberate confirm step, so the grid
        // card itself is just an entry point now. A plain single-tap gesture on this container is
        // safe alongside the gearshape Button above (SwiftUI routes a tap within a nested Button's
        // own bounds to that button first) - this is a different situation from the earlier
        // Steam-tile bug, which was specifically a *simultaneous* zero-distance DragGesture
        // competing with a double-tap recognizer on the very same view.
        .contentShape(RoundedRectangle(cornerRadius: Playdock.Radius.card))
        .onTapGesture { onOpenDetail() }
        .contextMenu {
            Button {
                onOpenDetail()
            } label: {
                Label("View Details", systemImage: "info.circle")
            }
            if runningInfo == nil && !game.isPreviewSample && !game.isDownloading {
                Button {
                    onLaunch()
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .disabled(model.launchingTarget != nil)
            }
            Divider()
            Button {
                model.revealInFinder(installFolderPath)
            } label: {
                Label("Reveal Install Folder", systemImage: "folder")
            }
            Button {
                model.openStorePage(for: game)
            } label: {
                Label("View Store Page", systemImage: "safari")
            }
            Button {
                NSPasteboard.general.clearContents()
                // The real Steam appid, not ExeDock's own internally-namespaced `appID` (which can
                // carry a "MAC-"/"SAMPLE-" prefix so it never collides with a same-appid entry from
                // a different source) - copying that prefix out to a user would be actively wrong.
                NSPasteboard.general.setString(game.metadataAppID, forType: .string)
            } label: {
                Label("Copy App ID", systemImage: "doc.on.doc")
            }
        }
        .task(id: "\(game.appID)#\(model.gameInfoGeneration)") {
            storeInfo = await SteamStoreInfoCache.shared.info(for: game.metadataAppID)
        }
        .onHover { isHovering in
            isHoveringCard = isHovering
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var installFolderPath: String { game.installFolderPath }

    private var detailsRow: some View {
        HStack(spacing: 8) {
            if let score = storeInfo?.metacriticScore {
                metacriticBadge(score)
            }
            if let genre = storeInfo?.genres.first {
                Text(genre)
            }
            if let size = game.sizeOnDisk {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let build = game.buildID {
                Text("Build \(build)")
            }
            if game.source == .wineBottle {
                Text(engineBadgeText)
            } else {
                Text("Mac")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// Steam's own color convention: green for "generally favorable," yellow for "mixed," red for
    /// "generally unfavorable" - the same ranges Metacritic/Steam use on their own store pages.
    private func metacriticBadge(_ score: Int) -> some View {
        Text("\(score)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(metacriticColor(score), in: RoundedRectangle(cornerRadius: 4))
    }

    private func metacriticColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50..<75: return .yellow
        default: return .red
        }
    }

    private var developerHelpText: String {
        guard let storeInfo, !storeInfo.developers.isEmpty else { return game.name }
        var parts = ["By \(storeInfo.developers.joined(separator: ", "))"]
        if let releaseDate = storeInfo.releaseDate { parts.append("Released \(releaseDate)") }
        return parts.joined(separator: " · ")
    }

    private var engineBadgeText: String {
        let config = model.config(for: game)
        return config.d3dMetal ? "D3DMetal" : (config.dxvk ? "DXVK" : (config.dxmt ? "DXMT" : "Default"))
    }

    /// Replaces the old inline Launch button - launching now only happens from the full Game Detail
    /// view, reached by tapping the card, so this is just a quiet affordance instead of an action.
    private var openDetailHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
            Text("Click for details")
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var artwork: some View {
        Group {
            if let headerPath = storeInfo?.headerImagePath, let image = LocalImageCache.image(atPath: headerPath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(isHoveringArtwork ? 1.06 : 1.0)
                    .animation(.easeOut(duration: 0.3), value: isHoveringArtwork)
            } else {
                // Not a real exe-icon lookup on purpose - NSWorkspace can't extract one from a file
                // buried in a private, never-Finder-indexed Wine bottle, so it just renders blank.
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: artworkHeight * 0.3))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.15))
            }
        }
        .frame(height: artworkHeight)
        .clipped()
        .onHover { isHoveringArtwork = $0 }
    }
}

// MARK: - Game detail

/// The full "click into a game" detail view - a first-class, Steam-store-like page (big art, genre,
/// rating, developer, release date, description) reached by tapping a card. Launching now happens
/// from here rather than directly off the small grid card, a deliberate confirm step before a
/// title actually starts. Not a real `matchedGeometryEffect` hero animation from the
/// exact card tapped, for the same reason `LaunchOverlayView` doesn't attempt one either:
/// `GameCardView` lives inside a `LazyVGrid`/`ScrollView`, where an off-screen card may not have a
/// measured frame to animate from. A scale+fade transition (applied by the caller, matching
/// `LaunchOverlayView`'s own) reads as the card "growing" into this view without that risk.
/// The actions `actionRow` can show, in display order - used both to render the row and to drive
/// controller focus over it (see `GameDetailView`'s `.onChange(of: controllerObserver.*)` handlers).
private enum DetailAction: Equatable {
    case favorite, hide, launch, settings, reveal, storePage, about
}

struct GameDetailView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    /// Live play-activity for this game - totals, session count, last-played - from the local
    /// recorder (see PlayActivityStore). Observed so a finishing session updates the header in
    /// place while the page is open.
    @ObservedObject private var playActivity = PlayActivityStore.shared
    @ObservedObject private var curation = LibraryCurationStore.shared
    let game: SteamGame
    let isAdvancedMode: Bool
    let onClose: () -> Void
    let onLaunch: () -> Void
    /// Opens a different game's detail page in place ("More like this" taps).
    let onOpenSimilar: (SteamGame) -> Void
    @LocalState private var storeInfo: SteamStoreInfo?
    @LocalState private var showingSettings = false
    /// Which action a controller's D-pad currently has highlighted - only ever shown/used while a
    /// controller is actually connected (see `availableActions`'s call sites), so mouse-only use
    /// never sees a stray focus ring.
    @LocalState private var focusedActionIndex = 0
    /// Keyboard arrows (no pad connected) use the same action list. Stays off until a key moves
    /// focus, so a mouse-only visit doesn't grow a ring on Launch.
    @LocalState private var keyboardNavigating = false
    @LocalState private var descriptionExpanded = false
    /// Non-nil while a photo is shown full-size: the index into `allPhotoPaths`, so the lightbox
    /// can browse with arrows / D-pad instead of only closing.
    @LocalState private var expandedPhotoIndex: Int?
    @LocalState private var gameAccent: Color?
    /// This game's Playdock-recorded launch outcomes (see LocalOutcomeTracker) - loaded with the
    /// rest of the page and refreshed whenever a launch finishes while it's open, so the
    /// reliability banner below describes right now, not session-stale state.
    @LocalState private var launchHistory: [LaunchOutcomeRecord] = []
    @LocalState private var showingCompatibilityFinder = false
    /// Same-primary-genre Steam games, resolved asynchronously from the *cached* store info only
    /// (see cachedSnapshot) - this rail never triggers a network fetch of its own.
    @LocalState private var similarGames: [(game: SteamGame, headerPath: String?)] = []

    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[game.appID] }
    private var hasCustomSettings: Bool { model.perGameConfigs[game.appID] != nil }

    /// Exactly the same conditions `actionRow` already uses to decide what to show - kept as one
    /// list so controller focus always lines up with what's actually on screen (e.g. never
    /// highlights a Settings button that isn't rendered outside Advanced Mode).
    private var availableActions: [DetailAction] {
        var actions: [DetailAction] = [.favorite, .hide]
        if runningInfo == nil && !game.isPreviewSample && !game.isDownloading { actions.append(.launch) }
        if !game.isPreviewSample { actions.append(.settings) }
        actions.append(.reveal)
        actions.append(.storePage)
        if aboutCanExpand { actions.append(.about) }
        return actions
    }

    private var aboutText: String? {
        storeInfo?.aboutTheGame ?? storeInfo?.shortDescription
    }

    private var aboutCanExpand: Bool {
        guard let aboutText else { return false }
        return aboutText.count > 280 || aboutText.components(separatedBy: "\n").count > 4
    }

    private func isFocused(_ action: DetailAction) -> Bool {
        (controllerObserver.isConnected || keyboardNavigating) && availableActions[safe: focusedActionIndex] == action
    }

    private func moveActionFocus(_ direction: ControllerDirection) {
        guard !availableActions.isEmpty else { return }
        switch direction {
        case .left, .up: focusedActionIndex = max(0, focusedActionIndex - 1)
        case .right, .down: focusedActionIndex = min(availableActions.count - 1, focusedActionIndex + 1)
        }
    }

    private func activateFocusedAction() {
        switch availableActions[safe: focusedActionIndex] {
        case .favorite:
            curation.toggleFavorite(game.appID)
        case .hide:
            curation.hide(game.appID)
            onClose()
        case .launch:
            onLaunch()
            model.launchSteamGame(game)
        case .settings:
            showingSettings = true
        case .reveal:
            model.revealInFinder(installFolderPath)
        case .storePage:
            model.openStorePage(for: game)
        case .about:
            descriptionExpanded.toggle()
        case nil:
            break
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SkinBackground(skin: skin)
                .ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        launcherHero
                        VStack(alignment: .leading, spacing: 24) {
                            header
                            steamReviews
                            if hasPhotos { photoGrid }
                            achievementsSection
                            reliabilityBanner
                            descriptionCard
                            if !similarGames.isEmpty { moreLikeThis }
                        }
                        .padding(.horizontal, 32)
                    }
                    .padding(.bottom, 160)
                    .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
            .padding(.bottom, 72)
            closeButton

            if let expandedPhotoIndex {
                photoLightbox(at: expandedPhotoIndex)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(game.appID)#\(model.gameInfoGeneration)") {
            storeInfo = await SteamStoreInfoCache.shared.info(for: game.metadataAppID)
            if let path = storeInfo?.headerImagePath { gameAccent = await GameArtColor.dominantColor(forImagePath: path) }
            reloadLaunchHistory()
        }
        .task(id: storeInfo?.genres.first) { await reloadSimilarGames() }
        // A launch finishing while this page is open must update the banner in place.
        .onChange(of: model.launchingTarget) { _ in reloadLaunchHistory() }
        .onExitCommand { onClose() }
        .focusable()
        .onMoveCommand { direction in
            guard !controllerObserver.isConnected, expandedPhotoIndex == nil else { return }
            keyboardNavigating = true
            switch direction {
            case .left: moveActionFocus(.left)
            case .right: moveActionFocus(.right)
            case .up: moveActionFocus(.up)
            case .down: moveActionFocus(.down)
            @unknown default: break
            }
        }
        // GameDetailView always treats itself as the active controller-input layer while it's
        // mounted - it's rendered above everything else wherever it appears (a direct card tap, or
        // ControllerModeView's own drill-down), so there's nothing above it to defer to.
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard let direction = controllerObserver.directionPress?.direction else { return }
            if expandedPhotoIndex != nil {
                // Inside the lightbox the D-pad browses photos instead of moving detail focus.
                if direction == .left { stepExpandedPhoto(by: -1) }
                if direction == .right { stepExpandedPhoto(by: 1) }
                return
            }
            moveActionFocus(direction)
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            guard expandedPhotoIndex == nil else { return }
            activateFocusedAction()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            // Back out one level at a time - close the expanded photo first if one's open, the
            // whole detail view otherwise.
            if expandedPhotoIndex != nil {
                expandedPhotoIndex = nil
            } else {
                onClose()
            }
        }
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(skin.accent)
                .frame(width: 34, height: 34)
                .background(skin.topBarBackground, in: closeShape)
                .overlay(closeShape.strokeBorder(skin.topBarBorderColor ?? skin.accent.opacity(0.45), lineWidth: skin.borderWidth))
        }
        .buttonStyle(.plain)
        .padding(24)
        .keyboardShortcut(.cancelAction)
    }

    private var closeShape: PlaydockCardShape {
        PlaydockCardShape(skin: skin, cornerRadius: min(skin.cardRadius, 8))
    }

    /// The picture, the name, and Launch on the same surface. No blur band and no box around
    /// the art — that frame was the picture letterboxed inside a rounded rectangle.
    private var launcherHero: some View {
        HStack(alignment: .center, spacing: 24) {
            if let path = storeInfo?.logoPath ?? storeInfo?.headerImagePath ?? storeInfo?.backgroundImagePath,
               let image = LocalImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 132)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Text(game.name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        curation.toggleFavorite(game.appID)
                    } label: {
                        Image(systemName: curation.isFavorite(game.appID) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(curation.isFavorite(game.appID) ? .pink : skin.accent.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .focusRing(isFocused(.favorite))
                    .help(L(curation.isFavorite(game.appID) ? "Remove from Favorites" : "Mark as Favorite"))
                    Menu {
                        Button(L("Hide This Game from Library"), role: .destructive) {
                            curation.hide(game.appID)
                            onClose()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .foregroundStyle(skin.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusRing(isFocused(.hide))
                }
                if !subtitleLine.isEmpty {
                    Text(subtitleLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.top, 64)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Steam's own review words and the percent behind them. Shown only when the store returned a count.
    @ViewBuilder
    private var steamReviews: some View {
        if let summary = storeInfo?.reviewSummary {
            HStack(spacing: 8) {
                if let percent = storeInfo?.reviewPercent {
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: index < reviewStars(percent) ? "star.fill" : "star")
                                .font(.system(size: 13))
                                .foregroundStyle(index < reviewStars(percent) ? Color.yellow : Color.secondary.opacity(0.4))
                        }
                    }
                }
                Text(summary)
                    .font(.system(size: 15, weight: .semibold))
                if let percent = storeInfo?.reviewPercent, let count = storeInfo?.reviewCount {
                    Text("\(percent)% of \(count.formatted()) reviews")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reviewStars(_ percent: Int) -> Int {
        switch percent {
        case 95...: return 5
        case 80..<95: return 4
        case 70..<80: return 3
        case 40..<70: return 2
        default: return 1
        }
    }

    /// The achievements Steam puts on the store page: the total, and the highlighted icons.
    @ViewBuilder
    private var achievementsSection: some View {
        if let total = storeInfo?.achievementTotal, total > 0 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Achievements")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(total)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if !(storeInfo?.highlightedAchievements.isEmpty ?? true) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(storeInfo?.highlightedAchievements ?? [], id: \.name) { item in
                                VStack(spacing: 6) {
                                    if let path = item.iconPath, let image = LocalImageCache.image(atPath: path) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .frame(width: 56, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    } else {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(skin.accent.opacity(0.16))
                                            .frame(width: 56, height: 56)
                                    }
                                    Text(item.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(width: 88)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if storeInfo?.metacriticScore != nil || !(storeInfo?.genres.isEmpty ?? true) {
                DetailWrap(spacing: 10) {
                    if let score = storeInfo?.metacriticScore {
                        metacriticBadge(score)
                    }
                    ForEach(storeInfo?.genres.prefix(3) ?? [], id: \.self) { genre in
                        tag(genre)
                    }
                }
            }

            // Steam `categories` are already downloaded for the grid; the ones a player decides
            // things on (controller support first - this whole app is built around controllers)
            // rendered as compact chips right under the genre tags. Anything Playdock doesn't
            // specifically recognize just doesn't chip (no cryptic raw store strings).
            if !capabilityChips.isEmpty {
                DetailWrap(spacing: 10) {
                    ForEach(capabilityChips, id: \.label) { chip in
                        Label(L(chip.label), systemImage: chip.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(skin.accent.opacity(0.16), in: Capsule())
                    }
                }
            }
            if let activity = activitySummary {
                Label(activity, systemImage: "gamecontroller")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "18.5 h over 14 sessions · last played 2 days ago" - nil (row hidden) for a game with no
    /// recorded session yet; the card-style empty state would just read as UI clutter here.
    private var activitySummary: String? {
        let total = playActivity.totalSeconds(for: game.appID)
        guard total > 0, let last = playActivity.lastPlayed(game.appID) else { return nil }
        let hours = total / 3600
        let hoursText = hours < 1 ? "\(max(1, Int((total / 60).rounded(.up)))) min" : (hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h")
        let sessions = playActivity.sessionCount(for: game.appID)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.formattingLocale
        let relative = formatter.localizedString(for: last, relativeTo: Date())
        return "\(hoursText) over \(sessions) session\(sessions == 1 ? "" : "s") · last played \(relative)"
    }

    /// The full "About This Game" copy, styled as its own card rather than plain running text.
    /// Falls back to the short description for anything fetched before this field existed, or with
    /// no fuller write-up.
    @ViewBuilder
    private var descriptionCard: some View {
        if let description = aboutText {
            ExpandableAboutCard(
                text: description,
                expanded: descriptionExpanded,
                isFocused: isFocused(.about)
            ) {
                descriptionExpanded.toggle()
            }
        }
    }

    /// Screenshots only. The header art is already the banner, so repeating it here made the
    /// first "screenshot" a copy of the picture at the top of the page.
    private var allPhotoPaths: [String] {
        storeInfo?.screenshotPaths ?? []
    }

    /// The store categories worth a chip up front, in a fixed display order so "Full controller
    /// support" (the decision a controller-first dashboard actually funnels toward) always reads
    /// first for the games that have it.
    private var capabilityChips: [(label: String, icon: String)] {
        let cats = Set(storeInfo?.categories ?? [])
        let known: [(label: String, icon: String, matches: Set<String>)] = [
            ("Full Controller Support", "gamecontroller.fill", ["Full controller support"]),
            ("Controller Support", "gamecontroller", ["Partial Controller Support"]),
            ("Co-op", "person.2.fill", ["Co-op", "Shared/Split Screen Co-op", "Online Co-op", "Local Co-op"]),
            ("Multiplayer", "person.3.fill", ["Multi-player", "Online PvP", "PvP", "Cross-Platform Multiplayer",
                                              "Shared/Split Screen PvP", "LAN PvP", "LAN Co-op"]),
            ("Cloud Saves", "icloud.fill", ["Steam Cloud"]),
            ("Workshop", "hammer.fill", ["Steam Workshop", "Includes level editor"]),
            ("Achievements", "trophy.fill", ["Steam Achievements"]),
            ("Leaderboards", "chart.bar.fill", ["Steam Leaderboards"]),
            ("Remote Play", "play.display", ["Remote Play Together", "Remote Play on TV", "Remote Play on Tablet",
                                             "Remote Play on Phone", "Remote Play on Desktop"]),
            ("HDR", "sun.max.fill", ["HDR available"]),
            ("Family Sharing", "person.2.square.stack.fill", ["Family Sharing"]),
        ]
        var chips: [(label: String, icon: String)] = []
        for entry in known where !cats.isDisjoint(with: entry.matches) {
            chips.append((label: entry.label, icon: entry.icon))
        }
        return chips
    }

    /// True whenever there's actually something to put in `photoGrid`.
    private var hasPhotos: Bool { !allPhotoPaths.isEmpty }

    // MARK: - More like this

    /// Same primary genre, best rated first (Metacritic where known), self excluded. Cached data
    /// only: genre coverage depends on what's already been fetched for some other reason - a
    /// library with thin cache shows a short rail, and that's correct, not a bug to paper over.
    private func reloadSimilarGames() async {
        guard let primaryGenre = storeInfo?.genres.first else { similarGames = []; return }
        var matches: [(SteamGame, String?, Int)] = []
        for candidate in model.steamGames where candidate.appID != game.appID {
            guard let info = await SteamStoreInfoCache.shared.cachedSnapshot(for: candidate.metadataAppID),
                  info.genres.first == primaryGenre else { continue }
            matches.append((candidate, info.headerImagePath, info.metacriticScore ?? -1))
        }
        matches.sort { $0.2 > $1.2 }
        similarGames = Array(matches.prefix(10).map { ($0.0, $0.1) })
    }

    private var moreLikeThis: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("More like this"))
                .font(.headline)
                .foregroundStyle(.primary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(similarGames, id: \.game.appID) { similar in
                        Button {
                            onOpenSimilar(similar.game)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let path = similar.headerPath, let image = LocalImageCache.image(atPath: path) {
                                    Image(nsImage: image)
                                        .resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 148, height: 69)
                                        .skinArtTreatment()
                                        .clipShape(PlaydockCardShape(skin: skin, cornerRadius: min(skin.cardRadius, 8)))
                                } else {
                                    PlaydockCardShape(skin: skin, cornerRadius: min(skin.cardRadius, 8))
                                        .fill(skin.topBarBackground)
                                        .frame(width: 148, height: 69)
                                        .overlay(Image(systemName: "gamecontroller").foregroundStyle(skin.accent.opacity(0.7)))
                                }
                                Text(similar.game.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(width: 148, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }


    // MARK: - Reliability

    /// (failures, trailingFailureStreak) from the recorded launch history, or nil when nothing's
    /// been recorded at all - in which case there is no banner to show.
    private var reliabilitySummary: (total: Int, failures: Int, streak: Int)? {
        guard !launchHistory.isEmpty else { return nil }
        let failures = launchHistory.filter(\.launchErrored)
        var streak = 0
        for record in launchHistory.reversed() {
            if record.launchErrored { streak += 1 } else { break }
        }
        return (launchHistory.count, failures.count, streak)
    }

    private func reloadLaunchHistory() {
        launchHistory = LocalOutcomeTracker.records(for: game.appID)
    }

    /// Closes the app's one unique loop: Playdock sees launches fail (the same recorded evidence
    /// that feeds CompatibilityFinder's local-history source), so right at the failure it offers
    /// the fix - not a log path. Only counts launches through Playdock; anything else never
    /// appears here, by design.
    @ViewBuilder
    private var reliabilityBanner: some View {
        if let summary = reliabilitySummary {
            if summary.streak >= 2 {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("This game has failed its last ") + "\(summary.streak)"
                          + L(" launches from Playdock."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout.weight(.semibold))
                    Text(L("That's usually the engine/graphics configuration, not the game. Let Playdock look up what actually works for this title."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        withAnimation(PlaydockMotion.chrome) { showingCompatibilityFinder.toggle() }
                    } label: {
                        Label(L(showingCompatibilityFinder ? "Hide Compatibility Finder" : "Find a Working Configuration"),
                              systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PlaydockButtonStyle(skinOverride: skin))

                    if showingCompatibilityFinder {
                        FindBestConfigurationSection(itemID: game.appID, itemName: game.name)
                            .padding(.top, 6)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            } else {
                // Quiet positive/mixed signal - no banner chrome for what's working.
                Label(
                    summary.failures == 0
                        ? L("Launched ") + "\(summary.total)" + L(" time(s) from Playdock, no errors.")
                        : L("Reliability: ") + "\(summary.total - summary.failures)/\(summary.total)"
                            + L(" launches OK; a recent attempt failed."),
                    systemImage: summary.failures == 0 ? "checkmark.circle" : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// A sideways filmstrip, the way a launcher shows screenshots. Each frame keeps the whole
    /// picture (fit, not a center crop) so UI in the shot isn't sliced off.
    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(allPhotoPaths, id: \.self) { path in
                        photoThumbnail(path)
                    }
                }
            }
        }
    }

    private func photoThumbnail(_ path: String) -> some View {
        Group {
            if let image = LocalImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 360, height: 202)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { expandedPhotoIndex = allPhotoPaths.firstIndex(of: path) }
            }
        }
    }

    /// A full-size, uncropped look at one photo - tap anywhere (or press Escape/B) to dismiss.
    private func photoLightbox(at index: Int) -> some View {
        PhotoLightboxView(
            paths: allPhotoPaths,
            fullImageURLs: fullImageURLsByPhotoPath,
            index: index,
            onStep: { step in stepExpandedPhoto(by: step) },
            onClose: { expandedPhotoIndex = nil }
        )
    }

    /// Full-resolution source URL per photo path where one exists (screenshots only - the header
    /// art's cached copy is already full size). Parallel to `allPhotoPaths`, keyed by path.
    private var fullImageURLsByPhotoPath: [String: String] {
        var map: [String: String] = [:]
        let shots = storeInfo?.screenshotPaths ?? []
        let fulls = storeInfo?.screenshotFullImageURLs ?? []
        for (path, url) in zip(shots, fulls) { map[path] = url }
        return map
    }

    private func stepExpandedPhoto(by delta: Int) {
        guard let current = expandedPhotoIndex, !allPhotoPaths.isEmpty else { return }
        expandedPhotoIndex = (current + delta + allPhotoPaths.count) % allPhotoPaths.count
    }

    /// Same green/yellow/red convention Steam's own store pages use for Metacritic scores.
    private func metacriticBadge(_ score: Int) -> some View {
        Text("\(score)")
            .font(.callout.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(metacriticColor(score), in: RoundedRectangle(cornerRadius: 5))
    }

    private func metacriticColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50..<75: return .yellow
        default: return .red
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(skin.accent.opacity(0.16), in: Capsule())
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let developers = storeInfo?.developers, !developers.isEmpty {
            parts.append("By \(developers.joined(separator: ", "))")
        }
        if let releaseDate = storeInfo?.releaseDate {
            parts.append("Released \(releaseDate)")
        }
        return parts.joined(separator: "  ·  ")
    }


    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                if runningInfo != nil {
                    RunningBadge(compact: true)
                } else if game.isDownloading {
                    Label("Still downloading in Steam", systemImage: "arrow.down.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if !game.isPreviewSample {
                    Button {
                        onLaunch()
                        model.launchSteamGame(game)
                    } label: {
                        if model.launchingTarget == .game(game.appID) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Launching…")
                            }
                        } else {
                            Label("Launch", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.big(accentOverride: gameAccent))
                    .disabled(model.launchingTarget != nil)
                    .focusRing(isFocused(.launch))
                }
                if !game.isPreviewSample {
                    Button {
                        showingSettings = true
                    } label: {
                        Label(hasCustomSettings ? "Custom Settings" : "Settings", systemImage: hasCustomSettings ? "slider.horizontal.3" : "gearshape")
                    }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                    .focusRing(isFocused(.settings))
                    .popover(isPresented: $showingSettings) {
                        GameSettingsPopover(game: game)
                    }
                }
                Button {
                    model.revealInFinder(installFolderPath)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                .focusRing(isFocused(.reveal))
                Button {
                    model.openStorePage(for: game)
                } label: {
                    Label("Store Page", systemImage: "safari")
                }
                .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                .focusRing(isFocused(.storePage))
            }
            if !game.isPreviewSample {
                HStack(spacing: 10) {
                    Text("Launch with")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(LaunchBackendStore.available(for: game)) { backend in
                            Button(backend.displayName) {
                                model.setLaunchBackend(backend, for: game)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.launchBackend(for: game).displayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(skin.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text(model.launchBackend(for: game).summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var installFolderPath: String { game.installFolderPath }
}

// MARK: - Dashboard theming

/// A quiet, blurred version of the currently-running game's header art behind the whole dashboard -
/// not the macOS desktop, just this window's own background. Subtler than `LaunchOverlayView`
/// (which is the same idea at full intensity while a game is starting up) so the actual dashboard
/// content on top stays perfectly readable.
private struct DashboardBackdropView: View {
    let game: SteamGame
    @EnvironmentObject private var model: AppModel
    @LocalState private var headerImagePath: String?

    var body: some View {
        Group {
            if let headerImagePath, let image = LocalImageCache.image(atPath: headerImagePath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 70)
                    .overlay(.background.opacity(0.82))
            } else {
                Color.clear
            }
        }
        .task(id: "\(game.appID)#\(model.gameInfoGeneration)") {
            headerImagePath = await SteamStoreInfoCache.shared.info(for: game.metadataAppID)?.headerImagePath
        }
    }
}

// MARK: - Launch overlay

/// The full-window "WHOOSH" launch takeover: the game's own header art fills the screen while it
/// starts. Deliberately not a true `matchedGeometryEffect` hero transition from the exact card that
/// was clicked - `GameCardView` lives inside a `LazyVGrid`/`ScrollView`, where a card that hasn't
/// been scrolled into view yet may not have a measured frame for the effect to animate from, which
/// risks a broken-looking animation for a real but relatively rare case. A scale+fade transition
/// (applied by the caller) gets the same "whoosh" feeling reliably instead. Custom games get the
/// exact same treatment via `CustomLaunchOverlayView` below - previously they got nothing at all,
/// so clicking Launch looked like it silently did nothing, easy to mistake for a launch that
/// failed rather than one quietly starting up in the background.
private struct LaunchOverlayView: View {
    let game: SteamGame
    let config: GameModeConfig
    let onDismiss: () -> Void
    @LocalState private var headerImagePath: String?

    var body: some View {
        LaunchOverlayContent(name: game.name, artworkPath: headerImagePath, statusLine: engineSummary, onDismiss: onDismiss)
            .task {
                headerImagePath = await SteamStoreInfoCache.shared.info(for: game.metadataAppID)?.headerImagePath
            }
    }

    /// A native macOS Steam game runs through the real Steam app directly - no Wine, no engine, no
    /// D3D backend involved at all, so showing one here would be actively wrong, not just unused
    /// chrome - "the thing saying d3dmetal on mac steam games is a bit misleading," per live
    /// feedback. Empty (not shown) rather than some other placeholder text.
    private var engineSummary: String {
        let backend = LaunchBackendStore.backend(for: game)
        if backend == .nativeMac { return LaunchBackend.nativeMac.displayName }
        if backend == .steamPlay { return "Steam Play · Steam" }
        guard game.source == .wineBottle else { return "" }
        var parts = [config.engineName ?? "Sikarugir"]
        if config.d3dMetal {
            parts.append("D3DMetal")
        } else if config.dxvk {
            parts.append("DXVK")
        } else if config.dxmt {
            parts.append("DXMT")
        }
        return parts.joined(separator: " • ")
    }
}

/// The same launch takeover for a custom game - no async metadata fetch needed, since its artwork
/// path is already sitting right on the model. `statusLine` names where it's actually launching
/// *from* (Playdock itself, or a specific Sikarugir wrapper app when the launch was delegated to
/// one) instead of an engine/D3D summary, which wouldn't mean anything to a player either way.
private struct CustomLaunchOverlayView: View {
    let game: CustomGame
    let statusLine: String
    let onDismiss: () -> Void

    var body: some View {
        LaunchOverlayContent(name: game.effectiveName, artworkPath: game.effectiveArtworkPath, statusLine: statusLine, onDismiss: onDismiss)
    }
}

private struct LaunchOverlayContent: View {
    let name: String
    let artworkPath: String?
    let statusLine: String
    let onDismiss: () -> Void
    @LocalState private var logTail = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            VStack(spacing: 16) {
                if let artworkPath, let image = LocalImageCache.image(atPath: artworkPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 140)
                }
                Text(name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                LoadingDotsView(message: "Launching")
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !logTail.isEmpty {
                    ScrollView {
                        Text(logTail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                Button("Back to library", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .colorScheme(.dark)
        .onExitCommand { onDismiss() }
        .task {
            while !Task.isCancelled {
                logTail = Self.tail()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private static func tail() -> String {
        guard let path = ExeRunner.lastLogPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n")
        return lines.suffix(12).joined(separator: "\n")
    }
}

// MARK: - Settings

/// The engine/graphics/sync fields shared by both the global "Default Settings" sheet and each
/// game's own settings popover - the exact same controls that used to sit permanently in Game
/// Mode's form, now tucked away for anyone who doesn't need them.
struct GameSettingsFields: View {
    @Binding var config: GameModeConfig

    var body: some View {
        Section("Engine") {
            Picker("Wine engine", selection: $config.engineName) {
                ForEach(SikarugirEngine.availableEngineNames(), id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            Text("These are the same engines already downloaded by Sikarugir Creator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Graphics") {
            Toggle("D3DMETAL", isOn: $config.d3dMetal)
            Toggle("MoltenVK CX", isOn: $config.moltenVKCX)
            Toggle("DXVK", isOn: $config.dxvk)
            Toggle("DXMT", isOn: $config.dxmt)
        }

        Section("Sync") {
            Toggle("Fast Sync (ESYNC + MSYNC)", isOn: $config.fastSync)
        }
    }
}

// MARK: - Per-game settings popover

private struct GameSettingsPopover: View {
    @EnvironmentObject private var model: AppModel
    let game: SteamGame
    @LocalState private var showingExperiment = false

    var body: some View {
        VStack(spacing: 0) {
            Text(game.name)
                .font(.headline)
                .lineLimit(1)
                .padding(14)
            Divider()
            Form {
                Section("Launch") {
                    Picker("Backend", selection: backendBinding) {
                        ForEach(LaunchBackendStore.available(for: game)) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    Text(model.launchBackend(for: game).summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FindBestConfigurationSection(itemID: game.appID, itemName: game.name)
                GameSettingsFields(config: configBinding)
                Button("Use Default Settings") {
                    model.setOverride(nil, for: game)
                }
                .disabled(model.perGameConfigs[game.appID] == nil)

                if game.source == .wineBottle {
                    Section {
                        Button {
                            showingExperiment = true
                        } label: {
                            Label("Experiment", systemImage: "flask")
                        }
                    } footer: {
                        Text("Try a few engine/graphics combinations one at a time and see which actually works.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                InspectSection(itemID: game.appID, itemName: game.name, installPath: installFolderPath)
            }
            .formStyle(.grouped)
        }
        .frame(width: 380, height: 720)
        .sheet(isPresented: $showingExperiment) {
            ExperimentSheet(game: game)
        }
    }

    private var configBinding: Binding<GameModeConfig> {
        Binding(
            get: { model.perGameConfigs[game.appID] ?? model.gameModeConfig },
            set: { model.setOverride($0, for: game) }
        )
    }

    private var backendBinding: Binding<LaunchBackend> {
        Binding(
            get: { model.launchBackend(for: game) },
            set: { model.setLaunchBackend($0, for: game) }
        )
    }

    private var installFolderPath: String { game.installFolderPath }
}

// MARK: - Find Best Configuration

/// "🔎 Find Best Configuration" - pulls public compatibility evidence (AppleGamingWiki, GitHub) plus
/// this Mac's own launch history through `CompatibilityFinder`, and shows the aggregated result.
/// Never applies anything by itself - Apply is always a distinct, explicit tap that goes through the
/// existing `model.setOverride`, the same mechanism the manual settings below already use.
struct FindBestConfigurationSection: View {
    @EnvironmentObject private var model: AppModel
    let itemID: String
    let itemName: String
    @LocalState private var recommendation: CompatibilityRecommendation?
    @LocalState private var isSearching = false
    @LocalState private var showingEvidence = false

    var body: some View {
        Section {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching AppleGamingWiki, GitHub…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let recommendation {
                resultView(recommendation)
            } else {
                Button {
                    search(forceRefresh: false)
                } label: {
                    Label("Find Best Configuration", systemImage: "magnifyingglass.circle")
                }
            }
        } header: {
            Text("Recommended Settings")
        } footer: {
            Text("Looks at public compatibility reports and this Mac's own launch history for this game. Nothing is ever applied automatically - you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultView(_ recommendation: CompatibilityRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(recommendation.confidence.indicator) \(recommendation.confidence.label)")
                    .font(.callout).bold()
                Spacer()
                Button {
                    search(forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if recommendation.confidence == .none {
                Text("Nothing was changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Supported by \(independentSourceCount(recommendation)) independent report(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary(of: recommendation.recommendedSettings))
                    .font(.callout)
            }

            if !recommendation.reports.isEmpty {
                Button(showingEvidence ? "Hide Evidence" : "View Evidence") {
                    showingEvidence.toggle()
                }
                .buttonStyle(.borderless)
                if showingEvidence {
                    evidenceList(recommendation.reports)
                }
            }

            if recommendation.recommendedSettings != nil {
                Button("Apply") {
                    model.setOverride(recommendation.applied(onto: model.config(forID: itemID)), forID: itemID)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }

    private func evidenceList(_ reports: [CompatibilityReport]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.sourceName).font(.caption).bold()
                    Text(report.excerpt).font(.caption2).foregroundStyle(.secondary)
                    if let url = URL(string: report.sourceURL), !report.sourceURL.isEmpty {
                        Link(report.sourceURL, destination: url).font(.caption2)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func independentSourceCount(_ recommendation: CompatibilityRecommendation) -> Int {
        Set(recommendation.reports.map(\.sourceName)).count
    }

    private func summary(of settings: DetectedSettings?) -> String {
        guard let settings else { return "No changes to your current settings." }
        var parts: [String] = []
        if let v = settings.d3dMetal { parts.append("D3DMetal \(v ? "on" : "off")") }
        if let v = settings.dxvk { parts.append("DXVK \(v ? "on" : "off")") }
        if let v = settings.dxmt { parts.append("DXMT \(v ? "on" : "off")") }
        if let v = settings.moltenVKCX { parts.append("MoltenVK CX \(v ? "on" : "off")") }
        if let v = settings.wineESync { parts.append("ESync \(v ? "on" : "off")") }
        if let v = settings.wineMSync { parts.append("MSync \(v ? "on" : "off")") }
        return parts.isEmpty ? "No changes to your current settings." : parts.joined(separator: " · ")
    }

    private func search(forceRefresh: Bool) {
        isSearching = true
        Task {
            let result = await CompatibilityFinder.shared.recommendation(id: itemID, name: itemName, forceRefresh: forceRefresh)
            await MainActor.run {
                recommendation = result
                isSearching = false
            }
        }
    }
}

// MARK: - Inspect

/// "🔬 Inspect" - a read-only assembly of data Playdock already has, plus `RunningGameTracker` for
/// the live PID. No new data sources here, just a presentation layer.
struct InspectSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    let itemID: String
    let itemName: String
    let installPath: String

    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[itemID] }
    private var config: GameModeConfig { model.config(forID: itemID) }

    var body: some View {
        Section("Inspect") {
            DisclosureGroup("Process") {
                if let runningInfo {
                    LabeledContent("Status", value: "Running (PID \(runningInfo.pid))")
                    LabeledContent("Started", value: runningInfo.startedAt.formatted(date: .omitted, time: .shortened))
                } else {
                    LabeledContent("Status", value: "Not running")
                }
            }
            DisclosureGroup("Wine") {
                LabeledContent("Engine", value: config.engineName ?? "Auto (recommended)")
            }
            DisclosureGroup("Graphics") {
                LabeledContent("D3DMetal", value: config.d3dMetal ? "On" : "Off")
                LabeledContent("DXVK", value: config.dxvk ? "On" : "Off")
                LabeledContent("DXMT", value: config.dxmt ? "On" : "Off")
                LabeledContent("MoltenVK CX", value: config.moltenVKCX ? "On" : "Off")
            }
            DisclosureGroup("Files") {
                Text(installPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    model.revealInFinder(installPath)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Loading

/// A simple three-dot bounce, the same shape as most chat/loading indicators - used wherever Game
/// Mode has no content shape to show a skeleton of yet (installing Steam itself).
private struct LoadingDotsView: View {
    let message: String
    @LocalState private var isAnimating = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(y: isAnimating ? -8 : 0)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(index) * 0.15),
                            value: isAnimating
                        )
                }
            }
            .frame(height: 24)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .onAppear { isAnimating = true }
    }
}

/// A shimmering stand-in for a `GameCardView`, shown in the same grid the real cards land in while
/// the Steam library scan is still running.
private struct GameCardSkeleton: View {
    @LocalState private var isShimmering = false

    private var shimmerColor: Color {
        Color.secondary.opacity(isShimmering ? 0.22 : 0.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(shimmerColor).frame(height: 140)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(shimmerColor).frame(width: 150, height: 20)
                RoundedRectangle(cornerRadius: 4).fill(shimmerColor).frame(height: 10)
                RoundedRectangle(cornerRadius: 4).fill(shimmerColor).frame(width: 100, height: 10)
                RoundedRectangle(cornerRadius: 12).fill(shimmerColor).frame(height: 50).padding(.top, 4)
            }
            .padding(16)
        }
        .cardSurface()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isShimmering = true
            }
        }
    }
}

// MARK: - Photo lightbox

/// Full-window photo viewer for a game's screenshots: browsable with the on-screen arrows or a
/// controller's D-pad (one photo at a time, wrapping), and it lazily swaps each cached thumbnail
/// for its full-resolution original the moment that page is actually opened, falling back to the
/// cached copy if the server (or the network) doesn't cooperate. Closing: Esc / the X / a
/// controller's secondary button / tapping the backdrop.
private struct PhotoLightboxView: View {
    let paths: [String]
    let fullImageURLs: [String: String]
    let index: Int
    let onStep: (Int) -> Void
    let onClose: () -> Void

    // `@LocalState`, not `@State`: this repo builds with bare Command Line Tools, where the
    // SwiftUI macro plugin that powers `@State` isn't wired up - every view in the codebase uses
    // the hand-rolled equivalent for exactly that reason.
    @LocalState private var fullImage: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            Group {
                if let fullImage {
                    Image(nsImage: fullImage).resizable().aspectRatio(contentMode: .fit)
                } else if let cached = LocalImageCache.image(atPath: paths[index]) {
                    Image(nsImage: cached).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .padding(60)
            .id(index) // reset per-photo so one shot's failed load never sticks to the next
            .task(id: index) { await loadFullSize(index) }

            if paths.count > 1 {
                HStack {
                    lightboxArrow(systemName: "chevron.left") { onStep(-1) }
                    Spacer()
                    lightboxArrow(systemName: "chevron.right") { onStep(1) }
                }
                .padding(.horizontal, 20)
            }

            VStack {
                HStack {
                    Spacer()
                    Text("\(index + 1) of \(paths.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(24)
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onExitCommand { onClose() }
    }

    private func lightboxArrow(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Fetch the full-size original through `URLCache` (disk-backed): first open costs one real
    /// request, every later open of the same shot is local. A failure just keeps the thumbnail.
    private func loadFullSize(_ index: Int) async {
        guard let urlString = fullImageURLs[paths[index]], let url = URL(string: urlString) else { return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = NSImage(data: data) else { return }
        fullImage = image
    }
}
