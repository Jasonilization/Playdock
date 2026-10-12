import Foundation

/// Persists Game Mode's engine/graphics settings across launches - one global default plus
/// per-game overrides keyed by Steam appID, so different games (which often need different Wine
/// settings) don't have to share a single configuration.
enum GameSettingsStore {
    private static let key = "com.exedock.gameSettings"

    private struct Payload: Codable {
        var defaults: GameModeConfig
        var perGame: [String: GameModeConfig]
    }

    static func load() -> (defaults: GameModeConfig, perGame: [String: GameModeConfig]) {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return (GameModeConfig(), [:])
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // If a future schema change ever makes old data undecodable, the user's settings
            // visibly reset - this line is the breadcrumb that explains why in diagnostics.log
            // instead of it looking like Playdock just decided to forget them.
            DiagnosticsLog.log("GameSettingsStore: saved settings failed to decode - starting from defaults")
            return (GameModeConfig(), [:])
        }
        return (payload.defaults, payload.perGame)
    }

    static func save(defaults: GameModeConfig, perGame: [String: GameModeConfig]) {
        let payload = Payload(defaults: defaults, perGame: perGame)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
