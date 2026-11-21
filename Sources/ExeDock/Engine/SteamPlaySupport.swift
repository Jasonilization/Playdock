import Foundation
import AppKit

struct SteamPlayPaths {
    var steamRoot: String
    var appBundleMacOS: String
    var toolSupport: String

    static var live: SteamPlayPaths {
        let root = ("~/Library/Application Support/Steam" as NSString).expandingTildeInPath
        return SteamPlayPaths(
            steamRoot: root,
            appBundleMacOS: (root as NSString).appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS"),
            toolSupport: SikarugirEngine.supportFile("SteamPlay")
        )
    }

    var steamDevCfg: String {
        (appBundleMacOS as NSString).appendingPathComponent("steam_dev.cfg")
    }

    var toolRoots: [String] {
        [
            (appBundleMacOS as NSString).appendingPathComponent("compatibilitytools.d/\(SteamPlayTool.toolID)"),
            (appBundleMacOS as NSString).appendingPathComponent("compatibilitytool.d/\(SteamPlayTool.toolID)"),
            (steamRoot as NSString).appendingPathComponent("compatibilitytools.d/\(SteamPlayTool.toolID)"),
        ]
    }
}

struct SteamPlayEnableResult: Equatable {
    var wroteDevCfg: Bool
    var needsSteamRestart: Bool { wroteDevCfg }
}

enum SteamPlaySetupError: Error, LocalizedError {
    case missingSteam
    case missingEngine(String)

    var errorDescription: String? {
        switch self {
        case .missingSteam:
            return "Steam Play needs Steam in /Applications."
        case .missingEngine(let detail):
            return "Steam Play needs Playdock's Wine engine. \(detail)"
        }
    }
}

/// Playdock's own Steam Play. Mac Steam downloads Windows games on this Mac; Playdock Wine runs them.
/// `steam_dev.cfg` is Steam's documented platform override. The compatibility tool is ours.
enum SteamPlaySupport {
    static let nativeSteamAppPath = "/Applications/Steam.app"
    static let nativeSteamRoot = SteamPlayPaths.live.steamRoot
    static let steamDevCfgLine = "@sSteamCmdForcePlatformType windows"
    static let steamBundleID = "com.valvesoftware.steam"

    static var nativeSteamAppExists: Bool {
        FileManager.default.fileExists(atPath: nativeSteamAppPath)
    }

    static var nativeSteamAppURL: URL {
        URL(fileURLWithPath: nativeSteamAppPath)
    }

    static var isEnabled: Bool {
        isEnabled(paths: .live)
    }

    static func isEnabled(paths: SteamPlayPaths) -> Bool {
        guard let text = try? String(contentsOfFile: paths.steamDevCfg, encoding: .utf8),
              text.contains(steamDevCfgLine) else { return false }
        return paths.toolRoots.contains { SteamPlayTool.isInstalled(in: $0) }
    }

    static var statusLine: String {
        if !nativeSteamAppExists {
            return "Steam Play needs Steam in /Applications."
        }
        if isEnabled {
            return "Steam Play is on. Mac Steam downloads Windows games on this Mac. Playdock Wine runs them."
        }
        return "Set up Steam Play so Mac Steam downloads Windows games here instead of another computer."
    }

    static func isMacBuild(_ game: SteamGame) -> Bool {
        game.source == .nativeMac && windowsExecutable(for: game) == nil
    }

    /// After Steam Play is on, `steam://` is safe for Windows titles — they install on this Mac.
    static func usesMacSteamClient(for game: SteamGame, steamPlayEnabled: Bool = isEnabled) -> Bool {
        if steamPlayEnabled { return true }
        return isMacBuild(game)
    }

    static func runURL(appID: String) -> URL? {
        URL(string: "steam://rungameid/\(appID)")
    }

    static func installURL(appID: String) -> URL? {
        URL(string: "steam://install/\(appID)")
    }

    static func enable(paths: SteamPlayPaths = .live) throws -> SteamPlayEnableResult {
        guard nativeSteamAppExists || FileManager.default.fileExists(atPath: paths.appBundleMacOS) else {
            throw SteamPlaySetupError.missingSteam
        }
        try FileManager.default.createDirectory(atPath: paths.appBundleMacOS, withIntermediateDirectories: true)
        let wroteDevCfg = try writeSteamDevCfg(paths: paths)
        for root in paths.toolRoots {
            try SteamPlayTool.install(into: root)
        }
        try writeWineEnvironment(supportDir: paths.toolSupport)
        return SteamPlayEnableResult(wroteDevCfg: wroteDevCfg)
    }

    static func writeSteamDevCfg(paths: SteamPlayPaths) throws -> Bool {
        let body = steamDevCfgLine + "\n"
        if let existing = try? String(contentsOfFile: paths.steamDevCfg, encoding: .utf8),
           existing.contains(steamDevCfgLine) {
            return false
        }
        try body.write(toFile: paths.steamDevCfg, atomically: true, encoding: .utf8)
        return true
    }

    static func writeWineEnvironment(supportDir: String) throws {
        let wineBinary: String
        let libraryPath: String
        do {
            wineBinary = try SikarugirEngine.wineBinaryPath()
            libraryPath = try SikarugirEngine.runtimeEnvironment()["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        } catch {
            throw SteamPlaySetupError.missingEngine(error.localizedDescription)
        }
        let loader = ExeRunner.unixLoaderPath(wineBinary: wineBinary)
        try SteamPlayTool.writeEnvironment(
            to: supportDir,
            wineLoader: loader,
            prefixPath: BottleManager.shared.steamBottle.prefixPath,
            libraryPath: libraryPath,
            extra: GameModeConfig.maximumCompatibility.environment
        )
    }

    @discardableResult
    static func openInSteam(appID: String) -> Bool {
        guard let url = runURL(appID: appID) else { return false }
        return openMacSteam(with: url)
    }

    @discardableResult
    static func openInstallInSteam(appID: String) -> Bool {
        guard let url = installURL(appID: appID) else { return false }
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

    static var isMacSteamRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == steamBundleID }
    }

    static func restartMacSteam() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == steamBundleID }
        for app in running { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            openMacSteam()
        }
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
