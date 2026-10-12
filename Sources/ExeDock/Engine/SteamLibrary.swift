import Foundation

/// Scans a Steam library for installed games the same way Steam itself tracks them - via the
/// `appmanifest_*.acf` files Steam writes into `steamapps/` for every installed app. Used for both
/// ExeDock's own Windows Steam bottle and, separately, the real macOS Steam client's own library
/// (see `installedNativeMacGames()`) - the manifest format is identical either way.
enum SteamLibrary {
    /// Steam's own shared runtime payloads that show up as "apps" in steamapps/ but aren't games.
    private static let ignoredNames: Set<String> = ["steamworks common redistributables"]

    private static var wineBottleSteamAppsPath: String {
        (SteamInstaller.steamBottle.driveCPath as NSString)
            .appendingPathComponent("Program Files (x86)/Steam/steamapps")
    }

    static func installedGames() -> [SteamGame] {
        installedGames(inSteamAppsPath: wineBottleSteamAppsPath, source: .wineBottle, idPrefix: nil)
    }

    private static let nativeMacSteamRoot = ("~/Library/Application Support/Steam" as NSString).expandingTildeInPath

    /// Every game installed through the real, separately-installed macOS Steam client - a
    /// completely different Steam install from ExeDock's own Windows one, confirmed live to exist
    /// side by side on the same Mac (`~/Library/Application Support/Steam`). Every library folder
    /// Steam itself knows about is scanned, not just the default one, by reading the exact same
    /// `libraryfolders.vdf` format Steam's own client writes - so a second library folder (an
    /// external drive, say) is picked up automatically too.
    static func installedNativeMacGames() -> [SteamGame] {
        nativeMacSteamAppsPaths()
            .flatMap { installedGames(inSteamAppsPath: $0, source: .nativeMac, idPrefix: "MAC-") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func nativeMacSteamAppsPaths() -> [String] {
        let defaultPath = (nativeMacSteamRoot as NSString).appendingPathComponent("steamapps")
        let vdfPath = (defaultPath as NSString).appendingPathComponent("libraryfolders.vdf")
        guard let text = try? String(contentsOfFile: vdfPath, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: defaultPath) ? [defaultPath] : []
        }
        let paths = libraryPaths(fromLibraryFoldersVDF: text)
        return paths.isEmpty ? [defaultPath] : paths
    }

    /// The pure half of `libraryfolders.vdf` parsing - every `"path"` entry with Steam's own
    /// separator escaping undone and `/steamapps` appended, no disk access, so it's directly
    /// unit-testable against fixture text. The disk-reading wrapper above owns the fallback to
    /// the default library when the file (or its entries) don't exist.
    static func libraryPaths(fromLibraryFoldersVDF text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\"path\"\\s+\"([^\"]*)\"") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            // Steam escapes its own path separators in this file (e.g. "\\" for a literal "/") -
            // undo that before treating it as a real filesystem path.
            let raw = String(text[valueRange]).replacingOccurrences(of: "\\\\", with: "/")
            return (raw as NSString).appendingPathComponent("steamapps")
        }
    }

    /// The fields `parseManifest` extracts from one `appmanifest_*.acf`.
    struct ParsedManifest: Equatable {
        let appID: String
        let name: String
        let installDir: String
        let sizeOnDisk: Int64?
        let buildID: String?
        let lastUpdated: Date?
    }

    /// The pure half of manifest parsing - field extraction plus both "is this actually a
    /// launchable game" gates, with no disk access so it's directly unit-testable. `nil` means
    /// not worth listing: a required field is missing, the download isn't finished, or it's one
    /// of Steam's shared runtime payloads rather than a game.
    static func parseManifest(_ text: String) -> ParsedManifest? {
        guard let appID = value(for: "appid", in: text),
              let name = value(for: "name", in: text),
              let installDir = value(for: "installdir", in: text),
              !ignoredNames.contains(name.lowercased()) else { return nil }

        // Steam sets bit 0x4 in StateFlags once an app is fully installed and playable -
        // without this check, a game whose download is still in progress (its folder
        // already exists, just incomplete) would show up as launchable. Treat a missing/
        // unparseable StateFlags leniently (include it) rather than hiding a real game.
        if let stateFlags = value(for: "StateFlags", in: text).flatMap({ Int($0) }), stateFlags & 0x4 == 0 {
            return nil
        }

        return ParsedManifest(
            appID: appID,
            name: name,
            installDir: installDir,
            sizeOnDisk: value(for: "SizeOnDisk", in: text).flatMap { Int64($0) },
            buildID: value(for: "buildid", in: text),
            lastUpdated: value(for: "LastUpdated", in: text).flatMap { TimeInterval($0) }
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        )
    }

    private static func installedGames(inSteamAppsPath steamAppsPath: String, source: SteamGameSource, idPrefix: String?) -> [SteamGame] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: steamAppsPath) else { return [] }
        let commonPath = (steamAppsPath as NSString).appendingPathComponent("common")

        let games: [SteamGame] = entries
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            .compactMap { manifestName -> SteamGame? in
                let manifestPath = (steamAppsPath as NSString).appendingPathComponent(manifestName)
                guard let text = try? String(contentsOfFile: manifestPath, encoding: .utf8),
                      let parsed = parseManifest(text) else { return nil }

                let gameFolder = (commonPath as NSString).appendingPathComponent(parsed.installDir)
                guard fm.fileExists(atPath: gameFolder) else { return nil }

                return SteamGame(
                    appID: (idPrefix ?? "") + parsed.appID, name: parsed.name, installDir: parsed.installDir,
                    installFolderPath: gameFolder,
                    iconExePath: source == .wineBottle ? iconExecutable(inFolder: gameFolder) : nil,
                    sizeOnDisk: (parsed.sizeOnDisk ?? 0) > 0 ? parsed.sizeOnDisk : nil,
                    buildID: (parsed.buildID != "0") ? parsed.buildID : nil,
                    lastUpdated: parsed.lastUpdated,
                    source: source
                )
            }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Pulls a top-level `"key"    "value"` pair out of an ACF/VDF manifest. Steam only ever nests
    /// `appid`/`name`/`installdir` once, right under `AppState`, so a first-match regex is enough -
    /// no need for a full VDF parser for the handful of fields ExeDock actually reads.
    private static func value(for key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s+\"([^\"]*)\"", options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    /// Best-effort search for an executable to grab an icon from. Source-engine-style games nest
    /// their real binary several folders deep (e.g. `game/bin/win64/`), deeper than a typical
    /// Program Files install, so this looks further down than `CDriveScanner` does.
    private static func iconExecutable(inFolder folder: String) -> String? {
        ExecutableHeuristics.bestGuessExecutable(inFolder: folder, maxDepth: 5)
    }
}
