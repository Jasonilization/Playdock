import SwiftUI

/// Shared visual language for Playdock's dashboard - a small, consistent set of tokens plus a
/// reusable "floating card" treatment, so cards/panels read as one deliberate design instead of
/// independently-tuned one-offs. Built around a real surface scale (each layer reads as sitting
/// *on top of* the one below it, via material + border + shadow) - the same layering approach
/// well-regarded library/dashboard apps (Steam's own library, GOG Galaxy 2.0) use to make a dense
/// grid of cards read as separate, touchable objects rather than a flat wall of boxes.
enum Playdock {
    enum Radius {
        static let card: CGFloat = 20
        static let control: CGFloat = 12
        static let pill: CGFloat = 999
    }

    enum Spacing {
        /// Gap between cards in the library grid - wider than a typical control-spacing value on
        /// purpose, so the grid reads as a set of distinct objects with real room to breathe
        /// instead of tiles packed edge to edge.
        static let grid: CGFloat = 24
    }
}

/// The library's "look" - an independent axis from `LibraryLayoutStyle` (its *structure*), so any
/// layout can be paired with any skin. Each skin is a small set of real, native tokens (accent
/// color, corner radius, and a system `Font.Design` - `.rounded`/`.serif`/`.monospaced` are real,
/// built-in SwiftUI font variants, not custom typefaces that would need bundling) rather than 10
/// hand-painted screens, so a skin applies uniformly no matter which layout it's paired with.
/// Persisted via `@AppStorage` the same way `isAdvancedMode`/`uiScale` already are elsewhere in
/// this app.
enum PlaydockSkin: String, CaseIterable, Identifiable {
    case luxury, brutalist, cyber, soft, pixel, minimal
    var id: String { rawValue }

    static let storageKey = "com.exedock.librarySkin"

    /// Plain, grounded names, deliberately dropping the trendy prefixes/suffixes ("Neo-",
    /// "Terminal", "Arcade", "Unit", "UI") that read as trying too hard, while keeping each skin's
    /// own real identity.
    var displayName: String {
        switch self {
        case .luxury: return "Luxury"
        case .brutalist: return "Brutalist"
        case .cyber: return "Terminal"
        case .soft: return "Soft"
        case .pixel: return "Pixel"
        case .minimal: return "Minimal"
        }
    }

    /// One plain line describing the look, for the setup wizard's picker - describes what's
    /// actually different (materials, shapes, mood) rather than reaching for marketing language.
    var blurb: String {
        switch self {
        case .luxury: return "Warm, understated, gold accents"
        case .brutalist: return "Bold blocks, hard offset shadows"
        case .cyber: return "Dark, cut corners, neon accents"
        case .soft: return "Rounded, gentle depth"
        case .pixel: return "Retro, dotted grid, blocky"
        case .minimal: return "Plain, quiet, no decoration"
        }
    }

    /// This skin's own real `.cta`/`.launch` button text, ported straight from skins.js's card
    /// markup - Grid's real cards each carry a visible per-skin action button, not a generic
    /// "Details" label, so every native layout's own card/hero button reads the same real word
    /// Grid's does instead of one word painted over every skin alike.
    var ctaLabel: String {
        switch self {
        case .luxury: return "View Details"
        case .brutalist: return "Launch →"
        case .cyber: return "LAUNCH ▸"
        case .soft: return "Launch"
        case .pixel: return "START ▶"
        case .minimal: return "Launch →"
        }
    }

