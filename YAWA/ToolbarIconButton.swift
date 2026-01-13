import SwiftUI

/// Reusable toolbar icon button with optical sizing rules:
/// - Dense symbols (xmark, plus, etc.) render smaller so they match gear/star visually.
/// - Supports tint + optional background "pill" if you want it later.
struct ToolbarIconButton: View {
    enum Style {
        case plain                    // just the icon
        case pill(background: AnyShapeStyle = AnyShapeStyle(.ultraThinMaterial),
                  strokeOpacity: Double = 0.16,
                  fillOpacity: Double = 0.14)
    }

    let systemName: String
    var tint: Color = .white
    var style: Style = .plain
    var action: () -> Void

    init(
        _ systemName: String,
        tint: Color = .white,
        style: Style = .plain,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.tint = tint
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: metrics.size, weight: metrics.weight))
                // tiny optical nudge: dense icons feel high/large otherwise
                .baselineOffset(metrics.baselineOffset)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32) // consistent tap target
                .background(backgroundView)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Optical metrics

    private var metrics: (size: CGFloat, weight: Font.Weight, baselineOffset: CGFloat) {
        let name = systemName

        // Dense symbols that visually read bigger
        if name == "xmark" || name == "xmark.circle.fill" || name == "xmark.circle" {
            return (15, .medium, 0)   // ✅ makes it match gear/star
        }

        // Common "toolbar" icons you already use
        if name.contains("gearshape") || name.contains("star") {
            return (17, .semibold, 0)
        }

        // Default
        return (17, .semibold, 0)
    }

    // MARK: - Background styles

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .plain:
            EmptyView()

        case .pill(let background, let strokeOpacity, let fillOpacity):
            Capsule()
                .fill(background)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.75)
                )
                .overlay(
                    Capsule()
                        .fill(Color.white.opacity(fillOpacity))
                )
        }
    }

    private var accessibilityLabel: String {
        // You can improve this if you want
        systemName
    }
}