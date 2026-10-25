import AppKit
import SwiftUI

/// Soft rounded hover, as toolbar icons in Finder and Preview — `.borderless` has none.
/// Also used for card action icons and the ⋯ menu (`recolorsLabel: false` keeps a custom tint).
struct ToolbarIconStyle: ButtonStyle {
    var emphasized = false
    /// When false, the label keeps its own `foregroundStyle` (favorites heart, card icons).
    var recolorsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconStyleBody(configuration: configuration, emphasized: emphasized, recolorsLabel: recolorsLabel)
    }
}

private struct ToolbarIconStyleBody: View {
    let configuration: ButtonStyle.Configuration
    var emphasized = false
    var recolorsLabel = true
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Group {
            if recolorsLabel {
                configuration.label.foregroundStyle(emphasized ? Color.accentColor : Color.primary)
            } else {
                configuration.label
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(fill)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        // Disabled controls must not look interactive (nav chevrons at the ends, etc.).
        guard isEnabled else {
            return emphasized ? Color.accentColor.opacity(0.15) : .clear
        }
        if emphasized { return Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.15) }
        if configuration.isPressed { return Color.primary.opacity(0.14) }
        if hovering { return Color.primary.opacity(0.08) }
        return .clear
    }
}

/// Icon-only button for floating windows: hover chrome + AppKit tooltip. Prefer this over a raw
/// `.borderless` `Button` with `.help` — SwiftUI help often never appears while floating.
struct HoverIconButton: View {
    var systemImage: String
    var help: String
    var emphasized = false
    var recolorsLabel = true
    var width: CGFloat = 26
    var height: CGFloat = 22
    var font: Font? = nil
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            image
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        // Own tint → do not let the style repaint the symbol (favorites heart, etc.).
        .buttonStyle(ToolbarIconStyle(emphasized: emphasized, recolorsLabel: tint == nil && recolorsLabel))
        .floatingHelp(help)
        .accessibilityLabel(Text(help))
    }

    @ViewBuilder
    private var image: some View {
        if let tint {
            Image(systemName: systemImage).font(font).foregroundStyle(tint)
        } else {
            Image(systemName: systemImage).font(font)
        }
    }
}

/// Icon-only menu trigger with the same chrome as `HoverIconButton`.
struct HoverIconMenu<Content: View>: View {
    var systemImage: String
    var help: String
    var emphasized = false
    var width: CGFloat = 26
    var height: CGFloat = 22
    var font: Font? = nil
    var tint: Color = .secondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(tint)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ToolbarIconStyle(emphasized: emphasized, recolorsLabel: false))
        .fixedSize()
        .floatingHelp(help)
        .accessibilityLabel(Text(help))
    }
}

/// SwiftUI `.help` often never appears in floating windows; AppKit `toolTip` does, with
/// `allowsToolTipsWhenApplicationIsInactive` on the panel and record window.
struct AppKitToolTip: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        view.text = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Anchor)?.text = text
    }

    private final class Anchor: NSView {
        var text = "" {
            didSet { apply() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        private func apply() {
            let value = text.isEmpty ? nil : text
            toolTip = value
            // The SwiftUI host that wraps the control: tooltips follow that frame.
            superview?.toolTip = value
        }
    }
}

extension View {
    func appKitToolTip(_ text: String) -> some View {
        background(AppKitToolTip(text: text))
    }

    /// Use instead of bare `.help` on controls in the panel, record window or Settings: SwiftUI
    /// help often never appears while those windows float above other apps.
    func floatingHelp(_ text: String) -> some View {
        help(text).appKitToolTip(text)
    }
}
