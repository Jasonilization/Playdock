import Foundation

/// Everything auto-discovered for a custom game - local PE resource fields (always available, no
/// network) plus, if a confident public match was found, real Steam catalog data. Kept separate
/// from `CustomGameOverrides` so re-running discovery never clobbers something the user typed in by
/// hand, and so overrides can be cleared back to "whatever was discovered" cleanly.
struct DiscoveredMetadata: Codable, Equatable {
    var productName: String?
    var fileDescription: String?
    var publisher: String?
    var fileVersion: String?
    var steamArtworkPath: String?
    var steamDescription: String?
    // Everything below only ever gets filled in alongside a confident Steam match - the same
    // richer fields a real Steam game's own card/detail view already shows, pulled from the exact
    // same appdetails call that already provides the two fields above, so this costs nothing extra.
    var steamAboutTheGame: String?
    var steamBackgroundPath: String?
    var steamScreenshotPaths: [String] = []
    var steamGenres: [String] = []
    var steamReleaseDate: String?
    var steamDevelopers: [String] = []
    var steamPublishers: [String] = []
    var steamCategories: [String] = []
    var steamMetacriticScore: Int?
    var steamMetacriticURL: String?
}

/// User edits from "Edit Game" - every field `nil` means "use whatever was discovered instead."
struct CustomGameOverrides: Codable, Equatable {
    var name: String?
    var description: String?
    var artworkPath: String?
    var launchArguments: [String]?
}

/// A manually-imported game - a reference to an executable that already exists somewhere on disk
/// (never copied into Playdock's own storage) plus whatever metadata was discovered or edited for
/// it. See `CustomGameStore` for persistence.
struct CustomGame: Codable, Identifiable, Equatable {
    let id: String
    var exePath: String
    var addedAt: Date
    var discovered: DiscoveredMetadata
    var overrides: CustomGameOverrides
    /// When set, this game has its own bottle under `Bottles/Games/<bottleID>`. Older library
    /// entries leave this nil and keep launching from whichever prefix already contains the exe.
    var bottleID: String?

    init(
        id: String = UUID().uuidString,
        exePath: String,
        addedAt: Date = Date(),
        discovered: DiscoveredMetadata = DiscoveredMetadata(),
        overrides: CustomGameOverrides = CustomGameOverrides(),
        bottleID: String? = nil
    ) {
        self.id = id
        self.exePath = exePath
        self.addedAt = addedAt
        self.discovered = discovered
        self.overrides = overrides
        self.bottleID = bottleID
    }

    var effectiveName: String {
        overrides.name ?? discovered.productName ?? Self.cleanedName(fromExePath: exePath)
    }

    var effectiveDescription: String? {
        let text = overrides.description ?? discovered.steamDescription ?? discovered.fileDescription
        return (text?.isEmpty == false) ? text : nil
    }

    var effectiveArtworkPath: String? {
        overrides.artworkPath ?? discovered.steamArtworkPath
    }

    /// The full "About This Game" text when a confident Steam match found one, falling back to
    /// whatever `effectiveDescription` already resolves to (the short blurb, or the exe's own
    /// FileDescription) for anything without one.
    var effectiveAboutTheGame: String? {
        let text = overrides.description ?? discovered.steamAboutTheGame ?? effectiveDescription
        return (text?.isEmpty == false) ? text : nil
    }

    var launchArguments: [String] {
        overrides.launchArguments ?? []
    }

    /// "HollowKnight.exe" -> "Hollow Knight" - splits camelCase/PascalCase and underscores/dashes
    /// into words. Used both as the last-resort display name (nothing better discovered) and as the
    /// public-lookup search candidate when there's no PE product name or folder name to try first.
    static func cleanedName(fromExePath path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var result = ""
        var previousWasLower = false
        for character in stem {
            if character == "_" || character == "-" {
                result.append(" ")
                previousWasLower = false
                continue
            }
            if character.isUppercase && previousWasLower {
                result.append(" ")
            }
            result.append(character)
            previousWasLower = character.isLowercase
        }
        return result.split(separator: " ").joined(separator: " ")
    }
}