    /// A color that resolves to `light` or `dark` itself, live, per the *current* effective
    /// appearance - not a value fixed at whatever mode happened to be active when it was read.
    /// Only Cyber and Pixel's own real `--accent`/`--accent2` in skins.css actually change value
    /// between `[data-stage-theme="light"]` and the dark default (every other skin's accent stays
    /// the same literal in both blocks), checked directly against the real CSS rather than
    /// assumed. Built as one dynamic `NSColor` so every existing call site (cards, tiles, buttons,
    /// title text)
    /// gets this correctly for free, with no signature changes anywhere.
    private static func dynamicAccent(light: (r: Double, g: Double, b: Double), dark: (r: Double, g: Double, b: Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    var accent: Color {
        switch self {
        case .luxury: return Color(red: 0.69, green: 0.55, blue: 0.34)
        // Was #ff4d6d - a shrill cotton-candy pink that vibrated against both the cream and the
        // near-black Brutalist grounds, and clashed head-on with the old #3a86ff search bar.
        // Brutalism on the web is ink + paper + one loud signal color: a controlled vermilion red
        // (#da2e22), a touch brighter in dark mode (#f2483b) so it doesn't sink into the charcoal.
        case .brutalist: return Self.dynamicAccent(light: (0.855, 0.180, 0.133), dark: (0.949, 0.282, 0.231))
        // --accent:#00f0ff (dark) / #0092a3 (light) - a bright neon cyan reads fine glowing in
        // the dark but washes out on white, so the real light-mode CSS commits to a deeper teal.
        case .cyber: return Self.dynamicAccent(light: (0.0, 0.573, 0.639), dark: (0.0, 0.94, 1.0))
        case .soft: return Color(red: 0.42, green: 0.45, blue: 1.0)
        // --accent:#f6cf7a (dark) / #c97a1e (light) - same real reasoning as Cyber's.
        case .pixel: return Self.dynamicAccent(light: (0.788, 0.478, 0.118), dark: (0.96, 0.81, 0.48))
        case .minimal: return Color(red: 0.04, green: 0.37, blue: 1.0)
        }
    }

    /// The mockups' own `--accent2` - a real, distinct second color a handful of skins define
    /// alongside their main accent (Pixel's own launch button is genuinely this color, not
    /// `accent` - the two read close but aren't the same swatch). Skins with no second color of
    /// their own just repeat `accent`, so every call site can use this unconditionally.
    var accent2: Color {
        switch self {
        // Brutalist's old second color was #3a86ff electric blue - only ever used for the Grid
        // WebView's full-bleed search bar (skins.css), and the single worst offender in "the
        // colour scheme looks very bad": a hot-blue slab next to a hot-pink accent on cream. Gone
        // now - Brutalist collapses to its single red accent here, and the CSS search bar is an
        // ink block instead (see .brut in skins.css).
        case .cyber: return Self.dynamicAccent(light: (0.761, 0.090, 0.439), dark: (1.0, 0.18, 0.53)) // #ff2e88 / #c21770
        case .pixel: return Self.dynamicAccent(light: (0.851, 0.314, 0.184), dark: (0.937, 0.490, 0.341)) // #ef7d57 / #d9502f
        default: return accent
        }
    }

    /// This skin's real `.topbar` background from skins.css - "top bar will be the same look...
    /// every aspect of the app should be the appearance," per live feedback: the sticky header
    /// strip above the dashboard (and C: Drive's own header row) stayed on native window chrome
    /// regardless of skin until now. Ported directly from each skin's own real CSS rule, not an
    /// approximation - Pixel's real `.topbar` uses its own `--panel` token, a genuinely different
    /// color from the page's own `--bg`, not a mistake carried over from the other five.
    var topBarBackground: Color {
        switch self {
        case .luxury: return Self.dynamicAccent(light: (0.965, 0.961, 0.953), dark: (0.082, 0.078, 0.071)) // #f6f5f3 / #151412
        case .brutalist: return Self.dynamicAccent(light: (0.996, 0.965, 0.894), dark: (0.106, 0.090, 0.071)) // #fef6e4 / #1b1712 - dark ground lifted off near-black so cards/text stop looking crushed
        case .cyber: return Self.dynamicAccent(light: (0.933, 0.961, 0.969), dark: (0.020, 0.027, 0.039)) // #eef5f7 / #05070a
        case .soft: return Self.dynamicAccent(light: (0.902, 0.906, 0.933), dark: (0.169, 0.176, 0.227)) // #e6e7ee / #2b2d3a
        case .pixel: return Self.dynamicAccent(light: (0.780, 0.839, 0.937), dark: (0.161, 0.212, 0.435)) // #c7d6ef / #29366f (--panel)
        case .minimal: return Self.dynamicAccent(light: (1.0, 1.0, 1.0), dark: (0.043, 0.047, 0.059)) // #ffffff / #0b0c0f
        }
    }

    /// `nil` for Soft, whose real `.topbar{...}` rule has no border at all - every other skin's
    /// real value, not a generic hairline. `Color.primary` already flips light/dark exactly the
    /// way Luxury's `#111`/`#fefbf3` (border-color literally equals `--fg` there) and Brutalist's
    /// identical pattern do, so those two don't need their own dynamic color at all.
    var topBarBorderColor: Color? {
        switch self {
        case .luxury: return Color.primary.opacity(0.08) // rgba(0,0,0,.08) / rgba(255,255,255,.08)
        case .brutalist: return Color.primary // #111 / #fefbf3, same as --fg
        case .cyber: return accent // real accent-colored border, plus the glow this skin's own real box-shadow adds (see topBarGlow)
        case .soft: return nil
        case .pixel: return Color(red: 0.337, green: 0.424, blue: 0.525) // #566c86 - fixed, no light/dark override in the real CSS either
        case .minimal: return Self.dynamicAccent(light: (0.906, 0.910, 0.925), dark: (0.118, 0.125, 0.149)) // #e7e8ec / #1e2026
        }
    }

    /// Brutalist and Pixel's real `.topbar` border is a thick `4px`, not a hairline - everyone
    /// else's is `1px` (Soft has none at all, so this is moot for it).
    var topBarBorderWidth: CGFloat {
        switch self {
        case .brutalist, .pixel: return 4
        default: return 1
        }
    }

    /// Only Cyber's real `.topbar` adds `box-shadow:0 1px 12px -2px var(--accent)` - a genuine
    /// neon glow under the hairline border, not just a flat line like the other five.
    var topBarHasGlow: Bool { self == .cyber }

    /// A card's own corner radius under this skin - brutalist/pixel go sharp, everything else
    /// stays rounded to some degree.
    var cardRadius: CGFloat {
        switch self {
        case .brutalist, .pixel: return 4
        case .cyber: return 8
        default: return Playdock.Radius.card
        }
    }

    var fontDesign: Font.Design {
        switch self {
        case .brutalist, .cyber, .pixel: return .monospaced
        case .soft: return .rounded
        default: return .default
        }
    }

    /// Skins built around a specific dark backdrop (neon-on-black) commit to that single look
    /// rather than trying to also work as a light theme - matches the guidance that a deliberately
    /// single-world design is a legitimate choice, not an oversight.
    var forcesDarkSurface: Bool {
        self == .cyber
    }

    var borderWidth: CGFloat {
        self == .brutalist ? 3 : 1
    }

    var hasShadow: Bool {
        self != .brutalist && self != .soft
    }

    /// The real, bundled display face for this skin's most prominent text (falls back to a bold
    /// system font in this same `fontDesign` for a skin that deliberately has no display face of
    /// its own - see `SkinFonts`'s own doc comment for why).
    func displayFont(size: CGFloat) -> Font {
        if let name = SkinFonts.postscriptName(for: self) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .bold, design: fontDesign)
    }
}

/// A title/headline that renders in the active skin's own real display face - the one thing that
/// actually makes switching skins look like switching identities rather than just recoloring the
/// same system font. Used everywhere a game's name is the most prominent text on screen (grid
/// cards, every new library layout's tiles/heroes).
struct SkinTitleText: View {
    let text: String
    var size: CGFloat = 17
    var lineLimit: Int? = 1
    /// Renders in exactly this skin instead of the active one - only the setup wizard's
    /// side-by-side skin picker needs this (showing several skins' real display faces at once,
    /// none of them necessarily the currently-active one yet). Every existing call site leaves
    /// this `nil` and keeps following the active skin exactly as before.
    var skinOverride: PlaydockSkin?
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { skinOverride ?? (PlaydockSkin(rawValue: skinRaw) ?? .luxury) }

