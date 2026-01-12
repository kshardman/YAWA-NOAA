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
                .background {
                    Capsule()
                        // brighter fill so it pops
                        .fill(Color.white.opacity(0.18))
                        // add “glass” without a rim: a top highlight, not a border
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .scaleEffect(x: 0.92, y: 0.55, anchor: .top)
                                .blur(radius: 0.2)
                                .padding(.top, 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }
}
