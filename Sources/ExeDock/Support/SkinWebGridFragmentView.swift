import SwiftUI
import WebKit

/// A grid-shaped *region* of real per-skin card markup, embedded inside a native SwiftUI layout -
/// Steam-style's own poster grid, Spotlight's own grid section. Both are structurally the exact
/// same shape Grid itself is (a wrapping grid of cards), so this reuses the real thing
/// (`window.PlaydockRenderGridFragment`, sharing skins.css/skins.js with `SkinWebGridView`) rather
/// than a second hand-ported approximation of the same cards. Minimal has no real `.card`/`.grid`
/// markup in the mockups at all (it's genuinely list-shaped), so it isn't offered through this -
/// callers keep using a native list for it.
struct SkinWebGridFragmentView: NSViewRepresentable {
    let skin: PlaydockSkin
    let entries: [SkinWebGridEntry]
    let isDark: Bool
    /// "a setting to hide labels" - see `SkinWebGridView.hideBadges`'s identical contract.
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
        context.coordinator.render(skin: skin, entries: entries, isDark: isDark, hideBadges: hideBadges)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onOpen: (String) -> Void
        weak var webView: WKWebView?
        private var isPageReady = false
        private var pending: (skin: PlaydockSkin, entries: [SkinWebGridEntry], isDark: Bool, hideBadges: Bool)?

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
                render(skin: pending.skin, entries: pending.entries, isDark: pending.isDark, hideBadges: pending.hideBadges)
            }
        }

        func render(skin: PlaydockSkin, entries: [SkinWebGridEntry], isDark: Bool, hideBadges: Bool) {
            guard isPageReady, let webView else {
                pending = (skin, entries, isDark, hideBadges)
                return
            }
            pending = nil
            guard let entriesJSON = jsonString(entries) else { return }
            guard let themeJSON = jsonString(WebTheme(theme: isDark ? "dark" : "light", hideBadges: hideBadges)) else { return }
            let js = "window.PlaydockRenderGridFragment && window.PlaydockRenderGridFragment(\(jsLiteral(skin.rawValue)), \(jsLiteral(entriesJSON)), \(jsLiteral(themeJSON)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private struct WebTheme: Encodable { let theme: String; let hideBadges: Bool }

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