    var body: some View {
        Text(text)
            .font(skin.displayFont(size: size))
            .lineLimit(lineLimit)
    }
}

/// A card's real silhouette under this skin - a plain rounded rect for most, but Cyber Terminal's
/// own distinctive chamfered (cut-corner) shape, ported directly from its mockup's own
/// `clip-path: polygon(14px 0, 100% 0, 100% calc(100% - 14px), calc(100% - 14px) 100%, 0 100%,
/// 0 14px)` - a real structural difference no amount of corner-radius tuning on a plain
/// `RoundedRectangle` can reproduce - this is the real shape, not an approximation, shared by
/// every layout's cards/tiles alike.
struct PlaydockCardShape: InsettableShape {
    let skin: PlaydockSkin
    let cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard skin == .cyber else {
            return RoundedRectangle(cornerRadius: max(0, cornerRadius - insetAmount), style: .continuous).path(in: rect)
        }
        let cut = max(0, min(14, min(rect.width, rect.height) / 4))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }

    /// Required for `InsettableShape` (what actually makes `.strokeBorder(...)` available - a plain
    /// `Shape` only gets the centered, non-inset `.stroke(...)`, which would draw half the border
    /// outside the shape and get clipped away by the `.clipShape` right after it).
    func inset(by amount: CGFloat) -> PlaydockCardShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// A color that resolves light/dark itself, live - a file-scope twin of `PlaydockSkin.dynamicAccent`
/// for the handful of skin tokens defined outside the enum (the hard-shadow ink below).
private func dynamicColor(light: (r: Double, g: Double, b: Double), dark: (r: Double, g: Double, b: Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = isDark ? dark : light
        return NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    })
}

/// Skins whose real mockup card gets a hard, unblurred offset "twin shape" shadow instead of a soft
/// `.shadow()` glow - Neobrutalist's `box-shadow: 8px 8px 0` and Pixel Arcade's `box-shadow: 6px 6px
/// 0` are the same real technique, just different ink colors.
private func hardShadowColor(for skin: PlaydockSkin) -> Color? {
    switch skin {
    // Was `.primary` - fine as near-black on Brutalist's cream, but in dark mode `.primary` is
    // near-*white*, so every card and button sat on a hard-edged white slab: a wall of glare that
    // was a big part of "the colour scheme looks very bad." A shadow should read as a shadow in
    // both modes - near-black ink on paper, a warm charcoal (#4b4237) on the dark ground.
    case .brutalist: return dynamicColor(light: (0.078, 0.078, 0.078), dark: (0.294, 0.259, 0.216))
    case .pixel: return Color(red: 0.063, green: 0.071, blue: 0.11) // #10121c, the mockup's own ink
    default: return nil
    }
}

/// Soft's real, exact `--sd`/`--hl` neumorphic shadow/highlight pair from skins.css - genuine
/// colors, not a generic black/white wash. Real neumorphism reads from these being *close in
/// value* to the background itself (`--bg:#2b2d3a`/`--sd:#212330`/`--hl:#363a4c` in dark mode,
/// `#e6e7ee`/`#c3c6d4`/`#ffffff` in light), not from raw contrast - which is exactly why a generic
/// `.black.opacity(0.2)` shadow rendered completely invisible against Soft's own dark background.
/// Grid's own WKWebView renders these exact CSS values already, so this brings every native
/// card/tile/button in line with it.
private func softShadowHighlight(isDark: Bool) -> (shadow: Color, highlight: Color) {
    isDark
        ? (Color(red: 0.129, green: 0.137, blue: 0.188), Color(red: 0.212, green: 0.227, blue: 0.298)) // #212330 / #363a4c
        : (Color(red: 0.765, green: 0.776, blue: 0.831), .white) // #c3c6d4 / #ffffff
}

private struct CardSurface: ViewModifier {
    var isHovering: Bool = false
    /// See `SkinTitleText.skinOverride` - same reason, same "every real call site leaves it nil"
    /// contract.
    var skinOverride: PlaydockSkin?
    /// A specific game's own sampled art color (`GameArtColor`), blended into the skin's accent at
    /// a modest weight wherever this card shows accent color at all - `nil` everywhere the caller
    /// doesn't have a specific game to key off of, which keeps the skin's own fixed accent exactly
    /// as before.
    var accentOverride: Color?
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { skinOverride ?? (PlaydockSkin(rawValue: skinRaw) ?? .luxury) }
    private var effectiveAccent: Color {
        guard let accentOverride else { return skin.accent }
        return skin.accent.blended(toward: accentOverride, amount: 0.4)
    }

