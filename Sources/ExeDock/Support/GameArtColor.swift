import AppKit
import CoreImage
import SwiftUI

/// A game's own dominant color, sampled from its real cached artwork - so a card's accent can pick
/// up a subtle hint of that specific game's palette instead of every card under a skin using the
/// exact same static swatch. Blended with (never replacing) the active skin's own accent by
/// `PlaydockSkin.blended(withGameColor:)`, so a skin's real identity stays intact and this only
/// ever reads as a per-game variation on it.
enum GameArtColor {
    private static let cache: NSCache<NSString, NSColor> = {
        let cache = NSCache<NSString, NSColor>()
        cache.countLimit = 400 // one entry per distinct art path ever sampled this session
        return cache
    }()

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Forgets every sampled color. Used by Settings' "Hard Refresh Game Info" - a game whose art
    /// is about to be re-downloaded should get its accent re-sampled from the new image, not keep
    /// the one derived from the old one.
    static func clearCache() {
        cache.removeAllObjects()
    }

    /// Keeps `color`'s real hue but pulls saturation and brightness into a range that actually
    /// reads as a color instead of a gray - a raw pixel average is desaturated far more often than
    /// not (see `dominantColor`'s own doc comment for why), and a near-black or near-white result
    /// is equally useless as a tint (barely visible against either a dark or a light card). Hue is
    /// never touched - this is *this image's own* color, just made usable, not a different one.
    ///
    /// `nil` when the raw average is genuinely close to gray (`rawSaturation` below the threshold)
    /// - a real, confirmed bug: forcing *any* raw average up to 50%+ saturation doesn't just make a
    /// subtle real color usable, it also takes pure noise and fabricates a color from it. Most box
    /// art averages to a near-white/gray (light background + a logo), and real-world "white" JPEGs
    /// almost always carry a tiny, near-imperceptible warm bias (JPEG's YCbCr rounding leans warm) -
    /// hue is mathematically unstable that close to gray, but whatever tiny hue `getHue` measures
    /// was getting amplified to a strong, consistent tint on nearly every card regardless of that
    /// game's actual colors, which is exactly what read as "the whole app has a yellow filter."
    /// Below the threshold there's no real color signal to boost, so this hands back nothing rather
    /// than inventing one - callers fall back to the skin's own fixed accent, same as any image with
    /// no art at all.
    private static func vivid(_ color: NSColor) -> NSColor? {
        guard let hsb = color.usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s >= 0.12 else { return nil }
        let vividSaturation = max(s, 0.5)
        let vividBrightness = min(max(b, 0.35), 0.8)
        return NSColor(hue: h, saturation: vividSaturation, brightness: vividBrightness, alpha: 1)
    }

    /// The already-cached result for `path`, if any - safe to call from a view's own body since it
    /// never does any real work, just an `NSCache` lookup. `nil` until `dominantColor(forImagePath:)`
    /// has resolved at least once for this path.
    static func cachedColor(forImagePath path: String) -> Color? {
        cache.object(forKey: path as NSString).map { Color(nsColor: $0) }
    }

    /// The average color of the image already cached at `path` (via `LocalImageCache`, so this
    /// never decodes a file a second time) - `nil` if there's no image there or the sample
    /// genuinely can't be computed. Real work (`CIAreaAverage`, the same standard technique system
    /// UI itself uses for this, over an already-downsampled image) - measured live at ~230ms on its
    /// first real call (`CIContext`'s own one-time GPU pipeline setup) and under 2ms on every call
    /// after, so this must never run synchronously on the main thread the first time. Callers use
    /// this from a `.task(id:)`, matching every other per-entry art fetch already in this codebase
    /// (`LibraryPresentation.resolve`), and read `cachedColor(forImagePath:)` for the fast path.
    static func dominantColor(forImagePath path: String) async -> Color? {
        if let cached = cachedColor(forImagePath: path) { return cached }
        return await Task.detached(priority: .utility) {
            guard let nsImage = LocalImageCache.image(atPath: path),
                  let tiff = nsImage.tiffRepresentation,
                  let ciImage = CIImage(data: tiff) else { return nil }

            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0,
                  let averageFilter = CIFilter(name: "CIAreaAverage", parameters: [
                    kCIInputImageKey: ciImage,
                    kCIInputExtentKey: CIVector(cgRect: extent),
                  ]),
                  let outputImage = averageFilter.outputImage else { return nil }

            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                outputImage, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            let rawAverage = NSColor(
                red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                blue: CGFloat(pixel[2]) / 255, alpha: 1
            )
            // A literal pixel average over real cover art - much of which is a mostly-white/light
            // background with a logo or a few characters on it - lands on a pale, low-saturation
            // gray far more often than not (confirmed live: a real chalkboard-style cover's own
            // average came back essentially neutral). That's mathematically correct but useless as
            // an *accent* - nothing to actually tint anything with. Boosting saturation/normalizing
            // brightness afterward (keeping the real hue this image actually has) is the standard
            // fix real "extract an accent from this image" features use, not a second average.
            guard let color = vivid(rawAverage) else { return nil }
            cache.setObject(color, forKey: path as NSString)
            return Color(nsColor: color)
        }.value
    }
}

extension Color {
    /// A linear RGB blend toward `other` - `amount` 0 keeps `self` unchanged, 1 becomes `other`
    /// entirely. Used to fold a game's own sampled color into a skin's fixed accent at a modest
    /// weight, never enough to override the skin's own identity.
    func blended(toward other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? NSColor(other)
        let t = min(max(amount, 0), 1)
        return Color(
            red: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t
        )
    }
}
