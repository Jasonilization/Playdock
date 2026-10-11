import SwiftUI
import AppKit

/// Playdock's settings surface: a full-window panel with a category sidebar and a detail pane, the
/// shape a real desktop app's settings take (System Settings, Music.app, Steam's own) rather than
/// a cramped modal `Form`. Every control here is drawn with the same skin primitives the dashboard
/// uses - `SkinBackground`, `SkinTitleText`, `PlaydockButtonStyle`, `.cardSurface()`, the active
/// accent on every toggle and picker - so the panel is itself a live, one-to-one preview of
/// whatever appearance is selected, and switching skins on the Appearance tab restyles the panel
/// you're standing in.
///
/// Presented as an in-window overlay by `GameModeView` (not a `.sheet`), opened from the floating
/// settings launcher or the header gear, dismissed with Done / Esc / the launcher's own control.
///
/// Built one category at a time (see the other commits in this unit) - this first cut is just the
/// shell plus General, enough to be a working (if minimal) panel on its own.
struct SettingsPanelView: View {
    var onClose: () -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    /// Purely a redraw trigger - `L(_:)` reads `UserDefaults` directly. Same pattern the rest of
    /// the app uses for `PlaydockSkin.storageKey`.
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue
    @LocalState private var category: Category = .general

    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    enum Category: String, CaseIterable, Identifiable {
        case general, appearance, personalization, games, language, diagnostics
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .personalization: return "Personalization"
            case .games: return "Games & Data"
            case .language: return "Language"
            case .diagnostics: return "Diagnostics"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .personalization: return "slider.horizontal.3"
            case .games: return "gamecontroller"
            case .language: return "globe"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    var body: some View {
        ZStack {
            SkinBackground(skin: skin).ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                skinnedDivider
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 236)
                    skinnedDivider.frame(width: 1).frame(maxHeight: .infinity)
                    ScrollView {
                        content
                            .padding(28)
                            .frame(maxWidth: 660, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .fontDesign(skin.fontDesign)
        .tint(skin.accent)
        .transition(.opacity)
        .onExitCommand(perform: onClose)
    }

    private var skinnedDivider: some View {
        Rectangle()
            .fill(skin.accent.opacity(0.16))
            .frame(height: 1)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundStyle(skin.accent)
            SkinTitleText(text: L("Settings"), size: 22, lineLimit: 1)
            Spacer()
            Button(L("Done")) { onClose() }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Category.allCases) { item in
                sidebarRow(item)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ item: Category) -> some View {
        let isSelected = category == item
        let shape = PlaydockCardShape(skin: skin, cornerRadius: min(skin.cardRadius, 12))
        return Button {
            category = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.body)
                    .frame(width: 22)
                Text(L(item.titleKey))
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? skin.accent : Color.primary)
        .background(isSelected ? skin.accent.opacity(0.14) : Color.clear, in: shape)
        .overlay(isSelected ? shape.strokeBorder(skin.accent.opacity(0.35), lineWidth: skin.borderWidth) : nil)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general: generalTab
        case .appearance: appearanceTab
        case .personalization: personalizationTab
        case .games: gamesTab
        case .language: languageTab
        case .diagnostics: diagnosticsTab
        }
    }

    // MARK: General

    @AppStorage("com.exedock.advancedMode") private var isAdvancedMode = false
    @AppStorage("com.exedock.uiScale") private var uiScale = 1.0

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.general)

            SettingsCard(skin: skin, title: L("Advanced Mode")) {
                SettingsToggle(
                    skin: skin,
                    title: L("Advanced Mode"),
                    subtitle: L("Adds a settings button to each game so you can fine-tune its engine and graphics settings individually. Most people never need this."),
                    isOn: $isAdvancedMode
                )
            }

