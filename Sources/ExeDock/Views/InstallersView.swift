import SwiftUI
import UniformTypeIdentifiers

/// The install catalog. Each row is a real Windows setup: the vendor's download, its own
/// bottle, and the runtime components, written out before anything runs.
struct InstallersView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    private enum Selection: Hashable {
        case catalog(String)
        case file
    }

    @LocalState private var selection: Selection = .catalog("steam")
    @LocalState private var query = ""
    @LocalState private var pickingProgram = false
    @LocalState private var programURL: URL?
    @LocalState private var bottleNames: [String: String] = [:]
    @LocalState private var editingBottleName = false
    @LocalState private var fileBottleName = ""
    @LocalState private var editingFileBottle = false

    private var matches: [CatalogInstaller] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CatalogInstaller.all }
        return CatalogInstaller.all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var selectedInstaller: CatalogInstaller? {
        guard case .catalog(let id) = selection else { return nil }
        return CatalogInstaller.all.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            Rectangle()
                .fill(skin.topBarBorderColor ?? Color.primary.opacity(0.12))
                .frame(width: 1)
            detail
        }
        .background(SkinBackground(skin: skin).ignoresSafeArea())
        .fontDesign(skin.fontDesign)
        .fileImporter(isPresented: $pickingProgram, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data, UTType(filenameExtension: "msi") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            programURL = url
            fileBottleName = url.deletingPathExtension().lastPathComponent
            editingFileBottle = false
            selection = .file
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Installers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(matches) { item in
                        catalogRow(item)
                    }
                    fileRow
                }
                .padding(.bottom, 24)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(skin.topBarBackground.opacity(0.55))
    }

    private func catalogRow(_ item: CatalogInstaller) -> some View {
        let selected = selection == .catalog(item.id)
        return Button {
            editingBottleName = false
            selection = .catalog(item.id)
        } label: {
            HStack(spacing: 10) {
                mark(for: item.name, steam: item.isSteam)
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.installedExePath() != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(skin.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? skin.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var fileRow: some View {
        let title = programURL?.deletingPathExtension().lastPathComponent ?? "From a file"
        let selected = selection == .file
        return Button {
            selection = .file
        } label: {
            HStack(spacing: 10) {
                mark(for: title, steam: false)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? skin.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            if let item = selectedInstaller {
                catalogDetail(item)
            } else {
                fileDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func catalogDetail(_ item: CatalogInstaller) -> some View {
        let bottleName = bottleNames[item.id] ?? item.name
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                mark(for: item.name, steam: item.isSteam, side: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 28, weight: .bold))
                    Text(statusLine(for: item))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                catalogAction(item, bottleName: bottleName)
            }

            Text(item.summary)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)

            HStack(spacing: 18) {
                Spacer()
                linkButton("More info", url: item.pageURL, symbol: "info.circle")
                linkButton("Download page", url: item.pageURL, symbol: "arrow.down.circle")
            }

            Text("Details")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 0) {
                planRow("Playdock will download the installer from the vendor.", detail: item.downloadURL.absoluteString)
                if item.isSteam {
                    planRow("Playdock will install Steam into a Windows 10 bottle named Steam.")
                    planRow("The setup is the English silent installer. Sign-in happens inside Steam after it opens.")
                } else {
                    bottleNameRow(
                        sentence: "Playdock will install it into a Windows 10 bottle named \(bottleName).",
                        name: Binding(
                            get: { bottleNames[item.id] ?? item.name },
                            set: { bottleNames[item.id] = $0 }
                        ),
                        editing: $editingBottleName
                    )
                    planRow("The vendor's setup window opens. You finish it there, including sign-in.")
                }
                planRow("Playdock will also install Visual C++, DirectX 9, and Windows core fonts.")
            }
        }
        .padding(28)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func catalogAction(_ item: CatalogInstaller, bottleName: String) -> some View {
        if item.isSteam, model.isInstallingSteam {
            progress(installingMessage)
        } else if model.catalogInstallID == item.id, let message = model.programInstallMessage {
            progress(message)
        } else if item.installedExePath() != nil {
            Button("Open") { model.openCatalogItem(item) }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                .disabled(model.launchingTarget != nil)
        } else {
            Button("Install") {
                if item.isSteam {
                    model.installAndRunSteam()
                } else {
                    model.installCatalogItem(item, bottleName: bottleName)
                }
            }
            .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
            .disabled(model.isInstallingSteam || model.programInstallMessage != nil)
        }
    }

    private var installingMessage: String {
        if case .installing(let message) = model.steamStatus { return message }
        return "Installing Steam…"
    }

    private func statusLine(for item: CatalogInstaller) -> String {
        if item.isSteam, model.isInstallingSteam { return installingMessage }
        if model.catalogInstallID == item.id, let message = model.programInstallMessage { return message }
        if item.installedExePath() != nil { return "Installed in the \(item.name) bottle." }
        if item.isSteam, case .failed(let message) = model.steamStatus { return message }
        return "Official Windows installer."
    }

    private var fileDetail: some View {
        let title = programURL?.deletingPathExtension().lastPathComponent ?? "From a file"
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                mark(for: title, steam: false, side: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(programURL == nil ? "A setup file you already downloaded." : "Runs in its own Windows 10 bottle.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                fileAction
            }

            Text(programURL == nil
                 ? "Choose a Windows setup that is not in the list. Playdock gives it a new bottle, installs the usual runtime components, and opens the setup window."
                 : "Playdock copies this setup into a new bottle and opens it. Finish the Windows installer in that window.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)

            Text("Details")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 0) {
                if let programURL {
                    planRow("Playdock will run this setup.", detail: programURL.path)
                    bottleNameRow(
                        sentence: "Playdock will install it into a Windows 10 bottle named \(fileBottleName.isEmpty ? title : fileBottleName).",
                        name: $fileBottleName,
                        editing: $editingFileBottle
                    )
                } else {
                    planRow("Playdock will run the setup file you choose.")
                    planRow("It goes in a new Windows 10 bottle, named after the file unless you rename it.")
                }
                planRow("Playdock will also install Visual C++, DirectX 9, and Windows core fonts before the setup window opens.")
            }
        }
        .padding(28)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fileAction: some View {
        if selection == .file, model.catalogInstallID == nil, let message = model.programInstallMessage {
            progress(message)
        } else if programURL == nil {
            Button("Choose Installer…") { pickingProgram = true }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
        } else {
            Button("Install") { startProgramInstall() }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                .disabled(model.isInstallingSteam || model.programInstallMessage != nil)
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240, alignment: .trailing)
        }
    }

    private func bottleNameRow(sentence: String, name: Binding<String>, editing: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(skin.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(sentence)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if editing.wrappedValue {
                    TextField("Bottle name", text: name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }
            Spacer(minLength: 8)
            Button(editing.wrappedValue ? "Done" : "Edit") { editing.wrappedValue.toggle() }
                .buttonStyle(.borderless)
                .foregroundStyle(skin.accent)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private func planRow(_ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(skin.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private func linkButton(_ title: String, url: URL, symbol: String) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func startProgramInstall() {
        guard let programURL else { return }
        model.installDownloadedProgram(at: programURL.path, bottleName: fileBottleName)
    }

    private func mark(for name: String, steam: Bool, side: CGFloat = 28) -> some View {
        Group {
            if steam, let icon = macSteamIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 14 : 6, style: .continuous))
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: side * 0.42, weight: .bold))
                    .foregroundStyle(skin.accent)
                    .frame(width: side, height: side)
                    .background(skin.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: side > 40 ? 14 : 6, style: .continuous))
            }
        }
    }

    private var macSteamIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }
}
