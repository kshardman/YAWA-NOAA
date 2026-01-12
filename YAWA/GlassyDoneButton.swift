import SwiftUI

struct GlassyDoneButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String = "Done", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(YAWATheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.12))   // ✅ readable on dark + blue
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1) // ✅ crisp edge
            )
            .contentShape(Capsule())
            .buttonStyle(.plain)
    }
}
