import SwiftUI

/// A chunky, full-width button - bigger than SwiftUI's `.large` control size caps out at, for the
/// handful of actions that should dominate the screen (Launch, Install & Run Steam, Controller
/// Mode's "[ SELECT ]"). Renders through the exact same real, per-skin `playdockButtonLook()`
/// recipe `PlaydockButtonStyle` uses everywhere else - the single most-seen button in the whole
/// app (Launch, front and center in the Game Detail view) was still a generic accent-filled
/// rounded rect while every other button had already been ported from the real mockups. Only the
/// sizing is different now, not the visual language.
struct BigButtonStyle: ButtonStyle {
    var prominent: Bool = true
    /// See `CardSurface.accentOverride` - identical contract.
    var accentOverride: Color?
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    func makeBody(configuration: Configuration) -> some View {
        PlaydockButtonBody(
            configuration: configuration,
            look: playdockButtonLook(skin: skin, prominent: prominent, isPressed: configuration.isPressed, accentOverride: accentOverride),
            skin: skin,
            font: .title3.weight(.semibold),
            horizontalPadding: 28,
            verticalPadding: 14
        )
    }
}

extension ButtonStyle where Self == BigButtonStyle {
    static var big: BigButtonStyle { BigButtonStyle() }
    static func big(prominent: Bool) -> BigButtonStyle { BigButtonStyle(prominent: prominent) }
    static func big(accentOverride: Color?) -> BigButtonStyle { BigButtonStyle(accentOverride: accentOverride) }
}
