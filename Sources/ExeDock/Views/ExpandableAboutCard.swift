import SwiftUI

/// Long store copy starts collapsed. "Show more" opens the rest; "Show less" puts it back.
/// Short blurbs stay as they are, with no button.
struct ExpandableAboutCard: View {
    let text: String
    let expanded: Bool
    var isFocused: Bool = false
    let onToggle: () -> Void

    private var canExpand: Bool {
        text.count > 280 || text.components(separatedBy: "\n").count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About This Game")
                .font(.headline)
                .foregroundStyle(.white)
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(4)
                .lineLimit(expanded || !canExpand ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canExpand {
                Button(expanded ? L("Show less") : L("Show more")) {
                    withAnimation(.easeInOut(duration: 0.2)) { onToggle() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusRing(isFocused)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
}
