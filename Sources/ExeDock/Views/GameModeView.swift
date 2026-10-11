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

/// Every controller-focusable spot on the main dashboard - the toolbar (Refresh/Settings), a card
/// in the grid, or the floating Steam icon - covering "every clickable thing," not just the grid.
private enum DashboardFocusTarget: Equatable {
    case toolbar(Int) // 0 = Refresh, 1 = Settings
    case card(Int)
    case steamIcon
}

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
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("com.exedock.advancedMode") private var isAdvancedMode = false
    @AppStorage(LibraryLayoutStyle.storageKey) private var libraryLayoutRaw = LibraryLayoutStyle.grid.rawValue
    private var libraryLayout: LibraryLayoutStyle { LibraryLayoutStyle(rawValue: libraryLayoutRaw) ?? .grid }
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    /// "add a hide steam icon launcher option," per live feedback - the floating icon also kept
    /// grabbing controller focus unexpectedly (see `moveFocus`'s own doc comment on the real bug
    /// that came from), so letting someone turn it off entirely addresses both complaints, not just
    /// the visual one.
    static let showSteamIconKey = "com.exedock.showSteamIcon"
    @AppStorage(GameModeView.showSteamIconKey) private var showSteamIcon = true
    /// "a setting to hide labels" - one global switch for every Custom/Mac/Windows badge, native
    /// layouts and the WebView-rendered ones alike, rather than a per-badge-kind toggle nobody
    /// asked for. Nothing reads this yet - a separate, later piece wires it into the actual badge
    /// display sites.
    static let hideBadgesKey = "com.exedock.hideLibraryBadges"
    @AppStorage(GameModeView.hideBadgesKey) private var hideLibraryBadges = false
    /// The floating Settings launcher's shown/minimized state - `true` is the full pill, `false`
    /// collapses it to an edge tab, exactly the way `showSteamIcon` works for the Steam icon.
    @AppStorage(SettingsLauncher.showLauncherKey) private var showSettingsLauncher = true
    @LocalState private var search = ""
    /// Drives the full-window `SettingsPanelView` overlay (it used to be a small `.sheet`).
    @LocalState private var showingSettings = false
    @LocalState private var showingAddGameSheet = false
    @LocalState private var sortOption: GameSortOption = .name
    @LocalState private var launchOverlayGame: SteamGame?
    @LocalState private var launchOverlayCustomGame: CustomGame?
    @LocalState private var showingControllerMode = false
    @LocalState private var detailGame: SteamGame?
    @LocalState private var detailCustomGame: CustomGame?
    /// Everywhere a controller's D-pad can currently be focused on the dashboard - the toolbar
    /// (Refresh/Settings), a card in the grid, or the floating Steam icon. `nil` until the first
    /// D-pad press (mouse-only browsing shows no ring at all).
    @LocalState private var focusedTarget: DashboardFocusTarget?
    /// The grid's own measured width - used only for controller D-pad row math (`columnCount`), not
    /// the grid's actual rendering (that's plain `.adaptive`, handled natively by SwiftUI). See
    /// `gridColumns`'s own doc comment for why this split matters.
    @LocalState private var gridWidth: CGFloat = 0
    /// Resolved art/genre/description per entry, feeding the real WebView-rendered grid
    /// (`SkinWebGridView`) - kept independently of the native layouts' own per-tile resolution so a
    /// game's info only ever needs to be fetched once regardless of which structure is on screen.
    @LocalState private var libraryPresentations: [String: LibraryPresentation] = [:]

    private enum GameSortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case recentlyUpdated = "Recently Updated"
        var id: String { rawValue }
    }

    private var filteredGames: [SteamGame] {
        let filtered = search.isEmpty ? model.steamGames : model.steamGames.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyUpdated:
            return filtered.sorted { ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast) }
        }
    }

    /// The unified grid content - Steam games plus manually-imported custom games, searched and
    /// sorted together. Steam-only concerns (the launch overlay, dashboard backdrop theming) stay
    /// keyed off `model.steamGames`/`filteredGames` directly; this is specifically what the grid
    /// itself, and controller focus over it, iterate.
    private var libraryEntries: [LibraryEntry] {
        let all = model.steamGames.map(LibraryEntry.steam) + model.customGames.map(LibraryEntry.custom)
        let filtered = search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyUpdated:
            return filtered.sorted { $0.sortDate > $1.sortDate }
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
            return SkinWebGridEntry(
                id: entry.id,
                title: entry.name,
                genre: presentation?.genre ?? "",
                desc: presentation?.description ?? "",
                art: SkinWebArt.dataURI(forImagePath: presentation?.artPath),
                custom: isCustom,
                mac: isMac,
                running: runningTracker.runningGames[entry.id] != nil,
                size: sizeText,
                hours: nil
            )
        }
    }

    /// Resolves every entry currently in the library concurrently (already-resolved entries are
    /// skipped, so this stays cheap on repeat calls) - driven by a `.task(id:)` keyed on the actual
    /// set of entry ids, so adding/removing a game re-resolves only what's actually new.
    private func resolveLibraryPresentations() async {
        await withTaskGroup(of: (String, LibraryPresentation).self) { group in
            for entry in libraryEntries where libraryPresentations[entry.id] == nil {
                group.addTask { (entry.id, await LibraryPresentation.resolve(entry)) }
            }
            for await (id, presentation) in group {
                libraryPresentations[id] = presentation
            }
        }
    }

    var body: some View {
        if !model.isGameModeUnlocked {
            lockedState
        } else {
            dashboard
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        VStack(spacing: 24) {
            if model.isInstallingSteam {
                LoadingDotsView(message: installingMessage)
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Your games live here once Steam is installed.")
                    .font(.title2)
                Button("Install & Run Steam") {
                    model.installAndRunSteam()
                }
                .buttonStyle(.big)
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                header
                if controllerObserver.isConnected && !controllerObserver.bannerDismissed {
                    controllerBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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
                    .task(id: libraryEntries.map(\.id)) {
                        await resolveLibraryPresentations()
                    }
                } else if libraryLayout == .steam || libraryLayout == .spotlight {
                    // These two embed a real, WKWebView-rendered card grid for their own
                    // grid-shaped region (see SkinWebGridFragmentView) rather than a native
                    // SwiftUI approximation - it needs the same real presentations Grid's own
                    // webGridEntries reads from.
                    alternateLayout
                        .task(id: libraryEntries.map(\.id)) {
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
            .padding(.bottom, isDashboardTheActiveControllerLayer && controllerObserver.isConnected ? Self.legendBarHeight : 0)
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

            if let detailGame {
                GameDetailView(game: detailGame, isAdvancedMode: isAdvancedMode) {
                    self.detailGame = nil
                } onLaunch: {
                    self.detailGame = nil
                    launchOverlayGame = detailGame
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .zIndex(1)
            }

            if let detailCustomGame {
                CustomGameDetailView(game: detailCustomGame, isAdvancedMode: isAdvancedMode) {
                    self.detailCustomGame = nil
                } onLaunch: {
                    self.detailCustomGame = nil
                    launchOverlayCustomGame = detailCustomGame
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .zIndex(1)
            }

            if let launchOverlayGame {
                LaunchOverlayView(game: launchOverlayGame, config: model.config(for: launchOverlayGame))
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(1)
            }

            if let launchOverlayCustomGame {
                CustomLaunchOverlayView(
                    game: launchOverlayCustomGame,
                    statusLine: "Launching via \(model.resolvedBottle(forExePath: launchOverlayCustomGame.exePath).name)…"
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                .zIndex(1)
            }

            if showingControllerMode {
                ControllerModeView {
                    showingControllerMode = false
                }
                .transition(.opacity)
                .zIndex(2)
            }

            settingsOverlay
        }
        .animation(.easeInOut(duration: 0.2), value: model.launchingTarget)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: launchOverlayGame?.appID)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: launchOverlayCustomGame?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: detailGame?.appID)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: detailCustomGame?.id)
        .animation(.easeInOut(duration: 0.4), value: themedGame?.appID)
        .animation(.easeInOut(duration: 0.25), value: showingControllerMode)
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
        .onChange(of: model.customGames) { _ in
            runningTracker.syncWatchedGames(watchTargets)
        }
        .onAppear {
            runningTracker.syncWatchedGames(watchTargets)
        }
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard isDashboardTheActiveControllerLayer, let direction = controllerObserver.directionPress?.direction else { return }
            moveFocus(direction)
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            guard isDashboardTheActiveControllerLayer else { return }
            activateFocusedTarget()
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

    private var controllerBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
            Text("Controller connected")
            Spacer()
            Button("Enter Controller Mode") {
                showingControllerMode = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    controllerObserver.bannerDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
    }

    /// Deliberately tiny and unobtrusive, so the games grid gets as much of the window as
    /// possible. Just enough to identify whose library this is and
    /// offer Refresh/Settings; everything else (art, ratings, controller navigation) lives in the
    /// grid and the Game Detail view instead of competing for space up here.
    private var header: some View {
        HStack(spacing: 10) {
            profileAvatar
            SkinTitleText(text: model.steamProfile?.personaName ?? "Steam", size: 17, lineLimit: 1)
            Text(model.steamGames.isEmpty ? "No games installed" : "\(model.steamGames.count) game\(model.steamGames.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Grouped under one shared, skin-tinted backing instead of floating as separate bordered
            // controls, matching the rest of the top bar's own look. Sort lives
            // here rather than inside the grid's own content now - the Grid layout's search/sort
            // strip was replaced by each skin's own real, functional topbar search field (see
            // `SkinWebGridView`), but sort has no equivalent in any of the ten mockups (a real app
            // capability the mockups never needed), so it stays as native chrome alongside
            // Add/Refresh/Settings instead of being dropped - it still governs every layout's
            // ordering, not just Grid's.
            HStack(spacing: 6) {
                sortMenu
                headerIconButton(systemImage: "plus", help: "Add Game", isFocused: controllerObserver.isConnected && focusedTarget == .toolbar(0)) {
                    showingAddGameSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                headerIconButton(systemImage: "arrow.clockwise", help: "Refresh", isFocused: controllerObserver.isConnected && focusedTarget == .toolbar(1)) {
                    model.refreshSteamGames()
                    model.refreshSteamProfile()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoadingSteamGames)

                headerIconButton(systemImage: "gearshape", help: "Settings", isFocused: controllerObserver.isConnected && focusedTarget == .toolbar(2)) {
                    openSettings()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(skin.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: skin.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: skin.cardRadius, style: .continuous)
                    .strokeBorder(skin.accent.opacity(0.18), lineWidth: skin.borderWidth)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // "make sure the top bar matches (the account and sort part) the colour etc." - this used
        // to be a generic `.bar` material with just an accent-colored bottom rule standing in for
        // real theming. Now the exact same real `.topbar` background/border/glow every other
        // themed chrome row in the app uses (`PlaydockSkin.topBarBackground`'s own doc comment has
        // the real per-skin CSS values this ports), not an approximation.
        .background(skin.topBarBackground)
        .overlay(alignment: .bottom) {
            if let borderColor = skin.topBarBorderColor {
                Rectangle()
                    .fill(borderColor)
                    .frame(height: skin.topBarBorderWidth)
                    .shadow(color: skin.topBarHasGlow ? skin.accent.opacity(0.7) : .clear, radius: 6, y: 2)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: skinRaw)
    }

    /// "make the sorting part on the top way better visually" - the plain native `Picker` this
    /// replaced rendered as bare system menu chrome with no relationship to the active skin at
    /// all. A themed pill - icon, current value, chevron - in the skin's own accent, matching the
    /// same capsule/border language `PlaydockButtonStyle`'s compact buttons already use elsewhere.
    private var sortMenu: some View {
        Menu {
            ForEach(GameSortOption.allCases) { option in
                Button {
                    sortOption = option
                } label: {
                    if option == sortOption {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                Text(sortOption.rawValue)
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .fontDesign(skin.fontDesign)
            .foregroundStyle(skin.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(skin.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(skin.accent.opacity(0.3), lineWidth: skin.borderWidth))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: sortOption)
    }

    /// A soft rounded-square, icon-only button - used for the header's secondary actions
    /// (Refresh/Settings), and generally sized big enough to be an easy, unambiguous target for a
    /// controller cursor as well as a mouse.
    private func headerIconButton(systemImage: String, help: String, isFocused: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .focusRing(isFocused)
        .help(help)
    }

    /// The way to open Steam itself - double-click, the same gesture as opening anything else on a
    /// Mac. Floats over the bottom-right corner of the whole dashboard (moved off a big centered
    /// tile that used to take up nearly half the screen, then off the header entirely), always
    /// reachable without competing for
    /// space with anything else in the layout. Uses Steam's own real icon when the native Mac
    /// Steam.app is present on this machine (legitimately already installed by the user, same as
    /// how AppIconProvider reads any other already-installed app's icon) - falling back to an
    /// in-house glyph otherwise, since NSWorkspace can't extract an icon from a .exe buried in a
    /// private, never-Finder-indexed Wine bottle. Shows exactly one spinner, right on the icon,
    /// while launching.
    private static let nativeSteamAppPath = "/Applications/Steam.app"

    /// One continuous view for both the full icon and its collapsed edge tab - "it disappears for
    /// a second... should be smooth, like when you minimize your window on macOS," a real,
    /// confirmed gap from the previous version, which swapped between two entirely separate views
    /// (one unmounting before the other finished mounting). Both states' content stay mounted the
    /// whole time and simply cross-fade while the shared container smoothly resizes/reshapes under
    /// them, so there's never a frame where neither is visible.
    private var steamFloatingIcon: some View {
        let isLaunching = model.launchingTarget == .steam
        let collapsed = !showSteamIcon
        // A real, confirmed layout bug in the first version of this: the full-icon content kept
        // an unconditional 200x200 frame even while "collapsed," so the ZStack's own natural size
        // never actually matched the smaller frame this whole view was told to report - the
        // outer .frame() call can change what size a view *reports upward*, but it doesn't reflow
        // topLeading-aligned children that still think they have 200x200 to lay out in, which is
        // exactly why the collapsed tab landed somewhere unreachable/invisible instead of neatly
        // docked to the edge. Every child below now sizes itself to this *same* pair of numbers,
        // so there's only ever one real size in play, not two disagreeing ones.
        let width: CGFloat = collapsed ? 34 : 200
        let height: CGFloat = collapsed ? 116 : 200

        return ZStack(alignment: .topLeading) {
            ZStack {
                steamIcon(size: 200, cornerRadius: 44)
                    .opacity(isLaunching ? 0.3 : 1)
                if isLaunching {
                    ProgressView().controlSize(.large).scaleEffect(1.8)
                }
            }
            .frame(width: width, height: height)
            .contentShape(RoundedRectangle(cornerRadius: 44))
            // No .pressPush()/other gesture-based press effect here on purpose - a real bug, found
            // live: a simultaneous zero-distance DragGesture (which is what that press effect used to
            // detect "pressed") competing with .onTapGesture(count: 2) on the same view could silently
            // swallow the double-click recognition entirely, so double-clicking did nothing at all - no
            // spinner, no launch. The isLaunching-driven opacity/spinner above is the only feedback
            // this needs.
            .onTapGesture(count: 2) {
                model.openSteamClient()
            }
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed && model.launchingTarget == nil)
            .focusRing(controllerObserver.isConnected && focusedTarget == .steamIcon)
            .help(isLaunching ? "Launching Steam…" : "Double-click to open Steam")

            // "dont see the minimalize the steam icon button" - the Settings toggle alone wasn't
            // discoverable enough; a small, always-visible control right on the icon itself is the
            // real fix.
            if !isLaunching {
                Button {
                    showSteamIcon = false
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(!collapsed)
                .help("Collapse the Steam icon to the edge")
            }

            // The collapsed edge tab - "should be on the edge but still expandable," not gone
            // entirely. Always mounted (see this whole property's own doc comment above), just
            // invisible/non-interactive while expanded.
            Button {
                showSteamIcon = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                    steamIcon(size: 26, cornerRadius: 7)
                        .frame(width: 26, height: 26)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .frame(width: width, height: height)
            }
            .buttonStyle(.plain)
            .opacity(collapsed ? 1 : 0)
            .allowsHitTesting(collapsed)
            .help("Show the Steam icon")
        }
        .frame(width: width, height: height, alignment: .topTrailing)
        .background(
            .regularMaterial,
            in: collapsed ? AnyShape(LeftRoundedRect(radius: 16)) : AnyShape(RoundedRectangle(cornerRadius: 44))
        )
        .clipShape(collapsed ? AnyShape(LeftRoundedRect(radius: 16)) : AnyShape(RoundedRectangle(cornerRadius: 44)))
        .shadow(color: .black.opacity(collapsed ? 0.3 : 0.35), radius: collapsed ? 12 : 20, x: collapsed ? -2 : 0, y: collapsed ? 0 : 8)
        // Flush against the real trailing edge while collapsed - "should be on the edge" - a
        // fixed 24pt inset only while expanded, matching the padding this always had.
        .padding(.trailing, collapsed ? 0 : 24)
        .padding(.bottom, collapsed ? 40 : 24)
        .animation(.easeInOut(duration: 0.3), value: showSteamIcon)
    }

    @ViewBuilder
    private func steamIcon(size: CGFloat, cornerRadius: CGFloat) -> some View {
        if FileManager.default.fileExists(atPath: Self.nativeSteamAppPath) {
            Image(nsImage: AppIconProvider.icon(forPath: Self.nativeSteamAppPath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.53, green: 0.33, blue: 0.96), Color(red: 0.16, green: 0.18, blue: 0.52)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.white)
                )
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }

    // MARK: - Floating corner controls

    /// Neither floating control should take clicks while any full-screen overlay (a game's detail
    /// view, a launch overlay, Controller Mode) is up over the dashboard.
    private var noDashboardOverlayActive: Bool {
        detailGame == nil && detailCustomGame == nil && launchOverlayGame == nil
            && launchOverlayCustomGame == nil && !showingControllerMode
    }

    /// The Steam icon and the Settings launcher, both docked bottom-right, kept in their own
    /// container so the main `body` ZStack stays inside the Swift type-checker's budget. Not wired
    /// into `body` yet - see the follow-up commit that replaces the old `steamFloatingIcon` call
    /// site with this.
    private var cornerFloaters: some View {
        ZStack(alignment: .bottomTrailing) {
            steamFloatingIcon
                .allowsHitTesting(noDashboardOverlayActive)
            settingsFloatingLauncher
                .allowsHitTesting(noDashboardOverlayActive && !showingSettings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.3), value: showSteamIcon)
        .animation(.easeInOut(duration: 0.3), value: showSettingsLauncher)
    }

    @ViewBuilder
    private var settingsOverlay: some View {
        if showingSettings {
            SettingsPanelView {
                withAnimation(.easeInOut(duration: 0.25)) { showingSettings = false }
            }
            .transition(.opacity)
            .zIndex(3)
        }
    }

    private func openSettings() {
        withAnimation(.easeInOut(duration: 0.25)) { showingSettings = true }
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
        let bottomInset: CGFloat = showSteamIcon ? (24 + 200 + 14) : (40 + 116 + 12)
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
        .padding(.trailing, collapsed ? 0 : 22)
        .padding(.bottom, bottomInset)
        .animation(.easeInOut(duration: 0.3), value: showSettingsLauncher)
    }

    private var profileAvatar: some View {
        Group {
            if let avatarPath = model.steamProfile?.avatarPath, let image = LocalImageCache.image(atPath: avatarPath) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .hoverSpin()
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your games", text: $search)
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

            Picker("Sort", selection: $sortOption) {
                ForEach(GameSortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
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
    /// auto-fill,minmax(250px,1fr));gap:24px;}` in skins.css, a fixed 250px/24px regardless of how
    /// many entries there are - not `idealCardSizeTier` (a *different*, count-dependent sizing table
    /// that only ever applied to the native `GameCardView` grid, which nothing renders anymore).
    /// Using the wrong constants here doesn't break the actual grid, but it does make the D-pad ring
    /// jump to a visually wrong row - exactly the kind of thing that reads as "navigation is broken"
    /// even though the mechanism underneath works.
    private static let webCardMinWidth: CGFloat = 250
    private static let webCardGap: CGFloat = 24
    private var columnCount: Int {
        guard gridWidth > 0 else { return 1 }
        return max(1, Int((gridWidth + Self.webCardGap) / (Self.webCardMinWidth + Self.webCardGap)))
    }

    private var artworkHeight: CGFloat { idealCardSizeTier.artworkHeight }

    /// Only active while nothing's covering the dashboard (no Game Detail view, no Controller Mode
    /// carousel) - both of those own the same D-pad/A stream the instant they're shown, per
    /// `ControllerObserver`'s "single owner, self-filtering subscribers" design.
    private var isDashboardTheActiveControllerLayer: Bool {
        detailGame == nil && detailCustomGame == nil && !showingControllerMode && !showingSettings
    }

    /// `focusedTarget`'s own `.card` index, resolved to that entry's real id, for `SkinWebGridView`'s
    /// `focusedID` - `nil` for every other target (toolbar, Steam icon) or while no controller is
    /// connected, so the WebView only ever shows a ring while there's a real card focused for it to
    /// show.
    private var focusedCardID: String? {
        guard controllerObserver.isConnected, case .card(let index) = focusedTarget else { return nil }
        return libraryEntries[safe: index]?.id
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
        guard let current = focusedTarget else {
            focusedTarget = libraryEntries.isEmpty ? .toolbar(0) : .card(0)
            return
        }
        switch current {
        case .toolbar(let toolbarIndex):
            switch direction {
            case .left: focusedTarget = .toolbar(max(0, toolbarIndex - 1))
            case .right: focusedTarget = .toolbar(min(2, toolbarIndex + 1))
            case .down: focusedTarget = libraryEntries.isEmpty ? current : .card(0)
            case .up: break
            }
        case .card(let index):
            let columns = columnCount
            switch direction {
            case .left:
                guard index % columns != 0 else { return }
                focusedTarget = .card(index - 1)
            case .right:
                guard index % columns != columns - 1, index + 1 < libraryEntries.count else { return }
                focusedTarget = .card(index + 1)
            case .up:
                focusedTarget = index < columns ? .toolbar(0) : .card(index - columns)
            case .down:
                // A real, confirmed bug: "steam launch should be very bottom, as it makes
                // navigation weird as it keeps popping to there" - every card in an incomplete
                // last row (not just the actual last one) used to warp straight to the Steam icon
                // on a single Down press, since `next` lands past the end of the array for any of
                // them, not just the true bottom-right card. Now only the genuine last card - the
                // one actually adjacent to the floating icon - can reach it; every other last-row
                // card with empty space below it just stays put, matching what a real grid with
                // nothing underneath should do.
                let next = index + columns
                if next < libraryEntries.count {
                    focusedTarget = .card(next)
                } else if index == libraryEntries.count - 1 && showSteamIcon {
                    focusedTarget = .steamIcon
                }
            }
        case .steamIcon:
            if direction == .up {
                focusedTarget = libraryEntries.isEmpty ? .toolbar(0) : .card(libraryEntries.count - 1)
            }
        }
    }

    private func activateFocusedTarget() {
        switch focusedTarget {
        case .toolbar(0):
            showingAddGameSheet = true
        case .toolbar(1):
            guard !model.isLoadingSteamGames else { return }
            model.refreshSteamGames()
            model.refreshSteamProfile()
        case .toolbar:
            openSettings()
        case .card(let index):
            guard libraryEntries.indices.contains(index) else { return }
            switch libraryEntries[index] {
            case .steam(let game): detailGame = game
            case .custom(let game): detailCustomGame = game
            }
        case .steamIcon:
            guard showSteamIcon, model.launchingTarget == nil else { return }
            model.openSteamClient()
        case nil:
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
                    let isFocused = controllerObserver.isConnected && focusedTarget == .card(index)
                    switch entry {
                    case .steam(let game):
                        GameCardView(
                            game: game, isAdvancedMode: isAdvancedMode, artworkHeight: artworkHeight,
                            isFocused: isFocused
                        ) {
                            launchOverlayGame = game
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
                            launchOverlayCustomGame = customGame
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
        switch libraryLayout {
        case .grid: EmptyView() // unreachable - handled above
        case .shelves: LibraryShelvesLayout(entries: libraryEntries, onOpenDetail: openDetail)
        case .sidebar: LibrarySidebarLayout(entries: libraryEntries, onOpenDetail: openDetail)
        case .steam: LibrarySteamStyleLayout(entries: libraryEntries, webGridEntries: webGridEntries, skin: skin, isDark: systemColorScheme == .dark, focusedID: focusedCardID, onOpenDetail: openDetail)
        case .carousel: LibraryCarouselLayout(entries: libraryEntries, onOpenDetail: openDetail)
        case .spotlight: LibrarySpotlightLayout(entries: libraryEntries, webGridEntries: webGridEntries, skin: skin, isDark: systemColorScheme == .dark, focusedID: focusedCardID, onOpenDetail: openDetail)
        }
    }

    private var emptyGamesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No games installed yet")
                .font(.title3).bold()
            Text("Install something from the Steam store, or use \u{201C}+\u{201D} above to add a game you already have.")
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
            if runningInfo == nil {
                Button {
                    onLaunch()
                    model.launchSteamGame(game)
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
        .task(id: game.appID) {
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
    case launch, settings, reveal, storePage
}

struct GameDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    let game: SteamGame
    let isAdvancedMode: Bool
    let onClose: () -> Void
    let onLaunch: () -> Void
    @LocalState private var storeInfo: SteamStoreInfo?
    @LocalState private var showingSettings = false
    /// Which action a controller's D-pad currently has highlighted - only ever shown/used while a
    /// controller is actually connected (see `availableActions`'s call sites), so mouse-only use
    /// never sees a stray focus ring.
    @LocalState private var focusedActionIndex = 0
    /// Non-nil while a photo is shown full-size over everything else.
    @LocalState private var expandedImagePath: String?
    @LocalState private var gameAccent: Color?

    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[game.appID] }
    private var hasCustomSettings: Bool { model.perGameConfigs[game.appID] != nil }

    /// Exactly the same conditions `actionRow` already uses to decide what to show - kept as one
    /// list so controller focus always lines up with what's actually on screen (e.g. never
    /// highlights a Settings button that isn't rendered outside Advanced Mode).
    private var availableActions: [DetailAction] {
        var actions: [DetailAction] = []
        if runningInfo == nil { actions.append(.launch) }
        // A native macOS Steam game has no ExeDock-managed wine bottle/engine to configure.
        if isAdvancedMode && game.source == .wineBottle { actions.append(.settings) }
        actions.append(.reveal)
        actions.append(.storePage)
        return actions
    }

    private func isFocused(_ action: DetailAction) -> Bool {
        controllerObserver.isConnected && availableActions[safe: focusedActionIndex] == action
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
        case .launch:
            onLaunch()
            model.launchSteamGame(game)
        case .settings:
            showingSettings = true
        case .reveal:
            model.revealInFinder(installFolderPath)
        case .storePage:
            model.openStorePage(for: game)
        case nil:
            break
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                closeButton
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        // Photos sit in their own column to the right of the text, not stacked
                        // below it.
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 22) {
                                actionRow
                                descriptionCard
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if hasPhotos {
                                photoGrid
                            }
                        }
                    }
                    .padding(32)
                    // The double .frame() is deliberate, not redundant: the first caps the content
                    // column's own width so it stays readable at 1320pt; the second then re-expands
                    // that capped block to fill whatever width the ScrollView actually has and
                    // re-applies leading alignment *within* that full width. A single
                    // `.frame(maxWidth: 1320, alignment: .leading)` only caps the view's own size -
                    // it doesn't reliably left-anchor it against a wider ancestor, which is exactly
                    // what put this content off-screen entirely: confirmed live, content rendering
                    // well past the left edge of the window with no way to reach the close button.
                    .frame(maxWidth: 1320, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let expandedImagePath {
                imageLightbox(expandedImagePath)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .colorScheme(.dark)
        .task(id: game.appID) {
            storeInfo = await SteamStoreInfoCache.shared.info(for: game.metadataAppID)
            if let path = storeInfo?.headerImagePath { gameAccent = await GameArtColor.dominantColor(forImagePath: path) }
        }
        .onExitCommand { onClose() }
        // GameDetailView always treats itself as the active controller-input layer while it's
        // mounted - it's rendered above everything else wherever it appears (a direct card tap, or
        // ControllerModeView's own drill-down), so there's nothing above it to defer to.
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard expandedImagePath == nil, let direction = controllerObserver.directionPress?.direction else { return }
            moveActionFocus(direction)
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            guard expandedImagePath == nil else { return }
            activateFocusedAction()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            // Back out one level at a time - close the expanded photo first if one's open, the
            // whole detail view otherwise.
            if expandedImagePath != nil {
                expandedImagePath = nil
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                // A real solid backing, not just the SF Symbol's own faint built-in shadow layer -
                // busy, high-contrast game art (bright whites, bold text baked into the artwork
                // itself) could wash the old icon-only close button out almost completely, leaving
                // no visible way out of a detail view.
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .padding(24)
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let path = storeInfo?.backgroundImagePath ?? storeInfo?.headerImagePath, let image = LocalImageCache.image(atPath: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 50)
                .overlay(Color.black.opacity(0.6))
                .ignoresSafeArea()
        } else {
            LinearGradient(colors: [Color.accentColor.opacity(0.5), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkinTitleText(text: game.name, size: 34)
                .foregroundStyle(.white)
            if storeInfo?.metacriticScore != nil || !(storeInfo?.genres.isEmpty ?? true) {
                HStack(spacing: 10) {
                    if let score = storeInfo?.metacriticScore {
                        metacriticBadge(score)
                    }
                    ForEach(storeInfo?.genres.prefix(3) ?? [], id: \.self) { genre in
                        tag(genre)
                    }
                }
            }
            if !subtitleLine.isEmpty {
                Text(subtitleLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// The full "About This Game" copy, styled as its own card rather than plain running text.
    /// Falls back to the short description for anything fetched before this field existed, or with
    /// no fuller write-up.
    @ViewBuilder
    private var descriptionCard: some View {
        if let description = storeInfo?.aboutTheGame ?? storeInfo?.shortDescription {
            VStack(alignment: .leading, spacing: 10) {
                Text("About This Game")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(description)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        }
    }

    /// Header art first, then every screenshot, in that order - the one list both `hasPhotos` and
    /// `photoGrid` build rows from.
    private var allPhotoPaths: [String] {
        var paths: [String] = []
        if let headerImagePath = storeInfo?.headerImagePath { paths.append(headerImagePath) }
        paths.append(contentsOf: storeInfo?.screenshotPaths ?? [])
        return paths
    }

    /// True whenever there's actually something to put in `photoGrid`.
    private var hasPhotos: Bool { !allPhotoPaths.isEmpty }

    /// A fixed-width column of photos to the right of the text, replacing an earlier full-width row
    /// layout. Two thumbnails per row rather than one, sized up generously, with the content column
    /// widened to match so the text side doesn't get squeezed. Each thumbnail gets both its width
    /// *and* height fixed in one `.frame()` call
    /// before `.fill` crops it, so every photo renders at exactly the same size no matter its own
    /// screenshot's native aspect ratio. Tap one to open the *complete*, uncropped image via
    /// `imageLightbox` - "images are expandable for the more detail pictures."
    private var photoGrid: some View {
        let rows = allPhotoPaths.chunked(into: 2)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Media")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 20) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 20) {
                        ForEach(rows[rowIndex], id: \.self) { path in
                            photoThumbnail(path)
                        }
                    }
                }
            }
        }
        .frame(width: 560, alignment: .leading)
    }

    private func photoThumbnail(_ path: String) -> some View {
        Group {
            if let image = LocalImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 270, height: 155)
                    .skinArtTreatment()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { expandedImagePath = path }
            }
        }
    }

    /// A full-size, uncropped look at one photo - tap anywhere (or press Escape/B) to dismiss.
    private func imageLightbox(_ path: String) -> some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            if let image = LocalImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(60)
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        expandedImagePath = nil
                    } label: {
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
        .onTapGesture { expandedImagePath = nil }
    }

    /// Same green/yellow/red convention Steam's own store pages use for Metacritic scores.
    private func metacriticBadge(_ score: Int) -> some View {
        Text("\(score)")
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
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
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
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
        HStack(spacing: 12) {
            if runningInfo != nil {
                RunningBadge(compact: true)
            } else {
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
                .frame(maxWidth: 260)
                .focusRing(isFocused(.launch))
            }
            if isAdvancedMode && game.source == .wineBottle {
                Button {
                    showingSettings = true
                } label: {
                    Label(hasCustomSettings ? "Custom Settings" : "Settings", systemImage: hasCustomSettings ? "slider.horizontal.3" : "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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
            .buttonStyle(.bordered)
            .controlSize(.large)
            .focusRing(isFocused(.reveal))
            Button {
                model.openStorePage(for: game)
            } label: {
                Label("Store Page", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .focusRing(isFocused(.storePage))
        }
        .padding(.top, 8)
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
        .task(id: game.appID) {
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
    @LocalState private var headerImagePath: String?

    var body: some View {
        LaunchOverlayContent(name: game.name, artworkPath: headerImagePath, statusLine: engineSummary)
            .task {
                headerImagePath = await SteamStoreInfoCache.shared.info(for: game.metadataAppID)?.headerImagePath
            }
    }

    /// A native macOS Steam game runs through the real Steam app directly - no Wine, no engine, no
    /// D3D backend involved at all, so showing one here would be actively wrong, not just unused
    /// chrome - "the thing saying d3dmetal on mac steam games is a bit misleading," per live
    /// feedback. Empty (not shown) rather than some other placeholder text.
    private var engineSummary: String {
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

    var body: some View {
        LaunchOverlayContent(name: game.effectiveName, artworkPath: game.effectiveArtworkPath, statusLine: statusLine)
    }
}

private struct LaunchOverlayContent: View {
    let name: String
    let artworkPath: String?
    let statusLine: String

    var body: some View {
        ZStack {
            background
            VStack(spacing: 14) {
                Spacer()
                Text(name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                LoadingDotsView(message: "LAUNCHING…")
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
            }
        }
        // This overlay's background is always a dark blurred image regardless of system appearance,
        // so force dark-mode semantic colors (.secondary etc. inside LoadingDotsView) rather than
        // risking low-contrast mid-gray text if the system happens to be in light mode.
        .colorScheme(.dark)
    }

    @ViewBuilder
    private var background: some View {
        if let artworkPath, let image = LocalImageCache.image(atPath: artworkPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 40)
                .overlay(Color.black.opacity(0.55))
        } else {
            LinearGradient(colors: [Color.accentColor.opacity(0.5), .black], startPoint: .top, endPoint: .bottom)
        }
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
                FindBestConfigurationSection(itemID: game.appID, itemName: game.name)
                GameSettingsFields(config: configBinding)
                Button("Use Default Settings") {
                    model.setOverride(nil, for: game)
                }
                .disabled(model.perGameConfigs[game.appID] == nil)

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

                InspectSection(itemID: game.appID, itemName: game.name, installPath: installFolderPath)
            }
            .formStyle(.grouped)
        }
        .frame(width: 380, height: 660)
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
