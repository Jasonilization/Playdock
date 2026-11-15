import SwiftUI
import AppKit

private enum CustomDetailAction: Equatable {
    case favorite, hide, launch, settings, reveal, edit, about
}

/// The custom-game equivalent of `GameDetailView`, giving a custom game the same full detail
/// treatment a Steam game gets. Same visual language (backdrop, header art, rating/genre tags,
/// description, screenshot strip, a controller-navigable action row) but its own type rather than a
/// generalized shared view, since the two diverge in real ways (no Steam store page to link to,
/// an Edit action instead, a location-unavailable state). Reached by tapping a custom game's card,
/// same as a Steam game's card opens `GameDetailView` - launching happens from here, not directly
/// off the grid card, for the same reason it does for Steam games.
struct CustomGameDetailView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    @ObservedObject private var playActivity = PlayActivityStore.shared
    @ObservedObject private var curation = LibraryCurationStore.shared
    let game: CustomGame
    let isAdvancedMode: Bool
    let onClose: () -> Void
    let onLaunch: () -> Void

    @LocalState private var showingSettings = false
    @LocalState private var showingEdit = false
    @LocalState private var focusedActionIndex = 0
    @LocalState private var keyboardNavigating = false
    @LocalState private var descriptionExpanded = false
    /// Non-nil while a photo is shown full-size over everything else.
    @LocalState private var expandedImagePath: String?
    @LocalState private var gameAccent: Color?
    @LocalState private var isMoving = false

    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[game.id] }
    private var hasCustomSettings: Bool { model.perGameConfigs[game.id] != nil }
    private var isMissing: Bool { !FileManager.default.fileExists(atPath: game.exePath) }

    private var availableActions: [CustomDetailAction] {
        var actions: [CustomDetailAction] = [.favorite, .hide]
        if runningInfo == nil && !isMissing { actions.append(.launch) }
        if isAdvancedMode && !isMissing { actions.append(.settings) }
        if !isMissing { actions.append(.reveal) }
        actions.append(.edit)
        if aboutCanExpand { actions.append(.about) }
        return actions
    }

    private var aboutCanExpand: Bool {
        guard let text = game.effectiveAboutTheGame else { return false }
        return text.count > 280 || text.components(separatedBy: "\n").count > 4
    }

    private func isFocused(_ action: CustomDetailAction) -> Bool {
        (controllerObserver.isConnected || keyboardNavigating) && availableActions[safe: focusedActionIndex] == action
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
                            if isMissing {
                                Label("Game location unavailable", systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                            header
                            if hasPhotos { photoGrid }
                            descriptionCard
                        }
                        .padding(.horizontal, 32)
                    }
                    .padding(.bottom, 160)
                    .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
            .padding(.bottom, 72)
            closeButton

            if let expandedImagePath {
                imageLightbox(expandedImagePath)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: game.id) {
            if let path = game.effectiveArtworkPath { gameAccent = await GameArtColor.dominantColor(forImagePath: path) }
        }
        .onExitCommand { onClose() }
        .focusable()
        .onMoveCommand { direction in
            guard !controllerObserver.isConnected, expandedImagePath == nil else { return }
            keyboardNavigating = true
            switch direction {
            case .left: moveActionFocus(.left)
            case .right: moveActionFocus(.right)
            case .up: moveActionFocus(.up)
            case .down: moveActionFocus(.down)
            @unknown default: break
            }
        }
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard expandedImagePath == nil, let direction = controllerObserver.directionPress?.direction else { return }
            moveActionFocus(direction)
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            guard expandedImagePath == nil else { return }
            activateFocusedAction()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            if expandedImagePath != nil {
                expandedImagePath = nil
            } else {
                onClose()
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditCustomGameSheet(game: game)
        }
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
            curation.toggleFavorite(game.id)
        case .hide:
            curation.hide(game.id)
            onClose()
        case .launch:
            onLaunch()
            model.launchCustomGame(game)
        case .settings: showingSettings = true
        case .reveal: model.revealInFinder(game.exePath)
        case .edit: showingEdit = true
        case .about: descriptionExpanded.toggle()
        case nil: break
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

    private var launcherHero: some View {
        HStack(alignment: .center, spacing: 24) {
            if let path = game.effectiveArtworkPath, let image = LocalImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 132)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Text(game.effectiveName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        curation.toggleFavorite(game.id)
                    } label: {
                        Image(systemName: curation.isFavorite(game.id) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(curation.isFavorite(game.id) ? .pink : .secondary)
                    }
                    .buttonStyle(.plain)
                    .focusRing(isFocused(.favorite))
                    .help(L(curation.isFavorite(game.id) ? "Remove from Favorites" : "Mark as Favorite"))
                    Menu {
                        Button(L("Hide This Game from Library"), role: .destructive) {
                            curation.hide(game.id)
                            onClose()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusRing(isFocused(.hide))
                    Text("Custom Game")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.85), in: Capsule())
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if game.discovered.steamMetacriticScore != nil || !game.discovered.steamGenres.isEmpty {
                HStack(spacing: 10) {
                    if let score = game.discovered.steamMetacriticScore {
                        metacriticBadge(score)
                    }
                    ForEach(game.discovered.steamGenres.prefix(3), id: \.self) { genre in
                        tag(genre)
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

    private var activitySummary: String? {
        let total = playActivity.totalSeconds(for: game.id)
        guard total > 0, let last = playActivity.lastPlayed(game.id) else { return nil }
        let hours = total / 3600
        let hoursText = hours < 1 ? "\(max(1, Int((total / 60).rounded(.up)))) min" : (hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h")
        let sessions = playActivity.sessionCount(for: game.id)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.formattingLocale
        let relative = formatter.localizedString(for: last, relativeTo: Date())
        return "\(hoursText) over \(sessions) session\(sessions == 1 ? "" : "s") · last played \(relative)"
    }

    @ViewBuilder
    private var descriptionCard: some View {
        if let description = game.effectiveAboutTheGame {
            ExpandableAboutCard(
                text: description,
                expanded: descriptionExpanded,
                isFocused: isFocused(.about)
            ) {
                descriptionExpanded.toggle()
            }
        }
    }

    /// Screenshots only. Artwork is already the banner at the top.
    private var allPhotoPaths: [String] {
        game.discovered.steamScreenshotPaths
    }

    /// True whenever there's actually something to put in `photoGrid`.
    private var hasPhotos: Bool { !allPhotoPaths.isEmpty }

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
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(skin.accent.opacity(0.14), in: PlaydockCardShape(skin: skin, cornerRadius: min(skin.cardRadius, 6)))
    }

    private var subtitleLine: String {
        var parts: [String] = []
        let developer = game.discovered.steamDevelopers.first ?? game.discovered.publisher
        if let developer { parts.append("By \(developer)") }
        if let releaseDate = game.discovered.steamReleaseDate { parts.append("Released \(releaseDate)") }
        return parts.joined(separator: "  ·  ")
    }


    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 16) {
            if runningInfo != nil {
                RunningBadge(compact: true)
            } else if isMissing {
                Button("Locate Game") { locateGame() }
                    .buttonStyle(.big)
                Button("Remove") { model.removeCustomGame(game); onClose() }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
            } else {
                Button {
                    onLaunch()
                    model.launchCustomGame(game)
                } label: {
                    if model.launchingTarget == .custom(game.id) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.primary)
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
            if isAdvancedMode && !isMissing {
                Button {
                    showingSettings = true
                } label: {
                    Label(hasCustomSettings ? "Custom Settings" : "Settings", systemImage: hasCustomSettings ? "slider.horizontal.3" : "gearshape")
                }
                .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                .focusRing(isFocused(.settings))
                .popover(isPresented: $showingSettings) {
                    CustomGameSettingsPopover(game: game)
                }
            }
            if !isMissing {
                Button {
                    model.revealInFinder(game.exePath)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                .focusRing(isFocused(.reveal))
            }
            Button {
                showingEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
            .focusRing(isFocused(.edit))
        }
        if game.bottleID == nil && !isMissing {
            Button {
                moveIntoOwnBottle()
            } label: {
                Label(isMoving ? "Creating a bottle…" : "Give this game its own bottle", systemImage: "shippingbox")
            }
            .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
            .disabled(isMoving)
        }
        }
        .padding(.top, 8)
    }

    /// Older library entries share one prefix, or still point at a Sikarugir wrapper. This
    /// copies the game into a bottle of its own. Nothing moves unless this is chosen.
    private func moveIntoOwnBottle() {
        isMoving = true
        let source = game
        Task {
            do {
                let newExePath = try await Task.detached(priority: .utility) {
                    let bottle = BottleManager.shared.gameBottle(id: source.id, name: source.effectiveName)
                    return try CustomGameFileImporter.importIntoGameBottle(exePath: source.exePath, pickedFolderPath: nil, bottle: bottle)
                }.value
                var updated = source
                updated.exePath = newExePath
                updated.bottleID = source.id
                await MainActor.run {
                    model.updateCustomGame(updated)
                    model.refreshBottlesAndApps()
                    isMoving = false
                }
            } catch {
                await MainActor.run {
                    isMoving = false
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func locateGame() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = game
        updated.exePath = url.path
        model.updateCustomGame(updated)
    }
}
