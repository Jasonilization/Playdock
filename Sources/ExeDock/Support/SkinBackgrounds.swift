import SwiftUI

/// The real background treatment behind the whole dashboard, one real SwiftUI view per skin -
/// ported directly from that skin's own HTML preview's `body` background (the same gradients,
/// grids, and textures, not an approximation of them). Color/corner-radius tokens alone were
/// never going to get a skin looking like its own preview; the background is most of what
/// actually reads as a different visual world.
struct SkinBackground: View {
    let skin: PlaydockSkin
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        switch skin {
        case .luxury:
            Color(nsColor: .windowBackgroundColor)
        case .brutalist:
            // Dark ground lifted from a crushed near-black (#171410) to a readable warm charcoal
            // (#1b1712) - paired with the retuned red accent and the no-longer-pure-white hard
            // shadows, this is the "colour scheme looks very bad" fix for Brutalist's dark mode.
            isDark ? Color(red: 0.106, green: 0.090, blue: 0.071) : Color(red: 0.996, green: 0.965, blue: 0.894)
        case .cyber:
            ZStack {
                isDark ? Color(red: 0.02, green: 0.027, blue: 0.039) : Color(red: 0.933, green: 0.961, blue: 0.969)
                GridPattern(spacing: 28, color: isDark ? Color(red: 0, green: 0.94, blue: 1).opacity(0.06) : Color(red: 0, green: 0.573, blue: 0.643).opacity(0.07))
            }
        case .soft:
            isDark ? Color(red: 0.169, green: 0.176, blue: 0.227) : Color(red: 0.90, green: 0.905, blue: 0.933)
        case .pixel:
            ZStack {
                isDark ? Color(red: 0.102, green: 0.11, blue: 0.173) : Color(red: 0.918, green: 0.945, blue: 0.984)
                DotPattern(spacing: 24, dotSize: 3, color: isDark ? Color(red: 0.161, green: 0.212, blue: 0.435) : Color(red: 0.78, green: 0.839, blue: 0.937))
            }
        case .minimal:
            Color(nsColor: .textBackgroundColor)
        }
    }
}

/// A faint repeating grid of hairlines, matching the Terminal preview's CSS background-image
/// grid.
private struct GridPattern: View {
    let spacing: CGFloat
    let color: Color
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color), lineWidth: 1)
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 1)
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// A repeating dot grid, matching the Pixel preview's CSS radial-gradient dot background.
private struct DotPattern: View {
    let spacing: CGFloat
    let dotSize: CGFloat
    let color: Color
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