    /// The soft-shadow neumorphic highlight, precomputed as its own small view (not an inline `if`
    /// inside the main chain) - Swift's type checker genuinely cannot solve this many chained
    /// modifiers with conditional ViewBuilder content mixed in as one expression
    /// ("failed to produce diagnostic for expression"), confirmed live against the real compiler,
    /// not a style choice.
    @ViewBuilder
    private func softHighlight(shape: PlaydockCardShape) -> some View {
        if skin == .soft {
            let pair = softShadowHighlight(isDark: colorSchemeIsDark)
            shape.fill(pair.highlight).offset(x: -9, y: -9).blur(radius: 12)
        }
    }

    @ViewBuilder
    private func hardShadowTwin(shape: PlaydockCardShape, color: Color?, offset: CGFloat) -> some View {
        if let color {
            shape.fill(color).offset(x: offset, y: offset)
        }
    }

    func body(content: Content) -> some View {
        let shape = PlaydockCardShape(skin: skin, cornerRadius: skin.cardRadius)
        let hardShadow: Color? = hardShadowColor(for: skin)
        let isSoft = skin == .soft
        let offset: CGFloat = isHovering ? 11 : 7
        let softPair = softShadowHighlight(isDark: colorSchemeIsDark)

        let fillStyle: AnyShapeStyle = skin.forcesDarkSurface ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial)
        let borderOpacity: Double = isHovering ? 0.5 : 0.16
        let borderColor: Color = hardShadow ?? effectiveAccent.opacity(borderOpacity)

        // Soft's own real box-shadow.9px 9px 18px var(--sd) - the mockup's exact color, not a
        // generic black wash (which is exactly what went invisible against Soft's own dark
        // background before this).
        let shadowColor: Color = isSoft ? softPair.shadow : (skin.hasShadow ? .black.opacity(isHovering ? 0.30 : 0.16) : .clear)
        let shadowRadius: CGFloat = isSoft ? 15 : (isHovering ? 24 : 12)
        let shadowX: CGFloat = isSoft ? 9 : 0
        let shadowY: CGFloat = isSoft ? 9 : (isHovering ? 12 : 6)
        let hoverPop: CGFloat = (hardShadow != nil && isHovering) ? -3 : 0
        let hoverScale: CGFloat = (isHovering && hardShadow == nil) ? 1.015 : 1

        let step1 = content
            .fontDesign(skin.fontDesign)
            // A real per-game tint behind the fill itself - not just wherever a skin's own accent
            // already shows (many skins' real card fill, Brutalist and Luxury included, never uses
            // accent color at all, so a tint that only ever reached borders/buttons had nowhere to
            // show on those). Sits behind the translucent material fill, tinting it the way a
            // colored surface behind real frosted glass would, rather than a flat wash on top of
            // the content.
            .background(alignment: .center) { if let accentOverride { shape.fill(accentOverride.opacity(0.4)) } }
            .background(fillStyle, in: shape)
        let step2 = step1
            .background(softHighlight(shape: shape))
        let step3 = step2
            .overlay(shape.strokeBorder(borderColor, lineWidth: skin.borderWidth))
            .clipShape(shape)
        let step4 = step3
            .background(hardShadowTwin(shape: shape, color: hardShadow, offset: offset))
        return step4
            .shadow(color: shadowColor, radius: shadowRadius, x: shadowX, y: shadowY)
            .offset(x: hoverPop, y: hoverPop)
            .scaleEffect(hoverScale)
            .animation(.easeOut(duration: 0.18), value: isHovering)
    }

    private var colorSchemeIsDark: Bool { NSApp.effectiveAppearance.name == .darkAqua }
}

private struct TileSurface: ViewModifier {
    var isHovering: Bool = false
    /// See `SkinTitleText.skinOverride` - same reason, same "every real call site leaves it nil"
    /// contract.
    var skinOverride: PlaydockSkin?
    /// See `CardSurface.accentOverride` - identical contract.
    var accentOverride: Color?
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { skinOverride ?? (PlaydockSkin(rawValue: skinRaw) ?? .luxury) }

    @ViewBuilder
    private func hardShadowTwin(shape: PlaydockCardShape, color: Color?, offset: CGFloat) -> some View {
        if let color {
            shape.fill(color).offset(x: offset, y: offset)
        }
    }

    /// Soft's real raised "popped out" look, ported from `CardSurface`'s own identical recipe.
    /// The confirmed bug was that a tile (the real clickable game entry in Shelves/Steam-style/
    /// Carousel) inherited
    /// `skin.hasShadow == false` - correct for a full *card*, which replaces its shadow with this
    /// exact highlight below - but a tile never got that replacement, so it rendered completely
    /// flat: no shadow and no highlight standing in for one.
    @ViewBuilder
    private func softHighlight(shape: PlaydockCardShape) -> some View {
        if skin == .soft {
            let pair = softShadowHighlight(isDark: colorSchemeIsDark)
            shape.fill(pair.highlight).offset(x: -6, y: -6).blur(radius: 8)
        }
    }

    private var colorSchemeIsDark: Bool { NSApp.effectiveAppearance.name == .darkAqua }