            SettingsCard(skin: skin, title: L("UI Size")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $uiScale, in: 0.75...1.5)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(uiScale * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            SettingsCard(skin: skin, title: L("Preview With Sample Games")) {
                SettingsToggle(
                    skin: skin,
                    title: L("Preview With Sample Games"),
                    subtitle: L("Adds well-known games (real art and ratings, nothing installed) so you can see how the grid looks. Turn off to remove them."),
                    isOn: Binding(
                        get: { model.isPreviewingSampleGames },
                        set: { _ in model.togglePreviewSampleGames() }
                    )
                )
            }
        }
    }

    // MARK: Appearance

    @LocalState private var showingWizard = false

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.appearance)

            SettingsCard(skin: skin, title: L("Look")) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(PlaydockSkin.allCases) { candidate in
                            MiniSkinTile(skin: candidate, isSelected: candidate == skin) {
                                withAnimation(.easeInOut(duration: 0.25)) { skinRaw = candidate.rawValue }
                            }
                        }
                    }
                    Text(L("Every control here is drawn in the look you pick, so this screen is a live preview of it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(L("Follows your Mac's light or dark appearance automatically."), systemImage: "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(skin: skin, title: L("Run Setup Wizard Again")) {
                Button(L("Run Setup Wizard Again")) { showingWizard = true }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
            }
        }
        .sheet(isPresented: $showingWizard) { SetupWizardView() }
    }

    // MARK: Personalization

    @AppStorage(LibraryLayoutStyle.storageKey) private var libraryLayoutRaw = LibraryLayoutStyle.grid.rawValue
    @AppStorage(PlaydockArtSource.storageKey) private var artSourceRaw = PlaydockArtSource.banner.rawValue
    @AppStorage(GameModeView.showSteamIconKey) private var showSteamIcon = true
    @AppStorage(SettingsLauncher.showLauncherKey) private var showSettingsButton = true
    /// Depends on the badge-wiring unit that defines this key - see this unit's notes.md.
    @AppStorage(GameModeView.hideBadgesKey) private var hideLibraryBadges = false

    private var personalizationTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.personalization)

            SettingsCard(skin: skin, title: L("Library")) {
                VStack(alignment: .leading, spacing: 14) {
                    labeledPicker(L("Layout"), selection: $libraryLayoutRaw) {
                        ForEach(LibraryLayoutStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    labeledPicker(L("Card Art"), selection: $artSourceRaw) {
                        ForEach(PlaydockArtSource.allCases) { source in
                            Text(source.displayName).tag(source.rawValue)
                        }
                    }
                }
            }

            SettingsCard(skin: skin, title: L("Show Floating Steam Icon")) {
                VStack(spacing: 12) {
                    SettingsToggle(
                        skin: skin,
                        title: L("Show Floating Steam Icon"),
                        subtitle: L("The double-click-to-open-Steam icon in the corner of the grid. Turn off to collapse it to a small tab on the edge (still there, just out of the way)."),
                        isOn: $showSteamIcon
                    )
                    Divider().overlay(skin.accent.opacity(0.1))
                    SettingsToggle(
                        skin: skin,
                        title: L("Show Floating Settings Button"),
                        subtitle: nil,
                        isOn: $showSettingsButton
                    )
                }
            }

            SettingsCard(skin: skin, title: L("Hide Library Badges")) {
                SettingsToggle(
                    skin: skin,
                    title: L("Hide Library Badges"),
                    subtitle: L("The Custom/Mac/Windows label every game's art shows to say where it came from. Turn on to hide all three everywhere - every layout, every appearance."),
                    isOn: $hideLibraryBadges
                )
            }
        }
    }

    // MARK: Games & Data

    private var gamesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.games)

            SettingsCard(skin: skin, title: L("Hard Refresh Game Info")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Re-downloads every game's art, description, and details from Steam. Use this if a game shows the wrong or missing art."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button {
                            model.hardRefreshGameInfo()
                        } label: {
                            if model.isHardRefreshingGameInfo {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L("Refreshing…"))
                                }
                            } else {
                                Label(L("Hard Refresh Game Info"), systemImage: "arrow.clockwise.circle")
                            }
                        }
                        .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                        .disabled(model.isHardRefreshingGameInfo)
                        Text(lastRefreshText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            EngineUpdatePanelSection(skin: skin)

            if isAdvancedMode {
                SettingsCard(skin: skin, title: L("Engine")) {
                    advancedEngineControls
                }
            }
        }
    }

    @ViewBuilder
    private var advancedEngineControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledPicker(L("Wine engine"), selection: Binding(
                get: { model.gameModeConfig.engineName ?? "" },
                set: { model.gameModeConfig.engineName = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(SikarugirEngine.availableEngineNames(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Text(L("These are the same engines already downloaded by Sikarugir Creator."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().overlay(skin.accent.opacity(0.1))
            Text(L("Graphics")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            SettingsToggle(skin: skin, title: "D3DMETAL", subtitle: nil, isOn: $model.gameModeConfig.d3dMetal)
            SettingsToggle(skin: skin, title: "MoltenVK CX", subtitle: nil, isOn: $model.gameModeConfig.moltenVKCX)
            SettingsToggle(skin: skin, title: "DXVK", subtitle: nil, isOn: $model.gameModeConfig.dxvk)
            SettingsToggle(skin: skin, title: "DXMT", subtitle: nil, isOn: $model.gameModeConfig.dxmt)
            Divider().overlay(skin.accent.opacity(0.1))
            SettingsToggle(skin: skin, title: L("Fast Sync (ESYNC + MSYNC)"), subtitle: nil, isOn: $model.gameModeConfig.fastSync)
        }
    }

    private var lastRefreshText: String {
        guard let date = model.lastGameInfoRefresh else { return L("Never refreshed") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return LF("Last refreshed %@", formatter.string(from: date))
    }

    // MARK: Language

    private var languageTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.language)

            SettingsCard(skin: skin, title: L("Language")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Choose the language Playdock's interface uses."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(AppLanguage.allCases) { option in
                        languageRow(option)
                        if option != AppLanguage.allCases.last {
                            Divider().overlay(skin.accent.opacity(0.08))
                        }
                    }
                    Text(L("Changes apply immediately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(L("Some text may stay in English until its translation is finished."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func languageRow(_ option: AppLanguage) -> some View {
        let isSelected = languageRaw == option.rawValue
        return Button {
            languageRaw = option.rawValue
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.endonym).font(.callout.weight(isSelected ? .semibold : .regular))
                    if option.englishName != option.endonym {
                        Text(option.englishName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(skin.accent)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Diagnostics

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.diagnostics)

            SettingsCard(skin: skin, title: L("Diagnostics")) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        model.revealInFinder(ExeRunner.logsDir)
                    } label: {
                        Label(L("Open Logs Folder"), systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                    Button {
                        model.revealInFinder(("~/Library/Logs/DiagnosticReports" as NSString).expandingTildeInPath)
                    } label: {
                        Label(L("Open Crash Reports"), systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                    Text(L("Every launch writes its own log here, plus a record of background checks. If something's not working, look here first."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Shared bits

    private func tabHeader(_ item: Category) -> some View {
        SkinTitleText(text: L(item.titleKey), size: 19, lineLimit: 1)
            .padding(.bottom, 2)
    }

    private func labeledPicker<SelectionValue: Hashable, Options: View>(
        _ label: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Picker(label, selection: selection, content: options)
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(skin.accent)
                .frame(maxWidth: 240)
        }
    }
}

// MARK: - Reusable card + rows

/// A titled panel section drawn with the active skin's real `cardSurface()` treatment, so a
/// settings card reads exactly like a game card under the same skin.
private struct SettingsCard<Content: View>: View {
    let skin: PlaydockSkin
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(skinOverride: skin)
    }
}

/// A small selectable swatch showing one skin's real background + a real `cardSurface()` sample,
/// each rendered explicitly as that candidate skin via the primitives' own `skinOverride` - the
/// same technique the setup wizard's picker uses, kept local here so the two can diverge in size/
/// density without fighting over one shared tile.
private struct MiniSkinTile: View {
    let skin: PlaydockSkin
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let shape = PlaydockCardShape(skin: skin, cornerRadius: skin.cardRadius)
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    SkinBackground(skin: skin)
                    VStack(spacing: 3) {
                        Circle().fill(skin.accent).frame(width: 12, height: 12)
                        SkinTitleText(text: skin.displayName, size: 10, skinOverride: skin)
                    }
                    .padding(8)
                    .cardSurface(skinOverride: skin)
                }
                .frame(height: 66)
                .clipShape(shape)
                .overlay(shape.strokeBorder(isSelected ? skin.accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1))
                Text(skin.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? skin.accent : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// "Check for Engine Updates", card-styled for the settings panel. Same two-step flow as before
/// (check is free/instant; the potentially large download only happens on an explicit tap) - only
/// the chrome changed from a `Form` `Section` to a `SettingsCard`.
private struct EngineUpdatePanelSection: View {
    let skin: PlaydockSkin
    @LocalState private var isChecking = false
    @LocalState private var isDownloading = false
    @LocalState private var updateAvailable: RemoteEngineAsset?
    @LocalState private var statusText: String?

    var body: some View {
        SettingsCard(skin: skin, title: L("Engine")) {
            VStack(alignment: .leading, spacing: 10) {
                if let updateAvailable {
                    Text("A newer engine is available: \(updateAvailable.name)")
                        .font(.callout)
                    Button {
                        downloadUpdate(updateAvailable)
                    } label: {
                        if isDownloading {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Downloading…")) }
                        } else {
                            Text(L("Download Update"))
                        }
                    }
                    .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                    .disabled(isDownloading)
                } else {
                    Button {
                        checkForUpdates()
                    } label: {
                        if isChecking {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Checking…")) }
                        } else {
                            Label(L("Check for Engine Updates"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                    .disabled(isChecking)
                }
                if let statusText {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Playdock's Wine engine comes from Sikarugir's public releases. Checking never downloads anything by itself."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkForUpdates() {
        isChecking = true
        statusText = nil
        Task {
            do {
                let assets = try await SikarugirEnginesRemote.fetchAvailableAssets()
                guard let recommended = SikarugirEnginesRemote.recommendedAsset(among: assets) else {
                    isChecking = false
                    statusText = "No engines found."
                    return
                }
                let alreadyHave = Set(SikarugirEngine.availableEngineNames()).contains(recommended.name)
                isChecking = false
                if alreadyHave {
                    statusText = "You already have the latest recommended engine (\(recommended.name))."
                } else {
                    updateAvailable = recommended
                }
            } catch {
                isChecking = false
                statusText = error.localizedDescription
            }
        }
    }

    private func downloadUpdate(_ asset: RemoteEngineAsset) {
        isDownloading = true
        Task {
            do {
                try await SikarugirEnginesRemote.download(asset) { message in
                    Task { @MainActor in statusText = message }
                }
                isDownloading = false
                updateAvailable = nil
                statusText = "Downloaded \(asset.name) - pick it in Advanced Mode's engine list, or it'll be offered next time a bottle needs (re)initializing."
            } catch {
                isDownloading = false
                statusText = error.localizedDescription
            }
        }
    }
}

private struct SettingsToggle: View {
    let skin: PlaydockSkin
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text(title).font(.callout)
            }
            .toggleStyle(.switch)
            .tint(skin.accent)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
