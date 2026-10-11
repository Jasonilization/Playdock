import SwiftUI

/// A big, controller-navigable carousel: one game centered at a time, D-pad left/right to switch, A
/// to drill into that game's full Game Detail view (not launch straight away - selecting should
/// always be a confirm step, not a surprise launch), B to back out one level at a
/// time (out of the detail view first, then out of Controller Mode itself). Reacts to
/// `ControllerObserver`'s shared D-pad/A/B stream rather than owning raw `GCExtendedGamepad`
/// handlers itself, self-filtering on `showingDetail` so it steps back and lets `GameDetailView`
/// (which reacts to the exact same stream, always active while it's mounted) own input the moment
/// it's shown - see `ControllerObserver`'s own doc comment for why that split exists.
struct ControllerModeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    @AppStorage("com.exedock.advancedMode") private var isAdvancedMode = false
    let onExit: () -> Void
    @LocalState private var selectedIndex = 0
    @LocalState private var storeInfo: SteamStoreInfo?
    @LocalState private var showingDetail = false

    private var games: [SteamGame] { model.steamGames }
    private var currentGame: SteamGame? { games.indices.contains(selectedIndex) ? games[selectedIndex] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let currentGame {
                VStack(spacing: 20) {
                    Spacer()
                    artwork
                        .frame(width: 280, height: 280)
                        .skinArtTreatment()
                        .tileSurface()
                    SkinTitleText(text: currentGame.name, size: 36, lineLimit: 2)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    if let subtitle = storeInfoSubtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Button("[ SELECT ]") {
                        openDetail()
                    }
                    .buttonStyle(.big)
                    .frame(maxWidth: 260)
                    Spacer()
                    neighborRow
                        .padding(.bottom, 32)
                }
            } else {
                Text("No games installed yet")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Exit (B)") { backOut() }
                        .buttonStyle(.bordered)
                        .padding(20)
                }
                Spacer()
            }

            if showingDetail, let currentGame {
                GameDetailView(game: currentGame, isAdvancedMode: isAdvancedMode) {
                    closeDetail()
                } onLaunch: {
                    model.launchSteamGame(currentGame)
                } onOpenSimilar: { similar in
                    // "More like this" navigates within the same controller-mode detail layer:
                    // the game may not even be on the carousel's current page, so jump the whole
                    // selection to it and keep the overlay open.
                    if let index = games.firstIndex(of: similar) { selectedIndex = index }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .zIndex(1)
            }
        }
        .colorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showingDetail)
        .task(id: currentGame?.appID) {
            guard let currentGame else { return }
            storeInfo = await SteamStoreInfoCache.shared.info(for: currentGame.metadataAppID)
        }
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            // Only browse the carousel while the detail view isn't covering it - GameDetailView
            // owns the D-pad the moment it's shown (see the type's own doc comment).
            guard !showingDetail, let direction = controllerObserver.directionPress?.direction else { return }
            switch direction {
            case .left: movePrevious()
            case .right: moveNext()
            case .up, .down: break
            }
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            // A drills into the detail view - GameDetailView (once shown) owns its own A/B
            // behavior (navigate its actions, launch, close) via the same shared stream.
            guard !showingDetail, currentGame != nil else { return }
            openDetail()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            guard !showingDetail else { return }
            backOut()
        }
    }

    private func openDetail() {
        guard currentGame != nil else { return }
        showingDetail = true
    }

    private func closeDetail() {
        showingDetail = false
    }

    /// One controller-style "back" step at a time: out of the detail view first if it's open,
    /// otherwise out of Controller Mode entirely - never both at once from a single B press.
    private func backOut() {
        if showingDetail {
            closeDetail()
        } else {
            onExit()
        }
    }

    private var storeInfoSubtitle: String? {
        guard let storeInfo else { return nil }
        var parts: [String] = []
        if let genre = storeInfo.genres.first { parts.append(genre) }
        if let score = storeInfo.metacriticScore { parts.append("Metacritic \(score)") }
        if let developer = storeInfo.developers.first { parts.append(developer) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = storeInfo?.headerImagePath, let image = LocalImageCache.image(atPath: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let currentGame {
            Image(nsImage: AppIconProvider.icon(forPath: currentGame.iconExePath ?? SteamInstaller.installedSteamExePath))
                .resizable().aspectRatio(contentMode: .fit).padding(40)
                .background(Color.accentColor.opacity(0.2))
        }
    }

    private var neighborRow: some View {
        HStack {
            if selectedIndex > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    SkinTitleText(text: games[selectedIndex - 1].name, size: 15)
                }
                .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if selectedIndex < games.count - 1 {
                HStack(spacing: 6) {
                    SkinTitleText(text: games[selectedIndex + 1].name, size: 15)
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 60)
    }

    private func movePrevious() {
        guard selectedIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedIndex -= 1 }
    }

    private func moveNext() {
        guard selectedIndex < games.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedIndex += 1 }
    }
}
