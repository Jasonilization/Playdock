import Foundation

/// Scans a bottle's `Program Files` folders for installed Windows programs.
enum CDriveScanner {
    private static let ignoredFolderNames: Set<String> = [
        "common files", "windows nt", "internet explorer", "windows media player",
        "installshield installation information", "windowsapps", "windows defender",
        "windows mail", "windows photo viewer", "windows portable devices",
        "windows sidebar", "microsoft.net", "reference assemblies",
    ]

    static func scan(_ bottle: Bottle) -> [DetectedApp] {
        let fm = FileManager.default
        var results: [DetectedApp] = []
        for programFilesDir in ["Program Files", "Program Files (x86)"] {
            let root = (bottle.driveCPath as NSString).appendingPathComponent(programFilesDir)
            guard let vendorFolders = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for vendor in vendorFolders {
                guard !ignoredFolderNames.contains(vendor.lowercased()) else { continue }
                let vendorPath = (root as NSString).appendingPathComponent(vendor)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: vendorPath, isDirectory: &isDir), isDir.boolValue else { continue }
                if let mainExe = mainExecutable(inFolder: vendorPath, folderName: vendor) {
                    results.append(DetectedApp(displayName: vendor, exePath: mainExe, bottle: bottle))
                }
            }
        }
        return results.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Every bottle ExeDock knows about: its own bottles plus any read-only discovered Sikarugir
    /// wrapper bottles.
    static func allKnownBottles() -> [Bottle] {
        let names = Dictionary(uniqueKeysWithValues: CustomGameStore.loadAll().map { ($0.id, $0.effectiveName) })
        return [BottleManager.shared.defaultBottle, BottleManager.shared.steamBottle]
            + BottleManager.shared.ownedGameBottles(names: names)
            + BottleManager.shared.discoverSikarugirWrapperBottles()
    }

    /// Prefers an exe whose name matches the folder name, else falls back to the largest exe -
    /// delegates to `ExecutableHeuristics`, shared with `SteamLibrary`'s own icon-exe lookup and
    /// `CustomGameFolderScanner`.
    private static func mainExecutable(inFolder folder: String, folderName: String) -> String? {
        ExecutableHeuristics.bestGuessExecutable(inFolder: folder, preferredName: folderName, maxDepth: 3)
    }
}
