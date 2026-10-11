import Foundation

/// Public store metadata for a game - description, artwork, screenshots, genres, release date, and
/// rating - used to make a game's card (and the richer Game Detail view) feel like part of a real
/// Steam dashboard instead of a bare file-launcher row. All of it comes from the one `appdetails`
/// call `SteamStoreInfoCache` already makes - no extra network round trip for the extra fields.
struct SteamStoreInfo: Codable, Equatable {
    /// Bumped whenever a new wave of fields is added - `SteamStoreInfoCache` re-fetches instead of
    /// trusting a cache entry written by an older version of this struct forever. Cleaner than
    /// guessing "is this incomplete?" from which fields happen to be empty (a genuinely sparse but
    /// fully-fetched entry - an obscure app with no Metacritic score, say - would otherwise look
    /// permanently stale under that heuristic).
    static let currentSchemaVersion = 3

    let shortDescription: String?
    /// The full "About This Game" text, HTML tags stripped down to plain text (with paragraph
    /// breaks preserved) - meant for the Game Detail view; `shortDescription` above stays the
    /// short blurb already used on cards.
    var aboutTheGame: String?
    /// Path to a locally cached copy of the header image, if one downloaded successfully.
    let headerImagePath: String?
    /// Path to a locally cached copy of the wide background/hero art, if one downloaded
    /// successfully - meant for a full-screen detail view backdrop, not the small grid card.
    var backgroundImagePath: String?
    /// Locally cached thumbnail screenshots (a handful, not the whole gallery) for the Game Detail
    /// view's screenshot strip.
    var screenshotPaths: [String] = []
    var genres: [String] = []
    var releaseDate: String?
    var developers: [String] = []
    var publishers: [String] = []
    var metacriticScore: Int?
    var metacriticURL: String?
    var categories: [String] = []
    var screenshotFullImageURLs: [String] = []
    var schemaVersion: Int = Self.currentSchemaVersion

    init(shortDescription: String?, aboutTheGame: String? = nil, headerImagePath: String?, backgroundImagePath: String? = nil,
         screenshotPaths: [String] = [], genres: [String] = [], releaseDate: String? = nil, developers: [String] = [],
         publishers: [String] = [], metacriticScore: Int? = nil, metacriticURL: String? = nil, categories: [String] = [],
         screenshotFullImageURLs: [String] = []) {
        self.shortDescription = shortDescription
        self.aboutTheGame = aboutTheGame
        self.headerImagePath = headerImagePath
        self.backgroundImagePath = backgroundImagePath
        self.screenshotPaths = screenshotPaths
        self.genres = genres
        self.releaseDate = releaseDate
        self.developers = developers
        self.publishers = publishers
        self.metacriticScore = metacriticScore
        self.metacriticURL = metacriticURL
        self.categories = categories
        /// Parallel to `screenshotPaths`: the full-resolution source URL each cached thumbnail
        /// came from, so the lightbox can lazy-load the real image on demand instead of pinning
        /// 6 full-size shots per game on disk for everyone.
        self.screenshotFullImageURLs = screenshotFullImageURLs
        self.schemaVersion = Self.currentSchemaVersion
    }

    /// True for a cache entry written by an older version of this struct - lets
    /// `SteamStoreInfoCache` re-fetch instead of trusting it forever.
    var isStale: Bool {
        schemaVersion < Self.currentSchemaVersion
    }

    /// Decodes leniently so cache files written before a field existed still load fine (with that
    /// field empty) rather than failing to decode entirely - `schemaVersion` defaults to `0` for
    /// any file old enough not to have one at all, which `isStale` then catches.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortDescription = try container.decodeIfPresent(String.self, forKey: .shortDescription)
        aboutTheGame = try container.decodeIfPresent(String.self, forKey: .aboutTheGame)
        headerImagePath = try container.decodeIfPresent(String.self, forKey: .headerImagePath)
        backgroundImagePath = try container.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        screenshotPaths = try container.decodeIfPresent([String].self, forKey: .screenshotPaths) ?? []
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        developers = try container.decodeIfPresent([String].self, forKey: .developers) ?? []
        publishers = try container.decodeIfPresent([String].self, forKey: .publishers) ?? []
        metacriticScore = try container.decodeIfPresent(Int.self, forKey: .metacriticScore)
        metacriticURL = try container.decodeIfPresent(String.self, forKey: .metacriticURL)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        screenshotFullImageURLs = try container.decodeIfPresent([String].self, forKey: .screenshotFullImageURLs) ?? []
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    }

    /// Explicit so the synthesized *encoder* covers every field (the custom decoder reads
    /// leniently; without this list, `screenshotFullImageURLs` would silently never be saved).
    private enum CodingKeys: String, CodingKey {
        case shortDescription, aboutTheGame, headerImagePath, backgroundImagePath
        case screenshotPaths, screenshotFullImageURLs
        case genres, categories, releaseDate, developers, publishers
        case metacriticScore, metacriticURL, schemaVersion
    }

    /// Turns Steam's own HTML-formatted "about the game" copy into plain text: `<br>` becomes a
    /// line break, every other tag is dropped, and the handful of entities Steam's own copy
    /// actually uses get decoded. Not a general HTML parser (nothing here needs one) - just enough
    /// to make Steam's real descriptions readable in a plain `Text` view.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse 3+ blank lines down to a single paragraph break - Steam's own copy sometimes
        // has runs of empty <br> tags for visual spacing that a SwiftUI Text doesn't need.
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
