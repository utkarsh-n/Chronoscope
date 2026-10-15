import SwiftUI

enum AtlasTheme {
    static let ink = Color(red: 0.035, green: 0.041, blue: 0.06)
    static let panel = Color(red: 0.065, green: 0.075, blue: 0.095)
    static let line = Color.white.opacity(0.09)
    static let lime = Color(red: 0.78, green: 0.96, blue: 0.20)
    static let cyan = Color(red: 0.23, green: 0.83, blue: 0.96)
    static let violet = Color(red: 0.69, green: 0.58, blue: 1)
    static func category(_ value: String) -> Color {
        let text = value.lowercased()
        if text.contains("war") || text.contains("battle") || text.contains("conflict") { return Color(red: 1, green: 0.48, blue: 0.43) }
        if text.contains("science") || text.contains("space") || text.contains("discovery") { return cyan }
        if text.contains("culture") || text.contains("art") || text.contains("film") { return violet }
        if text.contains("politic") || text.contains("revolution") { return lime }
        if text.contains("disaster") { return .orange }
        return Color(red: 0.28, green: 0.92, blue: 0.70)
    }
}

struct AtlasBadge: View {
    let text: String
    var color: Color = AtlasTheme.lime
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.18)))
    }
}

/// Glass belongs to the floating control layer. Content uses ordinary surfaces.
struct AtlasGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 24
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(AtlasTheme.panel, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(AtlasTheme.line))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func atlasGlass(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(AtlasGlassSurface(cornerRadius: cornerRadius, interactive: interactive))
    }
}
