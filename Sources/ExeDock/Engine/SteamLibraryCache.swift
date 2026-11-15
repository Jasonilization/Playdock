import Foundation
import ImageIO

/// Reads Steam's own locally-cached library art directly off disk - no network call, no re-fetch of
/// anything the real Steam client already downloaded for its own library UI. Confirmed live against
/// real cached folders (`~/Library/Application Support/Steam/appcache/librarycache/<appid>/`):
/// `library_600x900.jpg` is real, *native* portrait box art (not a crop of the landscape header),
/// and a real small icon exists too but under a SHA1-hashed filename Steam itself assigns, mixed in
/// with other same-shaped hashed files that are *not* images at all (some have no extension and
/// aren't decodable). This is exactly the gap behind "all the games are cropped" for every
/// portrait-oriented layout (Carousel, Steam-style, List/Sidebar's small icons): those were all
/// force-cropping the landscape `header.jpg` banner into a portrait frame because portrait art was
/// never looked for in the first place.
enum SteamLibraryCache {
    /// Mac Steam first, then the Windows bottle's own cache. A game installed only through
    /// Playdock's Steam never writes art into the Mac client's librarycache.
    private static func cacheDirs(appID: String) -> [String] {
        let mac = ("~/Library/Application Support/Steam/appcache/librarycache/\(appID)" as NSString).expandingTildeInPath
        let wine = (SteamInstaller.steamBottle.driveCPath as NSString)
            .appendingPathComponent("Program Files (x86)/Steam/appcache/librarycache/\(appID)")
        return [mac, wine]
    }

    /// Real, native portrait box art (600x900) for this app, if Steam has ever cached it locally -
    /// only true once the game has actually been viewed in Steam's own library UI at least once, so
    /// this is a real "might not exist yet" rather than "always available."
    static func portraitArtPath(appID: String) -> String? {
        for dir in cacheDirs(appID: appID) {
            let path = (dir as NSString).appendingPathComponent("library_600x900.jpg")
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// The best real square icon Steam has cached for this app, if any - scans for SHA1-hash-named
    /// files (Steam's own convention for these) with an image extension, decodes just their
    /// dimensions (not the full image - `CGImageSourceCopyPropertiesAtIndex` is cheap), keeps only
    /// the genuinely square ones, and returns the largest. Hash-named files with *no* extension
    /// exist in the same folder and are real but are not decodable images (confirmed live) - never
    /// considered here.
    static func iconPath(appID: String) -> String? {
        let hashPattern = try? NSRegularExpression(pattern: "^[0-9a-f]{20,40}\\.(jpg|jpeg|png)$", options: .caseInsensitive)
        var best: (path: String, size: Int)?
        for dir in cacheDirs(appID: appID) {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            best = bestIcon(in: files, dir: dir, pattern: hashPattern, current: best)
        }
        return best?.path
    }

    private static func bestIcon(in files: [String], dir: String, pattern: NSRegularExpression?, current: (path: String, size: Int)?) -> (path: String, size: Int)? {
        var best = current
        for file in files {
            let range = NSRange(file.startIndex..<file.endIndex, in: file)
            guard pattern?.firstMatch(in: file, range: range) != nil else { continue }
            let path = (dir as NSString).appendingPathComponent(file)
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width == height else { continue }
            if best == nil || width > best!.size {
                best = (path, width)
            }
        }
        return best
    }
}