    func body(content: Content) -> some View {
        let shape = PlaydockCardShape(skin: skin, cornerRadius: skin.cardRadius)
        let hardShadow: Color? = hardShadowColor(for: skin)
        let isSoft = skin == .soft
        let offset: CGFloat = isHovering ? 9 : 6
        let softPair = softShadowHighlight(isDark: colorSchemeIsDark)

        let borderColor: Color = hardShadow ?? Color.white.opacity(0.12)
        let shadowColor: Color = isSoft ? softPair.shadow : (skin.hasShadow ? .black.opacity(isHovering ? 0.35 : 0.25) : .clear)
        let shadowRadius: CGFloat = isSoft ? 12 : (isHovering ? 12 : 8)
        let shadowX: CGFloat = isSoft ? 7 : 0
        let shadowY: CGFloat = isSoft ? 7 : (isHovering ? 6 : 4)
        let hoverScale: CGFloat = (isHovering && hardShadow == nil) ? 1.03 : 1

        // Broken into typed steps - see CardSurface's own doc comment on this same pattern (a real
        // Swift type-checker limitation with this many chained modifiers + conditional content).
        let step1 = content
            .background(softHighlight(shape: shape))
            .clipShape(shape)
        let step2 = step1
            // A real per-game tint - laid over the art itself (unlike CardSurface's background
            // wash, real art here is opaque and would hide anything placed behind it), the same
            // subtle color cast a colored gel over a photo gives.
            .overlay {
                if let accentOverride {
                    shape.fill(accentOverride.opacity(0.32))
                }
            }
            .overlay(shape.strokeBorder(borderColor, lineWidth: skin.borderWidth))
        let step3 = step2
            .background(hardShadowTwin(shape: shape, color: hardShadow, offset: offset))
        return step3
            .shadow(color: shadowColor, radius: shadowRadius, x: shadowX, y: shadowY)
            .scaleEffect(hoverScale)
            .animation(.easeOut(duration: 0.16), value: isHovering)
    }
}

/// A real, per-skin button treatment: `cardSurface()`/`tileSurface()` got genuine per-skin craft
/// (Cyber's cut corners, Brutalist/Pixel's hard shadow, Soft's neumorphic highlight) while every
/// native button (View Details, Launch, prev/next) stayed a plain, unthemed `.borderedProminent`
/// regardless of skin. Same shape/shadow language as the cards, applied to buttons.
struct PlaydockButtonStyle: ButtonStyle {
    /// `true` for a primary action (View Details/Launch); `false` for a secondary control
    /// (prev/next nav). The mockups never actually style a "secondary button" of their own - only
    /// `.cta`/`.run` exist - so this half stays a reasonable, self-consistent outline convention;
    /// `prominent`'s own look below is a real, per-skin port instead.
    var prominent: Bool = true
    /// See `SkinTitleText.skinOverride` - same reason, same "every real call site leaves it nil"
    /// contract.
    var skinOverride: PlaydockSkin?
    /// See `CardSurface.accentOverride` - identical contract.
    var accentOverride: Color?
    /// A card-sized CTA (`LibraryEntryTile`'s own per-skin button) needs Grid's real, tighter card
    /// button proportions (~12.5px text, ~10px padding in a ~250px-wide card) rather than the
    /// larger hero/detail-view button size every other call site still wants.
    var compact: Bool = false
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { skinOverride ?? (PlaydockSkin(rawValue: skinRaw) ?? .luxury) }

    func makeBody(configuration: Configuration) -> some View {
        let look = playdockButtonLook(skin: skin, prominent: prominent, isPressed: configuration.isPressed, accentOverride: accentOverride)
        if compact {
            PlaydockButtonBody(configuration: configuration, look: look, skin: skin, font: .caption.weight(.semibold), horizontalPadding: 12, verticalPadding: 7)
        } else {
            PlaydockButtonBody(configuration: configuration, look: look, skin: skin)
        }
    }
}

/// One skin's own button recipe. Ported directly from that skin's real `.cta`/`.run` rule in
/// skins.css instead of one generic "accent fill, white text" guess applied to every skin alike -
/// each real button is structurally different (Luxury inverts fg/bg, Cyber is transparent with
/// glowing outline text that only fills solid on press, Brutalist is a flat ink
/// block with no shadow on the button itself at all, Pixel offsets a hard shadow in its own real
/// `--accent2`, Minimal has no visible chrome beyond colored text) - this reproduces that, not a
/// sixth approximation of it. Shared by `PlaydockButtonStyle` (every card/hero/nav button) and
/// `BigButtonStyle` (the single dominant Launch action) so the *same* real recipe backs both
/// instead of the dominant button alone staying generic.
struct PlaydockButtonLook {
    var fill: AnyShapeStyle
    var labelColor: Color
    var borderColor: Color = .clear
    var borderWidth: CGFloat = 0
    var cornerRadius: CGFloat = 10
    /// A second copy of the shape, filled with this color and offset behind the button - Pixel's
    /// own real box-shadow twin, matching `cardSurface()`'s identical technique for cards. `nil`
    /// everywhere else.
    var hardOffsetColor: Color?
    var hardOffsetX: CGFloat = 3
    var hardOffsetY: CGFloat = 3
    /// How far the button's own content shifts on press - Brutalist/Pixel move diagonally,
    /// matching each one's own real `:active` rule.
    var pressOffsetX: CGFloat = 0
    var pressOffsetY: CGFloat = 0
    var pressFadesOpacity = false
    var neumorphic = false
    var scalesOnPress = true
    var hasDropShadow = false
}

