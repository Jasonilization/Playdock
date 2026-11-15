import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Visually mirrors `GameCardView`'s layout (art/title/details/Launch) but wired to `CustomGame`/
/// `AppModel.launchCustomGame` instead of Steam - its own small view rather than sharing
/// `GameCardView` directly, since the two kinds diverge in real ways (a "Custom Game" badge, no
/// Steam-only launch overlay, a location-unavailable state Steam games can never hit). The settings
/// popover and Inspect section underneath are shared, generalized code, though - see
/// `CustomGameSettingsPopover`.
struct CustomGameCardView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var runningTracker = RunningGameTracker.shared
    let game: CustomGame
    let isAdvancedMode: Bool
    let artworkHeight: CGFloat
    let isFocused: Bool
    let onLaunch: () -> Void
    let onOpenDetail: () -> Void

    @LocalState private var showingSettings = false
    @LocalState private var showingEdit = false
    @LocalState private var isHoveringArtwork = false
    @LocalState private var isHoveringCard = false
    @LocalState private var isMoving = false

    private var runningInfo: RunningProcessInfo? { runningTracker.runningGames[game.id] }
    private var hasCustomSettings: Bool { model.perGameConfigs[game.id] != nil }
    private var isMissing: Bool { !FileManager.default.fileExists(atPath: game.exePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                        SkinTitleText(text: game.effectiveName, size: 20)
                        Text("Custom Game")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.85), in: Capsule())
                    }
                    Spacer()
                    if isAdvancedMode {
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
                            CustomGameSettingsPopover(game: game)
                        }
                    }
                }
                if let description = game.effectiveDescription {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if game.discovered.steamMetacriticScore != nil || game.discovered.steamGenres.first != nil {
                    detailsRow
                }
                if isMissing {
                    Label("Game location unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if runningInfo != nil {
                    RunningBadge()
                } else if isMissing {
                    HStack(spacing: 10) {
                        Button("Locate Game") { locateGame() }
                            .buttonStyle(.bordered)
                        Button("Remove") { model.removeCustomGame(game) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    openDetailHint
                }
            }
            .padding(20)
        }
        .cardSurface(isHovering: isHoveringCard)
        .focusRing(isFocused)
        // Tapping the card opens the full detail view rather than launching straight away - same
        // pattern as GameCardView, for the same reason (see that view's own comment on why a plain
        // single-tap gesture here is safe alongside the nested gearshape Button).
        .contentShape(RoundedRectangle(cornerRadius: Playdock.Radius.card))
        .onTapGesture { onOpenDetail() }
        .contextMenu {
            Button {
                onOpenDetail()
            } label: {
                Label("View Details", systemImage: "info.circle")
            }
            if runningInfo == nil, !isMissing {
                Button {
                    onLaunch()
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .disabled(model.launchingTarget != nil)
            }
            Divider()
            Button {
                model.revealInFinder(game.exePath)
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(game.exePath, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            Button {
                showingEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                refreshMetadata()
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.clockwise")
            }
            if !isMissing, game.bottleID == nil {
                Button {
                    moveIntoOwnBottle()
                } label: {
                    Label("Give This Game Its Own Bottle", systemImage: "shippingbox")
                }
                .disabled(isMoving)
            }
            Divider()
            Button(role: .destructive) {
                model.removeCustomGame(game)
            } label: {
                Label("Remove From Library", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditCustomGameSheet(game: game)
        }
        .onHover { isHovering in
            isHoveringCard = isHovering
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// Mirrors `GameCardView`'s own metacritic-badge-plus-genre treatment - the same green/yellow/
    /// red Steam convention - so a custom game with a confident Steam match looks just as much a
    /// "real" library entry as an actual Steam game does.
    /// Replaces the old inline Launch button - launching now only happens from the full detail
    /// view, reached by tapping the card, same as a Steam game's card.
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

    private var detailsRow: some View {
        HStack(spacing: 8) {
            if let score = game.discovered.steamMetacriticScore {
                Text("\(score)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(metacriticColor(score), in: RoundedRectangle(cornerRadius: 4))
            }
            if let genre = game.discovered.steamGenres.first {
                Text(genre)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func metacriticColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50..<75: return .yellow
        default: return .red
        }
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let path = game.effectiveArtworkPath, let image = LocalImageCache.image(atPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(isHoveringArtwork ? 1.06 : 1.0)
                    .animation(.easeOut(duration: 0.3), value: isHoveringArtwork)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: artworkHeight * 0.3))
                    .foregroundStyle(Color.purple)
                    .frame(maxWidth: .infinity)
                    .background(Color.purple.opacity(0.15))
            }
        }
        .frame(height: artworkHeight)
        .clipped()
        .onHover { isHoveringArtwork = $0 }
    }

    /// Re-runs the same file picker used to add a game in the first place - only updates `exePath`,
    /// never touches anything else about the record (name overrides, discovered metadata, etc.).
    private func locateGame() {
        let panel = NSOpenPanel()
        if let exeType = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exeType] }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = game
        updated.exePath = url.path
        model.updateCustomGame(updated)
    }

    /// Copies an older library entry into a bottle of its own. Games added before per-game
    /// bottles share the Playdock prefix, or still point at a Sikarugir wrapper. This is
    /// opt-in: nothing moves an existing game unless this is chosen.
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

    /// Re-runs metadata discovery from scratch (local PE info, then a confident-only Steam match)
    /// and replaces `discovered` entirely - useful for a game added before a later enrichment
    /// shipped (richer fields didn't exist yet at import time, so there's nothing here to
    /// auto-backfill), or one whose confident match was missed the first time. Never touches
    /// `overrides` - a manual rename/description edit survives a metadata refresh.
    private func refreshMetadata() {
        Task {
            let discovered = await CustomGameMetadataDiscovery.discover(exePath: game.exePath, folderName: nil)
            var updated = game
            updated.discovered = discovered
            model.updateCustomGame(updated)
        }
    }
}
