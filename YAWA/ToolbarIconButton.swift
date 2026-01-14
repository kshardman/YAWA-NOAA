//
//  ToolbarIconButton.swift
//  YAWA
//
//  Created by Keith Sharman on 1/13/26.
//


import SwiftUI

struct ToolbarIconButton: View {
    enum Style {
        case pill
        case plain
    }

    let systemName: String
    var tint: Color = .white
    var style: Style = .pill
    var action: () -> Void

    init(
        _ systemName: String,
        tint: Color = .white,
        style: Style = .pill,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.tint = tint
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemNameToRender)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)     // match star/gear tap target
                .background(backgroundView)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // Force plain xmark so you don't double-circle it accidentally
    private var systemNameToRender: String {
        if systemName == "xmark.circle" || systemName == "xmark.circle.fill" {
            return "xmark"
        }
        return systemName
    }

    private var iconSize: CGFloat {
        switch systemName {
        case "xmark", "xmark.circle", "xmark.circle.fill":
            return 14   // dense symbol → smaller
        case "star.circle.fill", "gearshape.fill":
            return 17   // your baseline
        default:
            return 17
        }
    }

    private var iconWeight: Font.Weight {
        switch systemName {
        case "xmark", "xmark.circle", "xmark.circle.fill":
            return .semibold
        default:
            return .semibold
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .plain:
            EmptyView()

        case .pill:
            Circle()
                .fill(Color.white.opacity(0.10))                 // consistent “glass”
                .overlay(
                    Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                )
        }
    }

    private var accessibilityLabel: String {
        systemNameToRender
    }
}
