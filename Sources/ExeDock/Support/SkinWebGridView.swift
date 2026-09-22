import SwiftUI
import WebKit

/// One real game/entry as handed to the WebView's own renderer - a plain, JSON-encodable snapshot,
/// not a live reference, since the page re-renders from a fresh JSON blob every time anything
/// relevant changes rather than trying to keep a persistent DOM in sync with SwiftUI state.
struct SkinWebGridEntry: Encodable, Equatable {
    let id: String
    let title: String
    let genre: String
    let desc: String
    /// A `data:image/jpeg;base64,...` URI, or `nil` for "no art yet/at all" - the page falls back to
    /// its own deterministic placeholder gradient for `nil`, exactly like every native SwiftUI
    /// layout in this app already does.
    let art: String?
    let custom: Bool
    /// A game found in the real, separate macOS Steam client's own library (`SteamGameSource
    /// .nativeMac`) - shown with a real "Mac" badge, the same way a custom game gets "Custom".
    let mac: Bool
    /// A game running through Playdock's own Windows Steam bottle (`SteamGameSource.wineBottle`) -
    /// the real majority case, previously the only one with no badge of its own at all. Defaulted
    /// so this field's own addition stays independently buildable - the one real call site
    /// (`GameModeView.webGridEntries`) starts actually setting it in a separate, later piece.
    let windows: Bool = false
    let running: Bool
    let size: String?
    let hours: String?
}

/// The real per-skin HTML/CSS from `ten-playdocks.html`, rendered by an actual `WKWebView` instead
/// of re-approximated in SwiftUI - several rounds of hand-porting individual
/// tokens (background, radius, border, shadow, font) still didn't read as the same design the
/// mockups showed. This renders the literal mockup markup/CSS, populated with this library's real
/// games, real fetched artwork, and real running/custom state - genuinely pixel-identical instead of
/// approximated, for every one of the ten skins. Search lives inside the page itself now (each
/// skin's own topbar search field, exactly as authored, made real) rather than a native SwiftUI
/// field competing with it for the same real estate.
struct SkinWebGridView: NSViewRepresentable {
    let skin: PlaydockSkin
    let entries: [SkinWebGridEntry]
    let userName: String
    let isDark: Bool
    /// The card a controller's D-pad currently has focused, by index into `entries` - `nil` while
    /// no controller is connected or focus is elsewhere (a toolbar button, the floating Steam
    /// icon). The page has no idea a controller exists at all; this just tells it which card to
    /// draw the ring around, via `window.PlaydockSetFocus` (see that function's own doc comment).
    var focusedIndex: Int?
    /// "a setting to hide labels" - hides every Mac/Custom/Windows badge in the real page via one
    /// shared `[data-hide-badges]` CSS rule (see skins.css), not a per-skin toggle. Defaulted so
    /// this plumbing stays independently buildable before anything actually sets it non-default.
    var hideBadges: Bool = false
    let onOpen: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "playdock")
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent instead of the default opaque white, so the one brief instant before the
        // page's own (opaque, skin-colored) content paints shows this app's own SkinBackground
        // underneath rather than a stark white flash.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        context.coordinator.webView = webView
        if let resourceURL = Bundle.main.resourceURL {
            let templateDir = resourceURL.appendingPathComponent("SkinTemplate")
            let indexURL = templateDir.appendingPathComponent("index.html")
            webView.loadFileURL(indexURL, allowingReadAccessTo: templateDir)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.render(skin: skin, entries: entries, userName: userName, isDark: isDark, hideBadges: hideBadges)
        context.coordinator.setFocus(focusedIndex)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onOpen: (String) -> Void
        weak var webView: WKWebView?
        private var isPageReady = false
        private var pending: (skin: PlaydockSkin, entries: [SkinWebGridEntry], userName: String, isDark: Bool, hideBadges: Bool)?

        init(onOpen: @escaping (String) -> Void) {
            self.onOpen = onOpen
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
            let handler = onOpen
            DispatchQueue.main.async { handler(id) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            if let pending {
                render(skin: pending.skin, entries: pending.entries, userName: pending.userName, isDark: pending.isDark, hideBadges: pending.hideBadges)
            }
        }

        func render(skin: PlaydockSkin, entries: [SkinWebGridEntry], userName: String, isDark: Bool, hideBadges: Bool) {
            guard isPageReady, let webView else {
                pending = (skin, entries, userName, isDark, hideBadges)
                return
            }
            pending = nil
            guard let entriesJSON = jsonString(entries) else { return }
            let meta = WebMeta(user: userName, theme: isDark ? "dark" : "light", hideBadges: hideBadges)
            guard let metaJSON = jsonString(meta) else { return }
            let js = "window.PlaydockRender && window.PlaydockRender(\(jsLiteral(skin.rawValue)), \(jsLiteral(entriesJSON)), \(jsLiteral(metaJSON)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// `index` is `nil` when nothing should be highlighted right now (no controller, or focus
        /// is on a native control outside the grid) - only actually calls into the page once it's
        /// ready, same deferred-until-loaded contract `render(skin:entries:userName:isDark:)` has.
        func setFocus(_ index: Int?) {
            guard isPageReady, let webView else { return }
            let arg = index.map(String.init) ?? "null"
            webView.evaluateJavaScript("window.PlaydockSetFocus && window.PlaydockSetFocus(\(arg));", completionHandler: nil)
        }

        private struct WebMeta: Encodable { let user: String; let theme: String; let hideBadges: Bool }

        private func jsonString<T: Encodable>(_ value: T) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        /// A JSON string literal (not raw interpolation) so any quote/backslash/newline in a game's
        /// own title or description can never break out of the surrounding JS call.
        private func jsLiteral(_ s: String) -> String {
            guard let data = try? JSONEncoder().encode(s), let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
            return literal
        }
    }
}

/// Building a `SkinWebGridEntry` from real app data - shared by both the Steam and custom-game
/// cases, and the one place that turns a locally-cached `NSImage` into the compact base64
/// `data:` URI the sandboxed page can actually load (a `file://` reference would need explicit read
/// access wired through `WKWebView`'s own sandbox for every distinct art location on disk - Steam's
/// cache, a custom game's own folder, wherever a user picked - so inlining the already-downsampled
/// bytes directly is the simpler, equally fast, and more robust choice for a handful of card images).
enum SkinWebArt {
    /// Re-encoding the same already-decoded image to base64 JPEG on every SwiftUI re-render (this
    /// gets recomputed each time `webGridEntries` is - which is often, since it depends on live
    /// running-state) would be real, pointless repeated CPU work; cached by path exactly like
    /// `LocalImageCache` caches the decode itself, one layer up.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 200
        return cache
    }()

    static func dataURI(forImagePath path: String?) -> String? {
        guard let path else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        guard let image = LocalImageCache.image(atPath: path) else { return nil }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        let uri = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        cache.setObject(uri as NSString, forKey: key)
        return uri
    }
}
