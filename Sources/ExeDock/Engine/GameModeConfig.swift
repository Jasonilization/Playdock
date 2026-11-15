import Foundation

/// The same Wine/engine toggles already present in the user's existing Sikarugir wrapper apps
/// (confirmed by inspecting Pragmata.app / Steam.app's Info.plist), surfaced for the Steam/game
/// bottle. These aren't new invented settings - they mirror what Sikarugir already exposes.
struct GameModeConfig: Equatable, Codable, Hashable {
    /// The stack that starts the most titles on this Mac: Apple's D3DMetal, MoltenVK, and
    /// fast sync. DXVK stays off because it fights D3DMetal when both are set.
    static var maximumCompatibility: GameModeConfig {
        var config = GameModeConfig()
        config.d3dMetal = true
        config.dxvk = false
        config.dxmt = false
        config.moltenVKCX = true
        config.fastSync = true
        return config
    }

    var d3dMetal = true
    var dxvk = false
    var dxmt = false
    var moltenVKCX = true
    var wineESync = true
    var wineMSync = true
    var engineName: String? = SikarugirEngine.recommendedEngineName()

    /// ESYNC and MSYNC are two different sync-primitive backends, but nobody's ever asked to toggle
    /// them independently - "only have 5 toggles" collapses them into one "Fast Sync" switch in the
    /// UI while keeping both fields (and both env vars) underneath, so nothing about a saved config
    /// or `environment` changes shape.
    var fastSync: Bool {
        get { wineESync && wineMSync }
        set { wineESync = newValue; wineMSync = newValue }
    }

    var environment: [String: String] {
        [
            "D3DMETAL": d3dMetal ? "1" : "0",
            "DXVK": dxvk ? "1" : "0",
            "DXMT": dxmt ? "1" : "0",
            "MOLTENVKCX": moltenVKCX ? "1" : "0",
            "WINEESYNC": wineESync ? "1" : "0",
            "WINEMSYNC": wineMSync ? "1" : "0",
        ]
    }
}
