import Foundation
import AppKit

enum SteamPlayInstallError: Error, LocalizedError {
    case brewMissing
    case brewFailed(String)

    var errorDescription: String? {
        switch self {
        case .brewMissing:
            return "Homebrew is not installed. Download NotProton from GitHub, then open it and tap Install."
        case .brewFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "NotProton did not install. Download it from GitHub, then open it and tap Install."
            }
            return "NotProton did not install: \(trimmed)"
        }
    }
}

/// Steam Play is NotProton: Mac Steam downloads and runs Windows games on this Mac.
/// Playdock installs and opens NotProton; it does not vendor NotProton's code.
enum SteamPlaySupport {
    static let nativeSteamAppPath = "/Applications/Steam.app"
    static let nativeSteamRoot = ("~/Library/Application Support/Steam" as NSString).expandingTildeInPath
    static let notProtonAppPath = "/Applications/NotProton.app"
    static let notProtonRoot = ("~/Library/Application Support/notproton" as NSString).expandingTildeInPath
    static let notProtonBundleID = "com.notproton.NotProton"
    static let brewCask = "notprotonnot/notproton/notproton"
    static let notProtonURL = URL(string: "https://github.com/NotProtonNot/NotProton")!
    static let notProtonReleasesURL = URL(string: "https://github.com/NotProtonNot/NotProton/releases")!

    static var nativeSteamAppExists: Bool {
        FileManager.default.fileExists(atPath: nativeSteamAppPath)
    }

    static var nativeSteamAppURL: URL {
        URL(fileURLWithPath: nativeSteamAppPath)
    }

    static var notProtonAppExists: Bool {
        FileManager.default.fileExists(atPath: notProtonAppPath)
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: notProtonBundleID) != nil
    }

    static var notProtonAppURL: URL? {
        if FileManager.default.fileExists(atPath: notProtonAppPath) {
            return URL(fileURLWithPath: notProtonAppPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: notProtonBundleID)
    }

    /// NotProton has installed its Steam Play pieces, so Mac Steam can fetch Windows titles here.
    static var isSteamPlayEnabled: Bool {
        let fm = FileManager.default
        let dylib = (notProtonRoot as NSString).appendingPathComponent("notproton.dylib")
        if fm.fileExists(atPath: dylib) { return true }
        let wine = (notProtonRoot as NSString).appendingPathComponent("wine")
        if fm.fileExists(atPath: wine) { return true }
        let runners = (notProtonRoot as NSString).appendingPathComponent("runners")
        if let items = try? fm.contentsOfDirectory(atPath: runners), items.contains(where: { $0 != ".DS_Store" }) {
            return true
        }
        return false
    }

    static var externalSteamPlayInstalled: Bool { isSteamPlayEnabled }

    static var statusLine: String {
        if !nativeSteamAppExists {
            return "Steam Play needs Steam in /Applications."
        }
        if isSteamPlayEnabled {
            return "NotProton is ready. Mac Steam can download and run Windows games on this Mac."
        }
        if notProtonAppExists {
            return "Open NotProton and tap Install. Until that finishes, Steam will send Windows games to another computer."
        }
        return "Install NotProton so Mac Steam can download Windows games here and launch them."
    }

    static func isMacBuild(_ game: SteamGame) -> Bool {
        game.source == .nativeMac && windowsExecutable(for: game) == nil
    }

    /// `steam://` is safe for a Mac build, or after NotProton has enabled Steam Play.
    /// A Windows title without NotProton made Steam download GTA IV on another computer.
    static func usesMacSteamClient(for game: SteamGame, steamPlayEnabled: Bool = isSteamPlayEnabled) -> Bool {
        if steamPlayEnabled { return true }
        return isMacBuild(game)
    }

    static func runURL(appID: String) -> URL? {
        URL(string: "steam://rungameid/\(appID)")
    }

    static func installURL(appID: String) -> URL? {
        URL(string: "steam://install/\(appID)")
    }

    @discardableResult
    static func openInSteam(appID: String) -> Bool {
        guard let url = runURL(appID: appID) else { return false }
        return openMacSteam(with: url)
    }

    @discardableResult
    static func openMacSteam(with url: URL? = nil) -> Bool {
        if nativeSteamAppExists {
            if let url {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: nativeSteamAppURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                NSWorkspace.shared.openApplication(at: nativeSteamAppURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
            return true
        }
        if let url {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    @discardableResult
    static func openNotProton() -> Bool {
        guard let url = notProtonAppURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return true
    }

    static func openNotProtonDownloadPage() {
        NSWorkspace.shared.open(notProtonReleasesURL)
    }

    static func brewPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func installNotProton(progress: @escaping (String) -> Void) async throws {
        if notProtonAppExists {
            progress("NotProton is already in /Applications.")
            return
        }
        guard let brew = brewPath() else {
            throw SteamPlayInstallError.brewMissing
        }
        progress("Installing NotProton…")
        let output: String = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "--cask", brewCask]
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
            env["NONINTERACTIVE"] = "1"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw SteamPlayInstallError.brewFailed(text)
            }
            return text
        }.value
        if !notProtonAppExists {
            throw SteamPlayInstallError.brewFailed(output)
        }
        progress("NotProton is installed.")
    }

    static func windowsExecutable(for game: SteamGame) -> String? {
        if let path = game.iconExePath, path.lowercased().hasSuffix(".exe"), FileManager.default.fileExists(atPath: path) {
            return path
        }
        let folders = [game.installFolderPath, nativeInstallFolder(appID: game.metadataAppID, installDir: game.installDir)].compactMap { $0 }
        for folder in folders where FileManager.default.fileExists(atPath: folder) {
            if let exe = ExecutableHeuristics.candidateExecutables(inFolder: folder).first?.path {
                return exe
            }
        }
        return nil
    }

    static func nativeInstallFolder(appID: String, installDir: String) -> String? {
        let steamapps = (nativeSteamRoot as NSString).appendingPathComponent("steamapps")
        let common = (steamapps as NSString).appendingPathComponent("common/\(installDir)")
        if FileManager.default.fileExists(atPath: common) { return common }
        let vdf = (steamapps as NSString).appendingPathComponent("libraryfolders.vdf")
        guard let text = try? String(contentsOfFile: vdf, encoding: .utf8) else { return nil }
        for steamappsPath in SteamLibrary.libraryPaths(fromLibraryFoldersVDF: text) {
            let folder = (steamappsPath as NSString).appendingPathComponent("common/\(installDir)")
            if FileManager.default.fileExists(atPath: folder) { return folder }
        }
        return nil
    }
}
