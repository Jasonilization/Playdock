import Foundation
import AppKit

/// Steam Play starts the game from the Mac Steam app (`steam://rungameid`), the same way
/// NotProton and steamplay-mac do. Playdock does not inject those tools; if they are already
/// installed, Steam uses them when it runs the title.
enum SteamPlaySupport {
    static let nativeSteamAppPath = "/Applications/Steam.app"
    static let nativeSteamRoot = ("~/Library/Application Support/Steam" as NSString).expandingTildeInPath
    static let notProtonRoot = ("~/Library/Application Support/notproton" as NSString).expandingTildeInPath
    static let notProtonURL = URL(string: "https://github.com/NotProtonNot/NotProton")!
    static let steamplayMacURL = URL(string: "https://github.com/Drustburn/steamplay-mac")!

    static var nativeSteamAppExists: Bool {
        FileManager.default.fileExists(atPath: nativeSteamAppPath)
    }

    static var nativeSteamAppURL: URL {
        URL(fileURLWithPath: nativeSteamAppPath)
    }

    /// True when NotProton or steamplay-mac is already on this Mac.
    static var externalSteamPlayInstalled: Bool {
        FileManager.default.fileExists(atPath: (notProtonRoot as NSString).appendingPathComponent("notproton.dylib"))
            || FileManager.default.fileExists(atPath: (notProtonRoot as NSString).appendingPathComponent("wine"))
    }

    static var statusLine: String {
        if !nativeSteamAppExists {
            return "Steam Play needs Steam in /Applications."
        }
        if externalSteamPlayInstalled {
            return "NotProton is installed. Steam Play starts the game from Steam."
        }
        return "Steam Play starts the game from Steam. NotProton or steamplay-mac lets Steam run Windows titles."
    }

    static func runURL(appID: String) -> URL? {
        URL(string: "steam://rungameid/\(appID)")
    }

    /// Ask Steam.app itself to run the game.
    @discardableResult
    static func openInSteam(appID: String) -> Bool {
        guard let url = runURL(appID: appID) else { return false }
        if nativeSteamAppExists {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: nativeSteamAppURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }
        return NSWorkspace.shared.open(url)
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
