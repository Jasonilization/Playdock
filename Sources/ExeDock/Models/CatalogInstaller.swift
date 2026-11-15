import Foundation

/// One Windows setup Playdock knows how to download. The URLs are the vendors' own installers.
/// Each one gets a Windows 10 bottle of its own. Steam is handled by `SteamInstaller` because
/// its silent setup is a special case; every other row opens the vendor's setup window.
struct CatalogInstaller: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let downloadURL: URL
    let pageURL: URL
    /// Saved file name inside the bottle. The extension decides how Wine opens it.
    let fileName: String
    /// Paths under drive_c. The first one that exists is the installed program.
    let installedRelativePaths: [String]
    /// Steam uses the proven silent installer. Everything else opens the setup window.
    let isSteam: Bool

    /// How sure Playdock is that this setup finishes. Steam's silent install is the one that
    /// has been checked. The others open the vendor's window, and that client may not finish.
    var ratingStars: Int { isSteam ? 4 : 2 }
    var ratingLabel: String { isSteam ? "Install path checked" : "Not checked yet" }

    var bottleID: String { "catalog-\(id)" }

    func bottle(named displayName: String) -> Bottle {
        if isSteam { return BottleManager.shared.steamBottle }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return BottleManager.shared.gameBottle(id: bottleID, name: trimmed.isEmpty ? name : trimmed)
    }

    func installedExePath() -> String? {
        if isSteam {
            return SteamInstaller.isSteamInstalled ? SteamInstaller.installedSteamExePath : nil
        }
        let root = bottle(named: name).driveCPath
        for relative in installedRelativePaths {
            let path = (root as NSString).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static let all: [CatalogInstaller] = [
        CatalogInstaller(
            id: "steam",
            name: "Steam",
            summary: "Valve's client for buying, downloading, and playing Windows games. You sign in inside Steam.",
            downloadURL: SteamInstaller.steamSetupURL,
            pageURL: URL(string: "https://store.steampowered.com/about/")!,
            fileName: "SteamSetup.exe",
            installedRelativePaths: [],
            isSteam: true
        ),
        CatalogInstaller(
            id: "epic",
            name: "Epic Games Store",
            summary: "Epic's store client. Playdock downloads Epic's installer and opens it in a bottle named Epic Games Store.",
            downloadURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
            pageURL: URL(string: "https://store.epicgames.com/download")!,
            fileName: "EpicGamesLauncherInstaller.msi",
            installedRelativePaths: [
                "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win32/EpicGamesLauncher.exe",
                "Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "battlenet",
            name: "Battle.net",
            summary: "Blizzard's client for Diablo, Overwatch, World of Warcraft, and the rest of Battle.net.",
            downloadURL: URL(string: "https://us.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!,
            pageURL: URL(string: "https://www.battle.net/download")!,
            fileName: "Battle.net-Setup.exe",
            installedRelativePaths: [
                "Program Files (x86)/Battle.net/Battle.net.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "gog",
            name: "GOG Galaxy",
            summary: "GOG's client for downloading and updating games you own on GOG.",
            downloadURL: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
            pageURL: URL(string: "https://www.gog.com/galaxy")!,
            fileName: "GOG_Galaxy_2.0.exe",
            installedRelativePaths: [
                "Program Files (x86)/GOG Galaxy/GalaxyClient.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "ubisoft",
            name: "Ubisoft Connect",
            summary: "Ubisoft's client. Games you own there install from inside this window.",
            downloadURL: URL(string: "https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
            pageURL: URL(string: "https://www.ubisoft.com/en-us/ubisoft-connect")!,
            fileName: "UbisoftConnectInstaller.exe",
            installedRelativePaths: [
                "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe",
                "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/upc.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "ea",
            name: "EA App",
            summary: "Electronic Arts' PC client, the one that replaced Origin.",
            downloadURL: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EADesktopInstaller.exe")!,
            pageURL: URL(string: "https://www.ea.com/ea-app")!,
            fileName: "EADesktopInstaller.exe",
            installedRelativePaths: [
                "Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "rockstar",
            name: "Rockstar Games Launcher",
            summary: "Rockstar's client for the games in your Rockstar library.",
            downloadURL: URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!,
            pageURL: URL(string: "https://www.rockstargames.com/launcher")!,
            fileName: "Rockstar-Games-Launcher.exe",
            installedRelativePaths: [
                "Program Files/Rockstar Games/Launcher/Launcher.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "itch",
            name: "itch",
            summary: "The itch app for games you bought or downloaded on itch.io.",
            downloadURL: URL(string: "https://itch.io/app/download?platform=windows")!,
            pageURL: URL(string: "https://itch.io/app")!,
            fileName: "itch-setup.exe",
            installedRelativePaths: [],
            isSteam: false
        ),
        CatalogInstaller(
            id: "amazon",
            name: "Amazon Games",
            summary: "Amazon's PC games client.",
            downloadURL: URL(string: "https://download.amazongames.com/AmazonGamesSetup.exe")!,
            pageURL: URL(string: "https://gaming.amazon.com/home")!,
            fileName: "AmazonGamesSetup.exe",
            installedRelativePaths: [
                "Program Files/Amazon Games/Launcher/Amazon Games.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "riot",
            name: "Riot Client",
            summary: "Riot's client for League of Legends, VALORANT, and Teamfight Tactics.",
            downloadURL: URL(string: "https://lol.secure.dyn.riotcdn.net/channels/public/x/installer/current/live.live.na.exe")!,
            pageURL: URL(string: "https://www.leagueoflegends.com/en-us/download/")!,
            fileName: "RiotClientInstaller.exe",
            installedRelativePaths: [
                "Program Files/Riot Games/Riot Client/RiotClientServices.exe",
            ],
            isSteam: false
        ),
        CatalogInstaller(
            id: "discord",
            name: "Discord",
            summary: "The Windows Discord app, for voice chat while a game is running.",
            downloadURL: URL(string: "https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=x86")!,
            pageURL: URL(string: "https://discord.com/download")!,
            fileName: "DiscordSetup.exe",
            installedRelativePaths: [],
            isSteam: false
        ),
    ]
}
