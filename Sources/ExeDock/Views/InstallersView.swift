import SwiftUI
import UniformTypeIdentifiers

/// The install catalog. Each row is one real setup, with the download, the bottle, and the
/// extra components written out before anything runs. Steam uses Valve's official installer.
/// The other row runs a setup file the user already has, in a bottle of its own.
struct InstallersView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    private enum Recipe: Hashable {
        case steam
        case program
    }

    @LocalState private var recipe: Recipe = .steam
    @LocalState private var pickingProgram = false
    @LocalState private var programURL: URL?
    @LocalState private var bottleName = ""
    @LocalState private var editingBottleName = false

    private var programTitle: String {
        guard let programURL else { return "Windows installer" }
        return programURL.deletingPathExtension().lastPathComponent
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
        .fileImporter(isPresented: $pickingProgram, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            programURL = url
            bottleName = url.deletingPathExtension().lastPathComponent
            editingBottleName = false
            recipe = .program
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Installers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)
            recipeRow(.steam, title: "Steam", installed: SteamInstaller.isSteamInstalled)
            recipeRow(.program, title: programURL == nil ? "Windows installer" : programTitle, installed: false)
            Spacer()
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(skin.topBarBackground.opacity(0.55))
    }

    private func recipeRow(_ item: Recipe, title: String, installed: Bool) -> some View {
        let selected = recipe == item
        return Button {
            recipe = item
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: item == .steam ? steamIcon : programIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if installed {
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

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            switch recipe {
            case .steam: steamDetail
            case .program: programDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var steamDetail: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: steamIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steam")
                        .font(.system(size: 28, weight: .bold))
                    Text(steamStatusLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                steamAction
            }

            Text("Valve's client for buying, downloading, and playing Windows games. Playdock downloads the official setup and installs it into a Windows 10 bottle named Steam. You sign in inside Steam.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)

            HStack(spacing: 18) {
                Spacer()
                linkButton("More info", url: "https://store.steampowered.com/about/")
                linkButton("Download page", url: "https://store.steampowered.com/about/")
            }

            Text("Details")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 0) {
                planRow("Playdock will download the installer from Valve.", detail: SteamInstaller.steamSetupURL.absoluteString)
                planRow("Playdock will install Steam into a Windows 10 bottle named Steam.")
                planRow("The setup is the English silent installer. Sign-in happens inside Steam after it opens.")
                planRow("Playdock will also install Visual C++, DirectX 9, and Windows core fonts.")
            }
        }
        .padding(28)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var steamAction: some View {
        if model.isInstallingSteam {
            VStack(alignment: .trailing, spacing: 8) {
                ProgressView()
                Text(installingMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        } else if SteamInstaller.isSteamInstalled {
            Button("Open Steam") { model.openSteamClient() }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                .disabled(model.launchingTarget != nil)
        } else {
            Button("Install") { model.installAndRunSteam() }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
        }
    }

    private var installingMessage: String {
        if case .installing(let message) = model.steamStatus { return message }
        return "Installing Steam…"
    }

    private var steamStatusLine: String {
        if model.isInstallingSteam { return installingMessage }
        if SteamInstaller.isSteamInstalled { return "Installed in the Steam bottle." }
        if case .failed(let message) = model.steamStatus { return message }
        return "Official Windows installer."
    }

    private var programDetail: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: programIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(programTitle)
                        .font(.system(size: 28, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(programURL == nil ? "A setup file you already downloaded." : "Runs in its own Windows 10 bottle.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                programAction
            }

            Text(programURL == nil
                 ? "Choose a Windows setup program. Playdock gives it a new bottle, installs the usual runtime components, and opens the setup window. It does not guess which game the setup creates."
                 : "Playdock copies this setup into a new bottle and opens it. Finish the Windows installer in that window, then add the game to the library if you want it on the shelf.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)

            Text("Details")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 0) {
                if let programURL {
                    planRow("Playdock will run this setup.", detail: programURL.path)
                    bottleNameRow
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
    private var programAction: some View {
        if let message = model.programInstallMessage {
            VStack(alignment: .trailing, spacing: 8) {
                ProgressView()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
        } else if programURL == nil {
            Button("Choose Installer…") { pickingProgram = true }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
        } else {
            Button("Install") { startProgramInstall() }
                .buttonStyle(PlaydockButtonStyle(skinOverride: skin))
                .disabled(model.isInstallingSteam)
        }
    }

    private var bottleNameRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(skin.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Playdock will install it into a Windows 10 bottle named \(bottleName.isEmpty ? programTitle : bottleName).")
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if editingBottleName {
                    TextField("Bottle name", text: $bottleName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }
            Spacer(minLength: 8)
            Button(editingBottleName ? "Done" : "Edit") { editingBottleName.toggle() }
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

    private func linkButton(_ title: String, url: String) -> some View {
        Button {
            guard let destination = URL(string: url) else { return }
            NSWorkspace.shared.open(destination)
        } label: {
            Label(title, systemImage: title == "Download page" ? "arrow.down.circle" : "info.circle")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func startProgramInstall() {
        guard let programURL else { return }
        model.installDownloadedProgram(at: programURL.path, bottleName: bottleName)
    }

    private var steamIcon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
        let symbol = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Steam") ?? NSImage()
        symbol.size = NSSize(width: 64, height: 64)
        return symbol
    }

    private var programIcon: NSImage {
        if let programURL {
            let icon = NSWorkspace.shared.icon(forFile: programURL.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
        let symbol = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Installer") ?? NSImage()
        symbol.size = NSSize(width: 64, height: 64)
        return symbol
    }
}
