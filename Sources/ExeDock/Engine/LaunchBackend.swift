import Foundation

/// How Playdock starts a Steam game. Steam Play is NotProton: Mac Steam downloads and runs the
/// Windows title on this Mac. Playdock Wine is the Sikarugir bottle. Native is a Mac build.
enum LaunchBackend: String, CaseIterable, Identifiable, Codable {
    case playdockWine
    case steamPlay
    case nativeMac

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playdockWine: return "Playdock Wine"
        case .steamPlay: return "Steam Play"
        case .nativeMac: return "Native macOS"
        }
    }

    var summary: String {
        switch self {
        case .playdockWine: return "Windows Steam inside Playdock's bottle."
        case .steamPlay: return "NotProton. Mac Steam downloads and runs the Windows game on this Mac."
        case .nativeMac: return "The Mac Steam app, for a Mac build."
        }
    }
}

enum LaunchBackendStore {
    private static let key = "com.exedock.launchBackends"

    static func backend(for game: SteamGame) -> LaunchBackend {
        let stored = load()[game.metadataAppID]
        if let stored, LaunchBackend(rawValue: stored) != nil {
            return LaunchBackend(rawValue: stored)!
        }
        return game.source == .nativeMac ? .nativeMac : .playdockWine
    }

    static func set(_ backend: LaunchBackend, for game: SteamGame) {
        var map = load()
        map[game.metadataAppID] = backend.rawValue
        UserDefaults.standard.set(map, forKey: key)
    }

    static func available(for game: SteamGame) -> [LaunchBackend] {
        var list: [LaunchBackend] = [.steamPlay]
        if game.source == .wineBottle { list.insert(.playdockWine, at: 0) }
        if game.source == .nativeMac || SteamPlaySupport.nativeSteamAppExists {
            list.append(.nativeMac)
        }
        if game.source == .nativeMac, !list.contains(.playdockWine), SteamPlaySupport.windowsExecutable(for: game) != nil {
            list.insert(.playdockWine, at: 0)
        }
        return list
    }

    private static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