/// `accentOverride` is a specific game's own sampled art color (`GameArtColor`) blended a modest
/// amount into the skin's accent wherever this button shows accent color - `nil` keeps the skin's
/// fixed accent exactly as before.
func playdockButtonLook(skin: PlaydockSkin, prominent: Bool, isPressed: Bool, accentOverride: Color? = nil) -> PlaydockButtonLook {
    let accent = accentOverride.map { skin.accent.blended(toward: $0, amount: 0.4) } ?? skin.accent
    guard prominent else {
        return PlaydockButtonLook(fill: AnyShapeStyle(Color.clear), labelColor: accent, borderColor: accent.opacity(0.5), borderWidth: 1.5, cornerRadius: min(skin.cardRadius, 12), hasDropShadow: skin.hasShadow)
    }
    switch skin {
    case .luxury:
        // .lux .cta{background:var(--fg);color:var(--bg);...} - a real inverted "buy button", not
        // an accent-colored one; Color.primary/.windowBackgroundColor already track light and
        // dark exactly the way --fg/--bg do. The CSS is a flat fill with no shadow of its own, but
        // a flat solid block was exactly the "looks generic everywhere else" complaint - give it
        // the same raised dual-shadow depth Soft's real button already has, so it reads as a
        // tactile object rather than a plain color chip.
        return PlaydockButtonLook(fill: AnyShapeStyle(Color.primary), labelColor: Color(nsColor: .windowBackgroundColor), cornerRadius: 9, neumorphic: true)
    case .brutalist:
        // .brut .cta was a fixed `#111` ink fill regardless of mode - on Brutalist's own dark
        // ground (`#1b1712`) that's a near-invisible fill, so the button read as just a hollow
        // white outline: half of "the colour scheme looks very bad." Inverted to a theme-aware
        // solid the way Luxury's real `.cta` already is - a near-black block with cream text on
        // paper, a cream block with dark text on the dark ground - keeping every other Brutalist
        // button trait (hard 3px border, sharp corners, hard offset twin, diagonal press, no
        // scale). skins.css's `.brut .cta` is updated to the same `var(--fg)`/`var(--bg)` pair.
        return PlaydockButtonLook(fill: AnyShapeStyle(Color.primary), labelColor: Color(nsColor: .windowBackgroundColor), borderColor: .primary, borderWidth: skin.borderWidth, cornerRadius: 0, hardOffsetColor: hardShadowColor(for: .brutalist), pressOffsetX: 2, pressOffsetY: 2, scalesOnPress: false)
    case .cyber:
        // .cyber .cta{border:1px solid var(--accent);background:transparent;color:var(--accent);}
        // .cyber .cta:active{background:var(--accent);color:#00131a;} - inverts solid on press.
        if isPressed {
            return PlaydockButtonLook(fill: AnyShapeStyle(accent), labelColor: Color(red: 0.0, green: 0.075, blue: 0.102), cornerRadius: 0)
        }
        return PlaydockButtonLook(fill: AnyShapeStyle(Color.clear), labelColor: accent, borderColor: accent, borderWidth: 1, cornerRadius: 0)
    case .soft:
        // .neu .cta{...box-shadow:5px 5px 10px var(--sd),-5px -5px 10px var(--hl);} - a real
        // raised dual shadow (dark+light), not just the dark half.
        return PlaydockButtonLook(fill: AnyShapeStyle(Color(nsColor: .windowBackgroundColor)), labelColor: accent, cornerRadius: 14, neumorphic: true)
    case .pixel:
        // .pix .cta{background:var(--accent2);color:#10121c;box-shadow:3px 3px 0 #10121c;}
        // accent2 is Pixel's own distinct swatch, not blended - the hard-shadow twin's ink stays
        // exact either way.
        return PlaydockButtonLook(fill: AnyShapeStyle(skin.accent2), labelColor: Color(red: 0.063, green: 0.071, blue: 0.11), cornerRadius: 0, hardOffsetColor: hardShadowColor(for: .pixel), pressOffsetX: 3, pressOffsetY: 3, scalesOnPress: false)
    case .minimal:
        // .lst .launch{background:none;border:none;color:var(--accent);...} .launch:active{opacity:.5;}
        return PlaydockButtonLook(fill: AnyShapeStyle(Color.clear), labelColor: accent, cornerRadius: 0, pressFadesOpacity: true, scalesOnPress: false)
    }
}

