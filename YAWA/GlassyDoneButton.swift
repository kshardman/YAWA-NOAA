import SwiftUI

struct GlassyDoneButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String = "Done", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    ZStack {
                        // Base glass
                        Capsule()
                            .fill(.ultraThinMaterial)

                        // Subtle lift so it doesn’t go dark on deep blues
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
                .shadow(
                    color: .black.opacity(0.20),
                    radius: 10,
                    y: 4
                )
        }
        .buttonStyle(.plain)
    }
}