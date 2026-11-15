import SwiftUI

/// A short, entirely optional first-launch walkthrough for picking a look and a layout. Nothing
/// here is required: every default already works with zero interaction, so this only ever helps
/// someone find a look they like faster - it never gates anything. Shown automatically once
/// `SetupCoordinator` reaches `.ready` for a brand-new install (see `RootView`), and reachable
/// again anytime from Settings ("Run Setup Wizard Again").
///
/// Every preview here is built from the real, shared primitives the dashboard itself uses
/// (`SkinBackground`, `PlaydockCardShape`, `cardSurface()`/`tileSurface()`, `SkinTitleText`,
/// `PlaydockButtonStyle`) via their `skinOverride` parameter, not a separate hand-drawn
/// approximation - what's picked here is exactly what the library will look like, because it's
/// the same code drawing both.
struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LibraryLayoutStyle.storageKey) private var libraryLayoutRaw = LibraryLayoutStyle.grid.rawValue
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    @AppStorage(PlaydockArtSource.storageKey) private var artSourceRaw = PlaydockArtSource.banner.rawValue
    @AppStorage(WizardCompletion.storageKey) private var hasCompletedWizard = false

    @LocalState private var step: Step = .welcome

    private enum Step: Int, CaseIterable {
        case welcome, skin, layout, artSource, done
    }

    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    private var layout: LibraryLayoutStyle { LibraryLayoutStyle(rawValue: libraryLayoutRaw) ?? .grid }
    private var artSource: PlaydockArtSource { PlaydockArtSource(rawValue: artSourceRaw) ?? .banner }

    var body: some View {
        ZStack {
            SkinBackground(skin: skin).ignoresSafeArea()
            VStack(spacing: 0) {
                progressDots.padding(.top, 22)
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .skin: skinStep
                    case .layout: layoutStep
                    case .artSource: artSourceStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
                footer
            }
        }
        .frame(width: 720, height: 580)
        .fontDesign(skin.fontDesign)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Chrome

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? skin.accent : Color.primary.opacity(0.15))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { back() }
                    .buttonStyle(PlaydockButtonStyle(prominent: false))
            }
            Spacer()
            if step != .done {
                Button("Skip Setup") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if step != .welcome && step != .done {
                Button("Next") { advance() }
                    .buttonStyle(PlaydockButtonStyle())
            }
        }
        .padding(24)
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func finish() {
        hasCompletedWizard = true
        dismiss()
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 46))
                .foregroundStyle(skin.accent)
            SkinTitleText(text: "Welcome to Playdock", size: 32, lineLimit: 2)
                .multilineTextAlignment(.center)
            Text("Pick how your library looks - takes about 30 seconds, and everything here can be changed later in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
            Button("Get Started") { advance() }
                .buttonStyle(PlaydockButtonStyle())
                .frame(maxWidth: 220)
        }
    }

    // MARK: - Skin

    private var skinStep: some View {
        VStack(spacing: 14) {
            SkinTitleText(text: "Choose a look", size: 24)
            Text("Whichever feels most like you. Real previews, not mockups - this is exactly what you'll get.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(PlaydockSkin.allCases) { candidate in
                    SkinPreviewTile(skin: candidate, isSelected: candidate == skin) {
                        skinRaw = candidate.rawValue
                    }
                }
            }
        }
    }

    // MARK: - Layout

    private var layoutStep: some View {
        VStack(spacing: 14) {
            SkinTitleText(text: "Choose a layout", size: 24)
            Text("How your library is arranged. Grid is the familiar default.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(LibraryLayoutStyle.allCases) { candidate in
                        LayoutPickerRow(layout: candidate, isSelected: candidate == layout) {
                            libraryLayoutRaw = candidate.rawValue
                        }
                    }
                }
            }
        }
    }

    // MARK: - Art source

    private var artSourceStep: some View {
        VStack(spacing: 14) {
            SkinTitleText(text: "Card art", size: 24)
            Text("Which real art shows on each card.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(PlaydockArtSource.allCases) { candidate in
                    ArtSourcePickerTile(source: candidate, isSelected: candidate == artSource) {
                        artSourceRaw = candidate.rawValue
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(skin.accent)
            SkinTitleText(text: "You're all set", size: 30)
            VStack(spacing: 4) {
                Text("\(skin.displayName) · \(layout.displayName) · \(artSource.displayName) Art")
                    .font(.callout.weight(.semibold))
                Text("Install Steam from the library when you want Windows games, then sign in inside Steam.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Spacer()
            Button("Start Playing") { finish() }
                .buttonStyle(PlaydockButtonStyle())
                .frame(maxWidth: 220)
        }
    }
}

/// One selectable skin swatch - a real `SkinBackground` behind a real, small `cardSurface()`
/// sample card, both explicitly rendered *as* `skin` regardless of what's currently active
/// elsewhere, via each primitive's own `skinOverride`.
private struct SkinPreviewTile: View {
    let skin: PlaydockSkin
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    SkinBackground(skin: skin)
                    VStack(spacing: 4) {
                        Circle().fill(skin.accent).frame(width: 14, height: 14)
                        SkinTitleText(text: "Sample", size: 11, skinOverride: skin)
                    }
                    .padding(10)
                    .cardSurface(skinOverride: skin)
                }
                .frame(height: 78)
                .clipShape(PlaydockCardShape(skin: skin, cornerRadius: skin.cardRadius))
                .overlay(
                    PlaydockCardShape(skin: skin, cornerRadius: skin.cardRadius)
                        .strokeBorder(isSelected ? skin.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2.5 : 1)
                )
                VStack(spacing: 1) {
                    Text(skin.displayName).font(.caption.weight(.semibold))
                    Text(skin.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One selectable layout row - real name, real subtitle, real icon, drawn with the actual
/// `cardSurface()` (following whatever skin is already picked, no override needed here since the
/// skin step always runs first).
private struct LayoutPickerRow: View {
    let layout: LibraryLayoutStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: layout.iconName)
                    .font(.title2)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(layout.displayName).font(.headline)
                    Text(layout.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface(isHovering: isSelected)
    }
}

private struct ArtSourcePickerTile: View {
    let source: PlaydockArtSource
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                Image(systemName: source == .banner ? "rectangle.ratio.16.to.9" : "rectangle.portrait")
                    .font(.system(size: 30))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(source.displayName).font(.headline)
                Text(source.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface(isHovering: isSelected)
    }
}

/// Whether the wizard has already run once - separate from every look/layout preference it sets,
/// so it can be reset independently (Settings' "Run Setup Wizard Again" just re-presents the same
/// view without touching this at all - only actually finishing or skipping it flips this back on).
enum WizardCompletion {
    static let storageKey = "com.exedock.hasCompletedSetupWizard"
}