/// Renders one button from an already-resolved `PlaydockButtonLook` - shared tail for
/// `PlaydockButtonStyle` and `BigButtonStyle`, which differ only in padding/font size, not in what
/// a skin's button actually looks like.
struct PlaydockButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let look: PlaydockButtonLook
    let skin: PlaydockSkin
    var font: Font = .callout.weight(.semibold)
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isPressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)

        // Typed steps rather than one long chain - see CardSurface's own doc comment on why
        // (a real Swift type-checker limit with this many modifiers plus conditional content).
        let step1 = configuration.label
            .font(font)
            .fontDesign(skin.fontDesign)
            .foregroundStyle(look.labelColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .opacity(look.pressFadesOpacity && isPressed ? 0.5 : 1)
        let step2 = step1
            .background(look.fill, in: shape)
            .background(alignment: .center) { neumorphicHighlight(shape: shape, isPressed: isPressed) }
        let step3 = step2
            .overlay(shape.strokeBorder(look.borderColor, lineWidth: look.borderWidth))
            .clipShape(shape)
        let step4 = step3
            .background(alignment: .center) { hardOffsetTwin(shape: shape, isPressed: isPressed) }
        return step4
            .offset(x: isPressed ? look.pressOffsetX : 0, y: isPressed ? look.pressOffsetY : 0)
            .shadow(color: (!isPressed && look.hasDropShadow) ? Color.black.opacity(0.18) : .clear, radius: 6, y: 3)
            .scaleEffect(isPressed && look.scalesOnPress ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    @ViewBuilder
    private func neumorphicHighlight(shape: RoundedRectangle, isPressed: Bool) -> some View {
        if look.neumorphic && !isPressed {
            // Real --sd/--hl, not a generic black/white wash - see softShadowHighlight's own doc
            // comment for why the wash version went invisible against Soft's dark background.
            // .neu .cta{box-shadow:5px 5px 10px var(--sd),-5px -5px 10px var(--hl);} - a real,
            // confirmed bug: this used to port that as offset 3/blur 4, well under half the real
            // CSS's spread. At that size the glow only ever peeked a couple of points past the
            // button's own edge - invisible in practice next to a photographic hero background,
            // and barely there even on a plain card. 5/10 is the real number, not a guess.
            let pair = softShadowHighlight(isDark: colorScheme == .dark)
            ZStack {
                shape.fill(pair.shadow).offset(x: 5, y: 5).blur(radius: 10)
                shape.fill(pair.highlight).offset(x: -5, y: -5).blur(radius: 10)
            }
        }
    }

    @ViewBuilder
    private func hardOffsetTwin(shape: RoundedRectangle, isPressed: Bool) -> some View {
        if let color = look.hardOffsetColor, !isPressed {
            shape.fill(color).offset(x: look.hardOffsetX, y: look.hardOffsetY)
        }
    }
}

extension View {
    /// A lighter version of `cardSurface()` for a raw art tile (the new library layouts' poster/
    /// icon tiles) - just the skin's corner radius, border, and shadow, with no material fill
    /// layered on top of real artwork the way a content card needs. Reads the same `PlaydockSkin`
    /// so every layout's tiles restyle together with the grid's own cards.
    func tileSurface(isHovering: Bool = false, skinOverride: PlaydockSkin? = nil, accentOverride: Color? = nil) -> some View {
        modifier(TileSurface(isHovering: isHovering, skinOverride: skinOverride, accentOverride: accentOverride))
    }

    /// Each skin's real `.art` filter/overlay from skins.css, ported directly - not just the
    /// card's own shape/shadow, but the actual *image* treatment: Cyber's scanning CRT overlay and
    /// saturation/contrast bump, Brutalist/Pixel's own saturation/contrast bumps. Every layout's
    /// own art (tiles, hero panels, detail-view art, Controller
    /// Mode) goes through this now, matching Grid's real CSS instead of only Grid having it.
    /// Reads the active `PlaydockSkin` itself (like `cardSurface()`/`tileSurface()`), so any art
    /// view anywhere just appends this with no extra state of its own.
    func skinArtTreatment() -> some View {
        modifier(SkinArtTreatment())
    }

    /// The same real per-game color cast `tileSurface(accentOverride:)`/`cardSurface
    /// (accentOverride:)` apply, for the handful of places (hero banners in Shelves/Sidebar/
    /// Spotlight) that render raw art directly rather than going through either of those - `nil`
    /// leaves the art untouched.
    @ViewBuilder
    func gameAccentTint(_ color: Color?) -> some View {
        if let color {
            overlay(color.opacity(0.32))
        } else {
            self
        }
    }
}

private struct SkinArtTreatment: ViewModifier {
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch skin {
        case .cyber:
            content.saturation(1.4).contrast(1.15).overlay(CyberScanlines())
        case .brutalist:
            content.saturation(1.3).contrast(1.1)
        case .pixel:
            content.saturation(1.6)
        case .soft:
            // box-shadow: inset 4px 4px 10px rgba(0,0,0,.18), inset -3px -3px 8px
            // rgba(255,255,255,.15) - SwiftUI has no true inset shadow, so the real "sunken into
            // the page" look is approximated with matching corner-anchored dark/light glows.
            content.overlay(
                LinearGradient(
                    colors: [.black.opacity(0.16), .clear, .clear, .white.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        case .luxury, .minimal:
            content
        }
    }
}

/// Cyber's real `repeating-linear-gradient(0deg,rgba(0,0,0,.15) 0 2px,transparent 2px 4px)` scan
/// overlay - actual repeating hairlines, not a single translucent tint standing in for the idea.
private struct CyberScanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(.black.opacity(0.15)))
                y += 4
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The one shared "floating card" treatment used across the game grid - rounded, materialed,
    /// bordered, properly clipped (an unclipped `.background` shape alone lets square-cornered
    /// content like artwork visibly overflow past the rounded corners underneath it), and shadowed
    /// with a genuine lift on hover, matching real game-library card conventions instead of a flat,
    /// borderless rectangle with no depth. Reads the active `PlaydockSkin` itself, so every card
    /// everywhere restyles together the instant the skin setting changes.
    func cardSurface(isHovering: Bool = false, skinOverride: PlaydockSkin? = nil, accentOverride: Color? = nil) -> some View {
        modifier(CardSurface(isHovering: isHovering, skinOverride: skinOverride, accentOverride: accentOverride))
    }

    /// Applies just the skin's accent color and font design, for non-card surfaces (headers,
    /// buttons, layout chrome) that still need to restyle with the active skin.
    func skinned() -> some View {
        modifier(SkinTint())
    }
}

private struct SkinTint: ViewModifier {
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw: String = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }
    func body(content: Content) -> some View {
        content.fontDesign(skin.fontDesign).tint(skin.accent)
    }
}

