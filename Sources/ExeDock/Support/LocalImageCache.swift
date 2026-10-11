import AppKit
import ImageIO

/// Caches decoded images for local files (the Steam avatar, cached game header/background art,
/// screenshots) so a SwiftUI view re-rendering for an unrelated reason - e.g. `statusMessage`
/// changing while the dashboard is visible - doesn't re-read and re-decode the same file from disk
/// every time. `AppIconProvider` does the same thing for Finder icons; this covers literal image
/// files.
///
/// Verified live why this app's memory footprint could grow more than it should for what's meant to
/// be a lightweight gaming launcher: Steam's own "background" art is often 1400x800+ pixels (a real
/// example measured at 1438x810) - trivial as a ~16KB JPEG on disk, but a *decoded* bitmap at that
/// size is ~4.7MB in memory, and nothing here ever displays that art at anywhere near full
/// resolution (it's either blurred full-screen or a small card). With no cap, every distinct image
/// ever viewed in a session - every game's header, background, and up to 6 screenshots - stayed
/// cached forever. Fixed two ways: images are downsampled at decode time to a size that still looks
/// perfect at every real use site here, and the cache now has an explicit byte budget so a long
/// session with a large library can't grow it without bound.
enum LocalImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // A generous but real budget - roughly 30-40 games' worth of art fully cached at once,
        // comfortably more than a single screen ever shows, without letting a long session with a
        // big library grow this without limit. NSCache evicts least-recently-used entries once
        // this is exceeded, and can evict earlier under real system memory pressure regardless.
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    /// No real use in this app ever needs more pixels than this on the longest side - the biggest
    /// on-screen use is a blurred full-window backdrop or the Game Detail view's header art, both
    /// well under it. Downsampling here (not after a full decode) is also the efficient way to do
    /// it: `CGImageSourceCreateThumbnailAtIndex` decodes directly at the target size instead of
    /// decoding full-resolution first and throwing most of it away.
    private static let maxDimension: CGFloat = 1000

    /// Drops every decoded bitmap. Used by Settings' "Hard Refresh Game Info" so re-downloaded art
    /// at the same file path isn't masked by the previous decode still sitting in memory.
    static func clear() {
        cache.removeAllObjects()
    }

    static func image(atPath path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = downsampledImage(atPath: path) else { return nil }
        // Approximate decoded byte size (width * height * 4 bytes/pixel for an RGBA bitmap) - the
        // same unit NSCache expects for totalCostLimit to mean anything.
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private static func downsampledImage(atPath path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Fall back to a plain load for anything the thumbnail path can't handle, rather than
            // losing the image entirely - correctness over the memory optimization in that edge case.
            return NSImage(contentsOfFile: path)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
