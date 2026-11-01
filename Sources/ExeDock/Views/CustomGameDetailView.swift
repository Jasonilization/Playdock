import SwiftUI
import AppKit

private enum CustomDetailAction: Equatable {
    case launch, settings, reveal, edit, about
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
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    @ObservedObject private var controllerObserver = ControllerObserver.shared
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

    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[game.id] }
    private var hasCustomSettings: Bool { model.perGameConfigs[game.id] != nil }
    private var isMissing: Bool { !FileManager.default.fileExists(atPath: game.exePath) }

    private var availableActions: [CustomDetailAction] {
        var actions: [CustomDetailAction] = []
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
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                closeButton
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if isMissing {
                            Label("Game location unavailable", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .padding(24)
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let path = game.discovered.steamBackgroundPath ?? game.effectiveArtworkPath, let image = LocalImageCache.image(atPath: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 50)
                .overlay(Color.black.opacity(0.6))
                .ignoresSafeArea()
        } else {
            LinearGradient(colors: [Color.purple.opacity(0.5), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SkinTitleText(text: game.effectiveName, size: 34)
                    .foregroundStyle(.white)
                Text("Custom Game")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.85), in: Capsule())
            }
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
            if !subtitleLine.isEmpty {
                Text(subtitleLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
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

    /// Header art first, then every screenshot - the one list both `hasPhotos` and `photoGrid`
    /// build rows from, matching `GameDetailView`'s own `allPhotoPaths`.
    private var allPhotoPaths: [String] {
        var paths: [String] = []
        if let artworkPath = game.effectiveArtworkPath { paths.append(artworkPath) }
        paths.append(contentsOf: game.discovered.steamScreenshotPaths)
        return paths
    }

    /// True whenever there's actually something to put in `photoGrid`.
    private var hasPhotos: Bool { !allPhotoPaths.isEmpty }

    /// A fixed-width column of photos to the right of the text - matches `GameDetailView`'s own
    /// treatment exactly (see that view's doc comment for the full reasoning: fixed width *and*
    /// height in one `.frame()` call before `.fill` crops it, so every photo renders at the same
    /// size regardless of its own screenshot's native aspect ratio).
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
        let developer = game.discovered.steamDevelopers.first ?? game.discovered.publisher
        if let developer { parts.append("By \(developer)") }
        if let releaseDate = game.discovered.steamReleaseDate { parts.append("Released \(releaseDate)") }
        return parts.joined(separator: "  ·  ")
    }


    private var actionRow: some View {
        HStack(spacing: 12) {
            if runningInfo != nil {
                RunningBadge(compact: true)
            } else if isMissing {
                Button("Locate Game") { locateGame() }
                    .buttonStyle(.big)
                    .frame(maxWidth: 220)
                Button("Remove") { model.removeCustomGame(game); onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            } else {
                Button {
                    onLaunch()
                    model.launchCustomGame(game)
                } label: {
                    if model.launchingTarget == .custom(game.id) {
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
            if isAdvancedMode && !isMissing {
                Button {
                    showingSettings = true
                } label: {
                    Label(hasCustomSettings ? "Custom Settings" : "Settings", systemImage: hasCustomSettings ? "slider.horizontal.3" : "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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
                .buttonStyle(.bordered)
                .controlSize(.large)
                .focusRing(isFocused(.reveal))
            }
            Button {
                showingEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .focusRing(isFocused(.edit))
        }
        .padding(.top, 8)
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
