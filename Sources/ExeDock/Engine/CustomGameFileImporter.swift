import Foundation

/// Moves a freshly-picked (or already-imported) custom game's files into that game's own
/// bottle. Each game gets a fresh prefix (`Bottles/Games/<id>`), so two games never share a
/// C: drive, a registry, or a save folder. The bottle is wineboot'd on first launch, not here.
enum CustomGameFileImporter {
    enum ImportError: Error, LocalizedError {
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .moveFailed(let detail): return "Couldn't move the game into Playdock: \(detail)"
            }
        }
    }

    /// Moves the game into `bottle` and returns its new exe path. `pickedFolderPath` is the
    /// folder the user explicitly chose (via "Choose Folder…," or a dropped folder) if there
    /// was one - that whole folder is moved as a unit. For a lone exe (no folder explicitly chosen),
    /// this moves the exe's own containing folder instead (it very often has sibling DLLs/assets it
    /// needs), *unless* that folder is broad enough that moving it wholesale would relocate unrelated
    /// files (the user's home directory, Desktop, Downloads, a volume root, …) - in that one case,
    /// only the exe file itself is moved. Files land in `drive_c/Game`, one game per bottle.
    static func importIntoGameBottle(exePath: String, pickedFolderPath: String?, bottle: Bottle) throws -> String {
        let fm = FileManager.default
        let customGamesRoot = (bottle.driveCPath as NSString).appendingPathComponent("Game")
        try fm.createDirectory(atPath: customGamesRoot, withIntermediateDirectories: true)

        let sourceFolder = pickedFolderPath ?? safeContainingFolder(forExePath: exePath)

        if let sourceFolder, exePath.hasPrefix(sourceFolder) {
            let destinationName = uniqueDestinationName(for: (sourceFolder as NSString).lastPathComponent, in: customGamesRoot)
            let destinationFolder = (customGamesRoot as NSString).appendingPathComponent(destinationName)
            do {
                try moveOrCopyItem(from: sourceFolder, to: destinationFolder)
            } catch {
                throw ImportError.moveFailed(error.localizedDescription)
            }
            let relativeExePath = String(exePath.dropFirst(sourceFolder.count))
            return destinationFolder + relativeExePath
        }

        // Either the containing folder was judged unsafe to move wholesale, or (defensively) it
        // somehow isn't actually a prefix of the exe path - move just the exe file itself.
        let exeName = (exePath as NSString).lastPathComponent
        let destinationName = uniqueDestinationName(for: (exeName as NSString).deletingPathExtension, in: customGamesRoot)
        let destinationFolder = (customGamesRoot as NSString).appendingPathComponent(destinationName)
        do {
            try fm.createDirectory(atPath: destinationFolder, withIntermediateDirectories: true)
            let destinationExePath = (destinationFolder as NSString).appendingPathComponent(exeName)
            try moveOrCopyItem(from: exePath, to: destinationExePath)
            return destinationExePath
        } catch {
            throw ImportError.moveFailed(error.localizedDescription)
        }
    }

    /// Same-volume picks rename in place; cross-volume picks can't `moveItem`, so copy instead and
    /// leave the original where the user put it.
    /// `moveItem` already copies across volumes. Only fall back to a copy when the move failed
    /// without consuming the source or creating the destination — otherwise a permission or
    /// "already exists" error gets replaced by a second, less useful one.
    private static func moveOrCopyItem(from source: String, to destination: String) throws {
        let fm = FileManager.default
        do {
            try fm.moveItem(atPath: source, toPath: destination)
        } catch let moveError {
            guard fm.fileExists(atPath: source), !fm.fileExists(atPath: destination) else {
                throw ImportError.moveFailed(moveError.localizedDescription)
            }
            do {
                try fm.copyItem(atPath: source, toPath: destination)
            } catch {
                throw ImportError.moveFailed(moveError.localizedDescription)
            }
        }
    }

    /// True once a game's exe already lives inside the bottle Playdock created for it.
    static func isInGameBottle(exePath: String, bottleID: String?) -> Bool {
        guard let bottleID else { return false }
        let bottle = BottleManager.shared.gameBottle(id: bottleID, name: "")
        return exePath.hasPrefix(bottle.driveCPath)
    }

    /// The exe's own containing folder, unless that folder is broad enough that moving it wholesale
    /// would relocate unrelated files sitting alongside it for unrelated reasons.
    private static func safeContainingFolder(forExePath exePath: String) -> String? {
        let folder = (exePath as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        let unsafe: Set<String> = [
            home,
            (home as NSString).appendingPathComponent("Desktop"),
            (home as NSString).appendingPathComponent("Downloads"),
            (home as NSString).appendingPathComponent("Documents"),
            "/", "/Users", "/Applications", "/Volumes",
        ]
        if unsafe.contains(folder) { return nil }
        // A volume root under /Volumes, e.g. "/Volumes/MyDrive" - two path components deep.
        if folder.hasPrefix("/Volumes/"), folder.split(separator: "/").count <= 2 { return nil }
        return folder
    }

    private static func uniqueDestinationName(for baseName: String, in root: String) -> String {
        let fm = FileManager.default
        let sanitized = baseName.isEmpty ? "Game" : baseName
        var candidate = sanitized
        var suffix = 2
        while fm.fileExists(atPath: (root as NSString).appendingPathComponent(candidate)) {
            candidate = "\(sanitized) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}
