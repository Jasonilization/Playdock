import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var controllerObserver = ControllerObserver.shared
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    @LocalState private var isTargeted = false
    /// A global "make everything bigger or smaller" size control. A real UI scale rather than a
    /// plain visual zoom - a bare `.scaleEffect` on its own is a pure *visual* zoom - it can push
    /// content past the window's real edges (clipped, unusable) with nothing to compensate. The fix
    /// - a well-known SwiftUI technique, not something invented here - is to first propose the
    /// content a *smaller logical size* (the window's real size divided by the scale) and then
    /// scale that back *up* to exactly fill the real window again: at scale 1.3, the content lays
    /// itself out believing it only has ~77% as much room, so SwiftUI's own layout genuinely
    /// reflows around that (fewer grid columns, tighter choices) - it's not faked - and the
    /// subsequent scale-up then blows that smaller, correctly-laid-out result up to fill the actual
    /// window exactly, so nothing is ever clipped and everything stays properly interactive
    /// (`.scaleEffect` scales hit-testing right along with the visuals).
    @AppStorage("com.exedock.uiScale") private var uiScale: Double = 1.0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar
                // No separate Divider() here - topBar's own real per-skin bottom border (see its
                // doc comment) already does this seam's job; a second, flat gray line right under
                // a themed border doubled the seam the same way GameModeView's header fix did.
                VStack(spacing: 0) {
                    // The Steam dashboard has its own header/search/launch flow - the generic drop
                    // zone and toolbar only make sense on the Exe Loader side, so they'd just be
                    // visual noise (and a distraction from "just click your game") on the main tab.
                    if model.selectedSection != .gameMode {
                        dropZone
                        Divider()
                    }
                    content
                }
            }
            .frame(width: geometry.size.width / uiScale, height: geometry.size.height / uiScale)
            .scaleEffect(uiScale, anchor: .topLeading)
        }
        .alert("Playdock", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: controllerObserver.sectionStepRequest?.token) { _ in
            guard let direction = controllerObserver.sectionStepRequest?.direction else { return }
            stepSection(by: direction)
        }
        // Switching back to the Steam dashboard (from either the button or a controller's LB/RB)
        // re-scans it fresh, so a game installed or removed while looking at Library/C: Drive
        // shows up without a full relaunch.
        .onChange(of: model.selectedSection) { newValue in
            guard newValue == .gameMode else { return }
            model.refreshSteamGames()
        }
        // Deliberately its own overlay on the GeometryReader itself, not something living inside
        // the scaled content above - this slider always renders at a constant, readable size in
        // the window's real bottom-left corner, unaffected by whatever `uiScale` currently is.
        .overlay(alignment: .bottomLeading) {
            uiScaleSlider
        }
    }

    private var uiScaleSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.size.smaller")
                .font(.caption)
                .foregroundStyle(.secondary)
            // "5 notches, confirmed no overlap" - plain SwiftUI `Slider` never draws tick marks at
            // all (a `step:` just changes how far a drag jumps, nothing visible), so this wraps the
            // real, native `NSSlider` tick rendering instead, snapped to exactly 5 stops across the
            // same 0.75-1.5 range this always had - AppKit lays its own ticks out, so there's no
            // hand-placed overlay geometry here to ever misalign or overlap.
            FiveStopSlider(value: $uiScale)
                .frame(width: 130)
            Image(systemName: "textformat.size.larger")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .focusRing(controllerObserver.isConnected && controllerObserver.libraryFocus == .uiScale)
        .padding(14)
        .help("UI Size (\(Int(uiScale * 100))%)")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: - Top bar

    /// A compact, always-in-the-same-spot switcher instead of a full sidebar column - keeps the
    /// window's whole width for the dashboard, and (unlike a sidebar list) is something a
    /// controller can drive directly: LB/RB step through it from anywhere in the app, wired
    /// globally by `ControllerObserver` rather than needing this specific view to be focused.
    /// "top bar will be the same look... every aspect of the app should be the appearance," per
    /// live feedback - this used to be plain native window chrome regardless of skin, the one
    /// piece of visible UI that never picked up the active look. Real per-skin background/border
    /// (`skin.topBarBackground`/`topBarBorderColor`/`topBarBorderWidth`/`topBarHasGlow`, ported
    /// directly from each skin's own real `.topbar` CSS rule - see `PlaydockSkin`'s own doc
    /// comments for the exact values), not a generic material tint.
    private var topBar: some View {
        HStack(spacing: 14) {
            sectionSwitcher
                .overlay(alignment: .bottom) { ControllerConnectedGlow() }
            Spacer()
            if model.selectedSection != .gameMode {
                Button {
                    browseForExecutable()
                } label: {
                    Label("Select EXE…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(PlaydockButtonStyle(prominent: false, skinOverride: skin))
                Button {
                    model.installAndRunSteam()
                } label: {
                    Label("Install & Run Steam", systemImage: "gamecontroller.fill")
                }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                .disabled(model.isInstallingSteam)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fontDesign(skin.fontDesign)
        .background(skin.topBarBackground)
        .overlay(alignment: .bottom) {
            if let borderColor = skin.topBarBorderColor {
                Rectangle()
                    .fill(borderColor)
                    .frame(height: skin.topBarBorderWidth)
                    .shadow(color: skin.topBarHasGlow ? skin.accent.opacity(0.7) : .clear, radius: 6, y: 2)
            }
        }
        // "add smooth af things too" - switching skins (Settings, or the setup wizard) crossfades
        // the whole bar's real color identity instead of snapping between two flat colors.
        .animation(.easeInOut(duration: 0.25), value: skinRaw)
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 10) {
            sectionButton(.gameMode)
            // A small visual gap, not a label - Steam still reads as the primary destination and
            // C: Drive as the secondary "Exe Loader" tool, just without spending a whole sidebar
            // section header on it. The old "Library" tab (a generic detected-apps browser) was
            // removed entirely - "remove the other tab one, as that's the game browser," per live
            // feedback: Game Mode's own dashboard is the real, polished game browser now, and a
            // second, cruder one alongside it was pure redundancy.
            Divider().frame(height: 20)
            sectionButton(.cDrive)
        }
    }

    private func sectionButton(_ section: AppModel.SidebarSection) -> some View {
        let isSelected = model.selectedSection == section
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.selectedSection = section }
        } label: {
            Label(title(for: section), systemImage: icon(for: section))
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 46, height: 36)
        }
        .buttonStyle(.plain)
        .focusRing(controllerObserver.isConnected && controllerObserver.libraryFocus == .section(section == .gameMode ? 0 : 1))
        .background(isSelected ? skin.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: skin.cardRadius > 12 ? 8 : skin.cardRadius))
        .foregroundStyle(isSelected ? skin.accent : Color.secondary)
        // "add smooth af things too" - a real spring pop on selection instead of the flat instant
        // swap the accent-color background/foreground used to do.
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isSelected)
        .help(title(for: section))
    }

    private func title(for section: AppModel.SidebarSection) -> String {
        switch section {
        case .gameMode: return "Steam"
        case .cDrive: return "C: Drive"
        }
    }

    private func icon(for section: AppModel.SidebarSection) -> String {
        switch section {
        case .gameMode: return "gamecontroller.fill"
        case .cDrive: return "internaldrive"
        }
    }

    /// Wired to the controller's shoulder buttons via `ControllerObserver`, so paging between
    /// Steam and C: Drive works from anywhere in the app.
    private func stepSection(by direction: Int) {
        let all = AppModel.SidebarSection.allCases
        guard let currentIndex = all.firstIndex(of: model.selectedSection) else { return }
        let newIndex = (currentIndex + direction + all.count) % all.count
        withAnimation(.easeInOut(duration: 0.2)) {
            model.selectedSection = all[newIndex]
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.selectedSection {
            case .gameMode:
                GameModeView()
            case .cDrive:
                CDriveView()
            }
        }
        .id(model.selectedSection)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: model.selectedSection)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34))
                .foregroundStyle(isTargeted ? skin.accent : .secondary)
            Text(isTargeted ? "Drop to run" : "Drag an .exe here to run it")
                .font(.title3)
                .fontDesign(skin.fontDesign)
            if let status = model.statusMessage {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if case .installing(let message) = model.steamStatus {
                VStack(spacing: 4) {
                    ProgressView(value: nil as Double?)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(isTargeted ? skin.accent.opacity(0.12) : Color.clear)
        .animation(.default, value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(fileURLType) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
            let url: URL?
            switch item {
            case let data as Data:
                url = URL(dataRepresentation: data, relativeTo: nil)
            case let nsurl as NSURL:
                url = nsurl as URL
            case let plainURL as URL:
                url = plainURL
            default:
                url = nil
            }
            guard let resolvedURL = url else { return }
            DispatchQueue.main.async {
                model.runDroppedFile(at: resolvedURL.path)
            }
        }
        return true
    }

    private func browseForExecutable() {
        let panel = NSOpenPanel()
        if let exeType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exeType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.runDroppedFile(at: url.path)
        }
    }
}

/// A real `NSSlider` with 5 visible tick marks, snapped so a drag can only ever land on one of
/// them - "5 toggles/notches, confirmed no overlap" for the UI Size control. Plain SwiftUI
/// `Slider` has no tick-mark rendering at all, so this is a thin `NSViewRepresentable` instead of
/// a hand-drawn overlay - AppKit places its own 5 marks evenly across the track, so there's no
/// custom geometry here that could ever misalign or overlap the thumb/track.
private struct FiveStopSlider: NSViewRepresentable {
    @Binding var value: Double

    static let minValue = 0.75
    static let maxValue = 1.5

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: Self.minValue, maxValue: Self.maxValue, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if nsView.doubleValue != value {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        let parent: FiveStopSlider
        init(_ parent: FiveStopSlider) { self.parent = parent }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = sender.doubleValue
        }
    }
}
