import AppKit
import SwiftUI

/// Non-activating toast when History / Record / Stack are not showing `ToastView`.
@MainActor
final class FloatingToastHost {
    static let shared = FloatingToastHost()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// - Parameter anchor: selection/caret rect in AppKit screen coords; toast sits above when
    ///   there is room, otherwise below. `nil` → bottom-center of the main screen.
    /// - Parameter force: layout-convert near the selection must float even if History is open
    ///   (in-window toast would appear at the panel bottom, not by the text).
    func present(
        _ message: String,
        isError: Bool = false,
        anchor: CGRect? = nil,
        force: Bool = false
    ) {
        // Prefer in-window toasts when a Memopila surface is already visible — unless callers
        // need screen anchoring (global layout convert).
        if !force,
           NSApp.windows.contains(where: { $0.isVisible && ($0 is RecordWindow || $0 is StackWindow || $0 is HistoryPanel) }) {
            return
        }

        dismissTask?.cancel()
        let hosting = NSHostingView(rootView: FloatingToastLabel(message: message, isError: isError))
        hosting.frame.size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        panel.setFrameOrigin(origin(for: panel.frame.size, anchor: anchor))
        panel.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func origin(for size: CGSize, anchor: CGRect?) -> NSPoint {
        let gap: CGFloat = 8
        let margin: CGFloat = 8

        if let anchor, !anchor.isNull, !anchor.isInfinite,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let spaceAbove = visible.maxY - anchor.maxY
            let spaceBelow = anchor.minY - visible.minY
            let needs = size.height + gap
            let placeAbove = spaceAbove >= needs || spaceAbove >= spaceBelow

            var x = anchor.midX - size.width / 2
            x = min(max(x, visible.minX + margin), max(visible.minX + margin, visible.maxX - size.width - margin))

            let y: CGFloat
            if placeAbove {
                y = min(anchor.maxY + gap, visible.maxY - size.height - margin)
            } else {
                y = max(anchor.minY - gap - size.height, visible.minY + margin)
            }
            return NSPoint(x: x, y: y)
        }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48)
        }
        return .zero
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct FloatingToastLabel: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "keyboard")
                .foregroundStyle(isError ? Color.orange : Color.accentColor)
            Text(message)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.thickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}
