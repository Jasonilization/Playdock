import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "+ Add Game" entry point for the Custom Game Library: pick a single `.exe` directly, point
/// at a folder (asks which executable if more than one plausible one is found), or drag either
/// straight onto this sheet. Runs metadata discovery (local PE info, then a confident-only Steam
/// catalog match - see `CustomGameMetadataDiscovery`) before handing the finished `CustomGame` to
/// `AppModel.addCustomGame`. Controller-navigable like the rest of this app's sheets: D-pad moves a
/// focus ring over whatever this sheet is currently showing, A activates it, B closes it.
struct AddGameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controllerObserver = ControllerObserver.shared

    @LocalState private var isTargeted = false
    @LocalState private var pendingCandidates: [CandidateExecutable] = []
    @LocalState private var pendingFolderName = ""
    /// The full path of a folder the user explicitly chose (via "Choose Folder…," or a dropped
    /// folder) - `nil` when a lone exe was picked directly. Threaded through to
    /// `CustomGameFileImporter`, which moves that whole folder as a unit when it's set.
    @LocalState private var pendingFolderPath: String?
    @LocalState private var isDiscovering = false
    @LocalState private var discoveringStatus = "Discovering game details…"
    @LocalState private var errorMessage: String?
    /// Which row is highlighted for controller navigation - 0/1 for the two method buttons on the
    /// chooser screen, or an index into `pendingCandidates` once a folder yields more than one.
    @LocalState private var focusedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Game").font(.title3).bold()
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            Divider()

            if isDiscovering {
                discoveringView
            } else if !pendingCandidates.isEmpty {
                candidatePicker
            } else {
                methodChooser
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
            }
        }
        .frame(width: 480, height: 460)
        .onChange(of: controllerObserver.directionPress?.token) { _ in
            guard let direction = controllerObserver.directionPress?.direction else { return }
            moveFocus(direction)
        }
        .onChange(of: controllerObserver.primaryPress) { _ in
            activateFocused()
        }
        .onChange(of: controllerObserver.secondaryPress) { _ in
            dismiss()
        }
    }

    // MARK: - Method chooser

    private var methodChooser: some View {
        VStack(spacing: 16) {
            dropZone
            methodButton(index: 0, title: "Choose EXE…", systemImage: "doc.badge.plus", action: chooseEXE)
            methodButton(index: 1, title: "Choose Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(isTargeted ? "Drop to add" : "Drag a .exe or game folder here")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [6])))
        .animation(.default, value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func methodButton(index: Int, title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.big)
        .focusRing(controllerObserver.isConnected && focusedIndex == index)
    }

    // MARK: - Candidate picker

    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which executable launches the game?")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(pendingCandidates.enumerated()), id: \.element.id) { index, candidate in
                            candidateRow(candidate, isFocused: controllerObserver.isConnected && focusedIndex == index) {
                                selectCandidate(candidate)
                            }
                            .id(candidate.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: focusedIndex) { index in
                    guard pendingCandidates.indices.contains(index) else { return }
                    withAnimation { scrollProxy.scrollTo(pendingCandidates[index].id, anchor: .center) }
                }
            }
        }
    }

    private func candidateRow(_ candidate: CandidateExecutable, isFocused: Bool, onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if candidate.isBestGuess {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName).font(.body)
                    Text(candidate.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(candidate.sizeBytes), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusRing(isFocused)
    }

    // MARK: - Discovering

    private var discoveringView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(discoveringStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controller navigation

    private func moveFocus(_ direction: ControllerDirection) {
        guard !isDiscovering, direction == .up || direction == .down else { return }
        let count = pendingCandidates.isEmpty ? 2 : pendingCandidates.count
        let delta = direction == .up ? -1 : 1
        focusedIndex = min(max(0, focusedIndex + delta), count - 1)
    }

    private func activateFocused() {
        guard !isDiscovering else { return }
        if pendingCandidates.isEmpty {
            if focusedIndex == 0 { chooseEXE() } else { chooseFolder() }
        } else if pendingCandidates.indices.contains(focusedIndex) {
            selectCandidate(pendingCandidates[focusedIndex])
        }
    }

    // MARK: - Actions

    private func chooseEXE() {
        let panel = NSOpenPanel()
        if let exeType = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exeType] }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginDiscovery(exePath: url.path, folderName: nil, pickedFolderPath: nil)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleFolder(at: url.path, folderName: url.lastPathComponent)
    }

    private func handleFolder(at path: String, folderName: String) {
        let candidates = CustomGameFolderScanner.scan(folder: path)
        guard !candidates.isEmpty else {
            errorMessage = "No executable found in that folder."
            return
        }
        errorMessage = nil
        if candidates.count == 1 {
            beginDiscovery(exePath: candidates[0].path, folderName: folderName, pickedFolderPath: path)
        } else {
            pendingFolderName = folderName
            pendingFolderPath = path
            pendingCandidates = candidates
            focusedIndex = candidates.firstIndex(where: \.isBestGuess) ?? 0
        }
    }

    private func selectCandidate(_ candidate: CandidateExecutable) {
        beginDiscovery(exePath: candidate.path, folderName: pendingFolderName, pickedFolderPath: pendingFolderPath)
    }

    /// Discovers metadata, then moves the game into Playdock's own managed bottle - see
    /// `CustomGameFileImporter`'s own doc comment for why. The move can take a while for a large
    /// game folder (it's a real file copy across volumes when the source isn't on the same disk as
    /// Playdock's own data), so it runs off the main thread with its own status text, same as
    /// discovery itself already does.
    private func beginDiscovery(exePath: String, folderName: String?, pickedFolderPath: String?) {
        // A real, confirmed bug: `errorMessage` is a sibling of the isDiscovering/methodChooser/
        // candidatePicker switch, not scoped inside any one of them - so a failure from a *previous*
        // attempt (import error, metadata discovery error) stayed on screen underneath the new
        // "Discovering game details…" spinner on a retry, never actually cleared until success.
        isDiscovering = true
        errorMessage = nil
        discoveringStatus = "Discovering game details…"
        Task {
            let discovered = await CustomGameMetadataDiscovery.discover(exePath: exePath, folderName: folderName)
            await MainActor.run { discoveringStatus = "Moving \(folderName ?? (exePath as NSString).lastPathComponent) into Playdock…" }
            do {
                let finalExePath = try await Task.detached(priority: .utility) {
                    try CustomGameFileImporter.importIntoManagedBottle(exePath: exePath, pickedFolderPath: pickedFolderPath)
                }.value
                await MainActor.run {
                    model.addCustomGame(CustomGame(exePath: finalExePath, discovered: discovered))
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(fileURLType) }) else { return false }
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
                handleDroppedURL(resolvedURL)
            }
        }
        return true
    }

    private func handleDroppedURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            handleFolder(at: url.path, folderName: url.lastPathComponent)
        } else if url.pathExtension.lowercased() == "exe" {
            errorMessage = nil
            beginDiscovery(exePath: url.path, folderName: nil, pickedFolderPath: nil)
        } else {
            errorMessage = "Drop a .exe file or a game folder."
        }
    }
}
