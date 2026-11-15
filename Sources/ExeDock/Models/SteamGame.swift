import Foundation

/// Where a `SteamGame` was actually found and how it launches. The vast majority (`wineBottle`) are
/// installed through ExeDock's own Windows Steam client, running inside its Sikarugir bottle, and
/// launch through that same Windows Steam via `-applaunch`. `nativeMac` is a game found in the
/// *real*, separately-installed macOS Steam client's own library - a completely different Steam
/// install, not something ExeDock manages - and launches by asking that real Steam app to run it
/// directly instead: "make sure I can see my mac steam games and launch it here too, same way," per
/// live feedback.
enum SteamGameSource: Equatable, Hashable {
    case wineBottle
    case nativeMac
}

/// A game ExeDock found installed in a Steam library - either its own Windows Steam bottle, or the
/// real, separate macOS Steam client (see `SteamGameSource`).
struct SteamGame: Identifiable, Hashable {
    let appID: String
    let name: String
    let installDir: String
    /// The game's actual install folder, as found at scan time - not reconstructed later from a
    /// single assumed root, since a native macOS Steam library can have more than one library
    /// folder (an external drive, say), unlike ExeDock's own single managed Windows Steam bottle.
    let installFolderPath: String
    /// Best-effort path to an executable inside the game's install folder, used only to look up a
    /// recognizable icon for a `wineBottle` game. ExeDock never runs this directly - games are
    /// always launched through Steam itself (`-applaunch`), since only Steam knows a game's real
    /// launch arguments and prerequisites, and some titles (anti-cheat games especially) require
    /// launching that way. Always `nil` for a `nativeMac` game - real Steam header art already
    /// covers its card/detail-view artwork the same way it does for everything else.
    let iconExePath: String?
    /// Bytes on disk, from the manifest's `SizeOnDisk` - shown on the game's card.
    let sizeOnDisk: Int64?
    /// Steam's own internal build number for the installed copy, from the manifest's `buildid` -
    /// the closest thing to a "version" Steam tracks locally.
    let buildID: String?
    /// Unix timestamp of the last update, from the manifest's `LastUpdated`.
    let lastUpdated: Date?
    var source: SteamGameSource = .wineBottle
    /// The manifest exists and the install folder is there, but Steam has not set the
    /// fully-installed bit yet. Shown in the library, not launched.
    var isDownloading: Bool = false

    var id: String { appID }

    /// The real numeric Steam appID to use for public store metadata lookups. Equal to `appID` for
    /// every real, installed game; only differs for entries whose `appID` is namespaced with a
    /// prefix so it can never collide with a same-appid entry from a different source in the same
    /// `ForEach` (a `ForEach` with two same-`id` elements is genuinely broken in SwiftUI, not just
    /// cosmetically wrong) - `SAMPLE-` for the debug-only sample-games preview
    /// (`AppModel.togglePreviewSampleGames`), `MAC-` for a `nativeMac` game. Metadata lookups still
    /// want the real, unprefixed id underneath.
    var metadataAppID: String {
        for prefix in ["SAMPLE-", "MAC-"] where appID.hasPrefix(prefix) {
            return String(appID.dropFirst(prefix.count))
        }
        return appID
    }

    /// Debug layout-preview cards from `AppModel.togglePreviewSampleGames`. They reuse real
    /// store appIDs for art, but they are not installed in the Steam bottle.
    var isPreviewSample: Bool { appID.hasPrefix("SAMPLE-") }

    /// Arguments appended to `Steam.exe` for a Windows-Steam library title (`-applaunch` plus
    /// the real numeric appID). Nil for native Mac games and layout-preview cards — those must
    /// never be sent through the bottle's Steam.exe.
    var wineSteamLaunchArguments: [String]? {
        guard source == .wineBottle, !isPreviewSample else { return nil }
        return ["-applaunch", metadataAppID]
    }
}
