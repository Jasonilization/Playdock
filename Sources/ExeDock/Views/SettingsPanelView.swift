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
    @ObservedObject private var curation = LibraryCurationStore.shared
    var onClose: () -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    /// Purely a redraw trigger - `L(_:)` reads `UserDefaults` directly. Same pattern the rest of
    /// the app uses for `PlaydockSkin.storageKey`.
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue
    @LocalState private var category: Category = .general
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    /// Done and the category list are the left column. Right steps into that category's controls;
    /// B steps back out, then closes.
    @LocalState private var settingsFocus: SettingsFocus = .category(.general)
    @LocalState private var engineActivate: UUID?

    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    enum Category: String, CaseIterable, Identifiable {
        case general, appearance, personalization, games, language, diagnostics, about
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .personalization: return "Personalization"
            case .games: return "Games & Data"
            case .language: return "Language"
            case .diagnostics: return "Diagnostics"
            case .about: return "About"
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
            case .about: return "info.circle"
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            content
                                .padding(28)
                                .frame(maxWidth: 660, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: settingsFocus) { focus in
                            guard case .pane(let control) = focus else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(control, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .fontDesign(skin.fontDesign)
        .tint(skin.accent)
        .transition(.opacity)
        .onExitCommand(perform: onClose)
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard let direction = controllerObserver.directionPress?.direction else { return }
            switch settingsFocus {
            case .done, .category:
                moveSidebar(direction)
            case .pane:
                movePane(direction)
            }
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            activateSettingsFocus()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            if case .pane = settingsFocus {
                settingsFocus = .category(category)
            } else {
                onClose()
            }
        }
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
                .focusRing(controllerObserver.isConnected && settingsFocus == .done)
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
        .focusRing(controllerObserver.isConnected && settingsFocus == .category(item))
        .foregroundStyle(isSelected ? skin.accent : Color.primary)
        .background(isSelected ? skin.accent.opacity(0.14) : Color.clear, in: shape)
        .overlay(isSelected ? shape.strokeBorder(skin.accent.opacity(0.35), lineWidth: skin.borderWidth) : nil)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private enum SettingsFocus: Hashable {
        case done
        case category(Category)
        case pane(PaneControl)
    }

    private enum PaneControl: Hashable {
        case advancedMode, uiScale, sampleGames
        case skin(String)
        case setupWizard
        case layout, cardArt, showSteamIcon, showSettingsButton, hideBadges
        case hardRefresh, engineUpdate
        case unhide(String)
        case wineEngine, d3dMetal, moltenVK, dxvk, dxmt, fastSync
        case language(String)
        case openLogs, openCrashes
    }

    private var sidebarFocuses: [SettingsFocus] {
        [.done] + Category.allCases.map { SettingsFocus.category($0) }
    }

    private var paneControls: [PaneControl] {
        switch category {
        case .general:
            return [.advancedMode, .uiScale, .sampleGames]
        case .appearance:
            return PlaydockSkin.allCases.map { .skin($0.rawValue) } + [.setupWizard]
        case .personalization:
            return [.layout, .cardArt, .showSteamIcon, .showSettingsButton, .hideBadges]
        case .games:
            var items: [PaneControl] = [.hardRefresh, .engineUpdate]
            items += sortedHidden(curation.hidden).map { .unhide($0.id) }
            if isAdvancedMode {
                items += [.wineEngine, .d3dMetal, .moltenVK, .dxvk, .dxmt, .fastSync]
            }
            return items
        case .language:
            return AppLanguage.allCases.map { .language($0.rawValue) }
        case .diagnostics:
            return [.openLogs, .openCrashes]
        case .about:
            return []
        }
    }

    private func isPaneFocused(_ control: PaneControl) -> Bool {
        controllerObserver.isConnected && settingsFocus == .pane(control)
    }

    private func moveSidebar(_ direction: ControllerDirection) {
        guard let index = sidebarFocuses.firstIndex(of: settingsFocus) else {
            settingsFocus = .category(category)
            return
        }
        switch direction {
        case .up where index > 0:
            settingsFocus = sidebarFocuses[index - 1]
        case .down where index + 1 < sidebarFocuses.count:
            settingsFocus = sidebarFocuses[index + 1]
        case .right:
            if case .category = settingsFocus, let first = paneControls.first {
                settingsFocus = .pane(first)
            }
        default:
            break
        }
        if case .category(let item) = settingsFocus { category = item }
    }

    private func movePane(_ direction: ControllerDirection) {
        guard case .pane(let current) = settingsFocus else { return }
        if current == .uiScale, direction == .left || direction == .right {
            nudgeSettingsScale(direction == .right ? 1 : -1)
            return
        }
        if direction == .left || direction == .right, adjustPicker(current, delta: direction == .right ? 1 : -1) {
            return
        }
        if case .skin(let raw) = current {
            moveSkin(raw, direction)
            return
        }
        let items = paneControls
        guard let index = items.firstIndex(of: current) else {
            settingsFocus = .category(category)
            return
        }
        switch direction {
        case .up where index > 0:
            settingsFocus = .pane(items[index - 1])
        case .down where index + 1 < items.count:
            settingsFocus = .pane(items[index + 1])
        case .left:
            settingsFocus = .category(category)
        default:
            break
        }
    }

    private func moveSkin(_ raw: String, _ direction: ControllerDirection) {
        let skins = PlaydockSkin.allCases
        guard let index = skins.firstIndex(where: { $0.rawValue == raw }) else {
            settingsFocus = .category(.appearance)
            return
        }
        let columns = 3
        switch direction {
        case .left:
            if index % columns == 0 {
                settingsFocus = .category(.appearance)
            } else {
                settingsFocus = .pane(.skin(skins[index - 1].rawValue))
            }
        case .right where index + 1 < skins.count:
            settingsFocus = .pane(.skin(skins[index + 1].rawValue))
        case .up where index >= columns:
            settingsFocus = .pane(.skin(skins[index - columns].rawValue))
        case .down:
            if index + columns < skins.count {
                settingsFocus = .pane(.skin(skins[index + columns].rawValue))
            } else {
                settingsFocus = .pane(.setupWizard)
            }
        default:
            break
        }
    }

    private func nudgeSettingsScale(_ step: Int) {
        let stops = [0.75, 0.9375, 1.125, 1.3125, 1.5]
        let nearest = stops.min(by: { abs($0 - uiScale) < abs($1 - uiScale) }) ?? uiScale
        guard let index = stops.firstIndex(of: nearest) else { return }
        uiScale = stops[min(max(0, index + step), stops.count - 1)]
    }

    /// Left/right on a menu picker cycles its choices instead of leaving the row.
    private func adjustPicker(_ control: PaneControl, delta: Int) -> Bool {
        switch control {
        case .layout:
            cycle(LibraryLayoutStyle.allCases.map(\.rawValue), current: libraryLayoutRaw) { libraryLayoutRaw = $0 }
        case .cardArt:
            cycle(PlaydockArtSource.allCases.map(\.rawValue), current: artSourceRaw) { artSourceRaw = $0 }
        case .wineEngine:
            let names = SikarugirEngine.availableEngineNames()
            let current = model.gameModeConfig.engineName ?? names.first ?? ""
            cycle(names, current: current) { model.gameModeConfig.engineName = $0.isEmpty ? nil : $0 }
        default:
            return false
        }
        return true

        func cycle(_ values: [String], current: String, apply: (String) -> Void) {
            guard !values.isEmpty else { return }
            let index = values.firstIndex(of: current) ?? 0
            let next = (index + delta + values.count) % values.count
            apply(values[next])
        }
    }

    private func activateSettingsFocus() {
        switch settingsFocus {
        case .done:
            onClose()
        case .category:
            if let first = paneControls.first { settingsFocus = .pane(first) }
        case .pane(let control):
            switch control {
            case .advancedMode:
                isAdvancedMode.toggle()
            case .uiScale:
                nudgeSettingsScale(1)
            case .sampleGames:
                model.togglePreviewSampleGames()
            case .skin(let raw):
                withAnimation(.easeInOut(duration: 0.25)) { skinRaw = raw }
            case .setupWizard:
                showingWizard = true
            case .layout:
                _ = adjustPicker(.layout, delta: 1)
            case .cardArt:
                _ = adjustPicker(.cardArt, delta: 1)
            case .showSteamIcon:
                showSteamIcon.toggle()
            case .showSettingsButton:
                showSettingsButton.toggle()
            case .hideBadges:
                hideLibraryBadges.toggle()
            case .hardRefresh:
                guard !model.isHardRefreshingGameInfo else { return }
                model.hardRefreshGameInfo()
            case .engineUpdate:
                engineActivate = UUID()
            case .unhide(let id):
                curation.unhide(id)
                settingsFocus = .category(.games)
            case .wineEngine:
                _ = adjustPicker(.wineEngine, delta: 1)
            case .d3dMetal:
                model.gameModeConfig.d3dMetal.toggle()
            case .moltenVK:
                model.gameModeConfig.moltenVKCX.toggle()
            case .dxvk:
                model.gameModeConfig.dxvk.toggle()
            case .dxmt:
                model.gameModeConfig.dxmt.toggle()
            case .fastSync:
                model.gameModeConfig.fastSync.toggle()
            case .language(let raw):
                languageRaw = raw
            case .openLogs:
                model.revealInFinder(ExeRunner.logsDir)
            case .openCrashes:
                model.revealInFinder(("~/Library/Logs/DiagnosticReports" as NSString).expandingTildeInPath)
            }
        }
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
        case .about: aboutTab
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
                    isOn: $isAdvancedMode,
                    isFocused: isPaneFocused(.advancedMode)
                )
                .id(PaneControl.advancedMode)
            }

            SettingsCard(skin: skin, title: L("UI Size")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $uiScale, in: 0.75...1.5)
                            .focusRing(isPaneFocused(.uiScale))
                            .id(PaneControl.uiScale)
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
                    ),
                    isFocused: isPaneFocused(.sampleGames)
                )
                .id(PaneControl.sampleGames)
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
                            MiniSkinTile(skin: candidate, isSelected: candidate == skin, isFocused: isPaneFocused(.skin(candidate.rawValue))) {
                                withAnimation(.easeInOut(duration: 0.25)) { skinRaw = candidate.rawValue }
                            }
                            .id(PaneControl.skin(candidate.rawValue))
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
                    .focusRing(isPaneFocused(.setupWizard))
                    .id(PaneControl.setupWizard)
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
                    labeledPicker(L("Layout"), selection: $libraryLayoutRaw, isFocused: isPaneFocused(.layout)) {
                        ForEach(LibraryLayoutStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .id(PaneControl.layout)
                    labeledPicker(L("Card Art"), selection: $artSourceRaw, isFocused: isPaneFocused(.cardArt)) {
                        ForEach(PlaydockArtSource.allCases) { source in
                            Text(source.displayName).tag(source.rawValue)
                        }
                    }
                    .id(PaneControl.cardArt)
                }
            }

            SettingsCard(skin: skin, title: L("Show Floating Steam Icon")) {
                VStack(spacing: 12) {
                    SettingsToggle(
                        skin: skin,
                        title: L("Show Floating Steam Icon"),
                        subtitle: L("The double-click-to-open-Steam icon in the corner of the grid. Turn off to collapse it to a small tab on the edge (still there, just out of the way)."),
                        isOn: $showSteamIcon,
                        isFocused: isPaneFocused(.showSteamIcon)
                    )
                    .id(PaneControl.showSteamIcon)
                    Divider().overlay(skin.accent.opacity(0.1))
                    SettingsToggle(
                        skin: skin,
                        title: L("Show Floating Settings Button"),
                        subtitle: nil,
                        isOn: $showSettingsButton,
                        isFocused: isPaneFocused(.showSettingsButton)
                    )
                    .id(PaneControl.showSettingsButton)
                }
            }

            SettingsCard(skin: skin, title: L("Hide Library Badges")) {
                SettingsToggle(
                    skin: skin,
                    title: L("Hide Library Badges"),
                    subtitle: L("The Custom/Mac/Windows label every game's art shows to say where it came from. Turn on to hide all three everywhere - every layout, every appearance."),
                    isOn: $hideLibraryBadges,
                    isFocused: isPaneFocused(.hideBadges)
                )
                .id(PaneControl.hideBadges)
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
                        .focusRing(isPaneFocused(.hardRefresh))
                        .id(PaneControl.hardRefresh)
                        Text(lastRefreshText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            EngineUpdatePanelSection(skin: skin, isFocused: isPaneFocused(.engineUpdate), activateToken: engineActivate)
                .id(PaneControl.engineUpdate)

            hiddenGamesCard

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
            ), isFocused: isPaneFocused(.wineEngine)) {
                ForEach(SikarugirEngine.availableEngineNames(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .id(PaneControl.wineEngine)
            Text(L("These are the same engines already downloaded by Sikarugir Creator."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().overlay(skin.accent.opacity(0.1))
            Text(L("Graphics")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            SettingsToggle(skin: skin, title: "D3DMETAL", subtitle: nil, isOn: $model.gameModeConfig.d3dMetal, isFocused: isPaneFocused(.d3dMetal))
                .id(PaneControl.d3dMetal)
            SettingsToggle(skin: skin, title: "MoltenVK CX", subtitle: nil, isOn: $model.gameModeConfig.moltenVKCX, isFocused: isPaneFocused(.moltenVK))
                .id(PaneControl.moltenVK)
            SettingsToggle(skin: skin, title: "DXVK", subtitle: nil, isOn: $model.gameModeConfig.dxvk, isFocused: isPaneFocused(.dxvk))
                .id(PaneControl.dxvk)
            SettingsToggle(skin: skin, title: "DXMT", subtitle: nil, isOn: $model.gameModeConfig.dxmt, isFocused: isPaneFocused(.dxmt))
                .id(PaneControl.dxmt)
            Divider().overlay(skin.accent.opacity(0.1))
            SettingsToggle(skin: skin, title: L("Fast Sync (ESYNC + MSYNC)"), subtitle: nil, isOn: $model.gameModeConfig.fastSync, isFocused: isPaneFocused(.fastSync))
                .id(PaneControl.fastSync)
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
                            .id(PaneControl.language(option.rawValue))
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
        .focusRing(isPaneFocused(.language(option.rawValue)))
    }

    /// The "undo" half of hiding a game: whatever was hidden shows here with an Unhide button.
    /// Empty state gets no card at all - no dead UI on a fresh install.
    @ViewBuilder
    private var hiddenGamesCard: some View {
        let hiddenIDs = curation.hidden
        if !hiddenIDs.isEmpty {
            SettingsCard(skin: skin, title: L("Hidden Games")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sortedHidden(hiddenIDs), id: \.id) { entry in
                        HStack {
                            Text(entry.name).font(.callout)
                            Spacer()
                            Button(L("Unhide")) { curation.unhide(entry.id) }
                                .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                                .focusRing(isPaneFocused(.unhide(entry.id)))
                                .id(PaneControl.unhide(entry.id))
                        }
                    }
                    Text(L("Hidden games stay installed; they're just removed from the library grid. Everything about them (play time, configs, launch history) is kept."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct HiddenEntry: Identifiable {
        let id: String
        let name: String
    }

    private func sortedHidden(_ ids: Set<String>) -> [HiddenEntry] {
        ids.map { id in
            let name = model.steamGames.first(where: { $0.appID == id })?.name
                ?? model.customGames.first(where: { $0.id == id })?.effectiveName
                ?? id
            return HiddenEntry(id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
                    .focusRing(isPaneFocused(.openLogs))
                    .id(PaneControl.openLogs)
                    Button {
                        model.revealInFinder(("~/Library/Logs/DiagnosticReports" as NSString).expandingTildeInPath)
                    } label: {
                        Label(L("Open Crash Reports"), systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                    .focusRing(isPaneFocused(.openCrashes))
                    .id(PaneControl.openCrashes)
                    Text(L("Every launch writes its own log here, plus a record of background checks. If something's not working, look here first."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            launchReliabilityCard
        }
    }

    /// A per-game tally of Playdock-driven launch outcomes - the same evidence the detail page's
    /// banner uses, collected in one place. Only surfaces at all once at least one launch has been
    /// recorded (no empty-state noise on a fresh install).
    @ViewBuilder
    private var launchReliabilityCard: some View {
        let summaries = LocalOutcomeTracker.summaries()
        if !summaries.isEmpty {
            SettingsCard(skin: skin, title: L("Launch Reliability")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summaries, id: \.appID) { summary in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gameName(for: summary.appID))
                                    .font(.callout.weight(.medium))
                                if summary.failures > 0 {
                                    Text(LF("%lld/%lld launches OK · last failure %@", summary.total - summary.failures, summary.total, relative(summary.lastFailure)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(LF("%lld launches, no errors", summary.total))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: summary.failures == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(summary.failures == 0 ? .green : .yellow)
                        }
                        if summary.appID != summaries.last?.appID { Divider().opacity(0.3) }
                    }
                    Text(L("Counts only launches started from Playdock."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func gameName(for appID: String) -> String {
        if let g = model.steamGames.first(where: { $0.appID == appID }) { return g.name }
        if let c = model.customGames.first(where: { $0.id == appID }) { return c.effectiveName }
        return L("Game") + " \(appID)"
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabHeader(.about)

            SettingsCard(skin: skin, title: "Playdock") {
                VStack(alignment: .leading, spacing: 8) {
                    SkinTitleText(text: "Playdock", size: 26, lineLimit: 1)
                    Text(LF("Version %@", appVersion))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("A Mac dashboard for the Windows games you run through Wine."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Built on the Sikarugir engine."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider().overlay(skin.accent.opacity(0.1)).padding(.vertical, 4)
                    HStack(spacing: 6) {
                        Text(L("Contact")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("thesuperjasonprocoolisplay@hotmail.com").font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "—"
    }

    // MARK: - Shared bits

    private func tabHeader(_ item: Category) -> some View {
        SkinTitleText(text: L(item.titleKey), size: 19, lineLimit: 1)
            .padding(.bottom, 2)
    }

    private func labeledPicker<SelectionValue: Hashable, Options: View>(
        _ label: String,
        selection: Binding<SelectionValue>,
        isFocused: Bool = false,
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
        .focusRing(isFocused)
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
    var isFocused: Bool = false
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
        .focusRing(isFocused)
    }
}

/// "Check for Engine Updates", card-styled for the settings panel. Same two-step flow as before
/// (check is free/instant; the potentially large download only happens on an explicit tap) - only
/// the chrome changed from a `Form` `Section` to a `SettingsCard`.
private struct EngineUpdatePanelSection: View {
    let skin: PlaydockSkin
    var isFocused: Bool = false
    var activateToken: UUID?
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
                    .focusRing(isFocused)
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
                    .focusRing(isFocused)
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
        .onChange(of: activateToken) { token in
            guard token != nil else { return }
            if let updateAvailable, !isDownloading {
                downloadUpdate(updateAvailable)
            } else if !isChecking {
                checkForUpdates()
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
    var isFocused: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .toggleStyle(.switch)
            .tint(skin.accent)
            .focusRing(isFocused)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