/// The library's *structure* - independent from `PlaydockSkin` (its look). Each case is a real,
/// distinct navigation model, not a reskinned grid - researched against actual, proven app
/// patterns before building: Steam's own current library (sidebar + tag-filtered grid), PS5/Xbox
/// home screens (hero + horizontal shelves), Music.app (sidebar list + big detail pane), and Apple
/// TV's poster carousel. A dense-table List layout and a Launchpad-style bare icon grid were both
/// tried and removed - a plain table with no artwork and a grid of generic small icons never read
/// as real, distinct designs the way each of the remaining five genuinely does.
enum LibraryLayoutStyle: String, CaseIterable, Identifiable {
    case grid, shelves, sidebar, steam, carousel, spotlight
    var id: String { rawValue }

    static let storageKey = "com.exedock.libraryLayout"

    var displayName: String {
        switch self {
        case .grid: return "Grid"
        case .shelves: return "Shelves"
        case .sidebar: return "Sidebar"
        case .steam: return "Steam-style"
        case .carousel: return "Carousel"
        case .spotlight: return "Spotlight"
        }
    }

    var subtitle: String {
        switch self {
        case .grid: return "Cards in a grid - the default"
        case .shelves: return "Featured hero + horizontal rows"
        case .sidebar: return "List with a big detail pane"
        case .steam: return "Sidebar categories + poster grid"
        case .carousel: return "One row, focus scales up"
        case .spotlight: return "One game up close, browsable, + a grid"
        }
    }

    /// A plain SF Symbol standing in for each layout's real shape - used wherever a layout needs
    /// to be picked from a short list without rendering the whole thing (the setup wizard's own
    /// picker), not a substitute for actually seeing it.
    var iconName: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .shelves: return "rectangle.grid.1x2"
        case .sidebar: return "sidebar.left"
        case .steam: return "square.grid.3x3.square"
        case .carousel: return "rectangle.stack"
        case .spotlight: return "star.square.on.square"
        }
    }
}

/// Which real art a card/tile shows for a Steam game - a real, fixable gap: every portrait-shaped
/// tile
/// (Carousel, Steam-style, List/Sidebar's small icons) was force-cropping the landscape
/// `header.jpg` banner rather than using Steam's own real, *native* portrait box art
/// (`library_600x900.jpg`, cached locally by the real Steam client - see `SteamLibraryCache`).
/// `.banner` keeps the existing landscape header everywhere (matches the mockups' own card shape);
/// `.boxArt` uses Steam's native portrait art where a game has it cached, falling back to the
/// banner for anything Steam hasn't cached yet (never viewed in Steam's own library) or a custom
/// game (no Steam cache to read at all).
enum PlaydockArtSource: String, CaseIterable, Identifiable {
    case banner, boxArt
    var id: String { rawValue }
    static let storageKey = "com.exedock.artSource"
    var displayName: String {
        switch self {
        case .banner: return "Banner"
        case .boxArt: return "Box Art"
        }
    }
    var subtitle: String {
        switch self {
        case .banner: return "Steam's landscape store banner"
        case .boxArt: return "Steam's native portrait box art, where cached"
        }
    }
}

/// A game card's "this is running right now" state - a plain static status tag with a soft
/// breathing pulse on the dot, not a live-ticking elapsed-time counter. Deliberately dropped the
/// minute counter this replaced: "running status not very good... 0m never actually changes," per
/// live feedback - a real bug (detection flickering resets the remembered start time, so the
/// counter can get stuck near zero indefinitely) traced back to how Steam/GOG Galaxy/Playnite
/// actually handle this in their own library grids too - none of them show a live-updating per-
/// minute clock on a card; a simple "Playing"/"Running" state tag is the real, established
/// convention. Removing the number removes the whole class of bug instead of chasing every way
/// detection can flicker.
struct RunningBadge: View {
    /// The full-width card version (default) fills its row and uses the standard `.quaternary`
    /// card-language background; `compact: true` is a tighter pill for a context that already sits
    /// on its own dark/blurred backdrop (the Game Detail views' action row), matching the white-
    /// on-translucent treatment that row's other elements already use.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text("Running")
                .font(.callout.weight(.medium))
                .foregroundStyle(compact ? .white : .primary)
        }
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.horizontal, compact ? 16 : 0)
        .padding(.vertical, compact ? 10 : 12)
        .background(
            compact ? AnyShapeStyle(.white.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: compact ? 10 : Playdock.Radius.control)
        )
    }
}

/// The shared breathing/pulsing green dot behind every "Running" indicator - a soft expanding ring
/// that fades out and loops, the same "this is live, right now" convention notification badges and
/// recording indicators use, rather than a numeric readout that can only ever be as reliable as
/// the underlying process-detection polling.
private struct PulsingDot: View {
    @LocalState private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(isPulsing ? 0 : 0.5), lineWidth: 4)
                    .scaleEffect(isPulsing ? 2.2 : 1)
            )
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
