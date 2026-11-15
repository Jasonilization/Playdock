import SwiftUI

/// Long store copy starts collapsed. "Show more" opens the rest; "Show less" puts it back.
/// Short blurbs stay as they are, with no button.
struct ExpandableAboutCard: View {
    let text: String
    let expanded: Bool
    var isFocused: Bool = false
    let onToggle: () -> Void

    private var readable: String { SteamStoreInfo.readableParagraphs(from: text) }

    private var canExpand: Bool {
        readable.count > 280 || readable.components(separatedBy: "\n").count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About This Game")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            Text(readable)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(expanded || !canExpand ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)
            if canExpand {
                Button {
                    withAnimation(PlaydockMotion.chrome) { onToggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(expanded ? L("Show less") : L("Show more"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .focusRing(isFocused)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// Lays children out left to right and wraps onto the next line when they don't fit.
/// Used on the game page so genre and feature tags don't crush into one row.
struct DetailWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640
        let rows = rows(in: width, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                item.view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current: [Row.Item] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !current.isEmpty {
                rows.append(Row(items: current, height: rowHeight))
                current = []
                x = 0
                rowHeight = 0
            }
            current.append(Row.Item(view: view, size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        if !current.isEmpty {
            rows.append(Row(items: current, height: rowHeight))
        }
        return rows
    }

    private struct Row {
        struct Item {
            let view: LayoutSubview
            let size: CGSize
        }
        let items: [Item]
        let height: CGFloat
    }
}
