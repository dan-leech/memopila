import AppKit
import SwiftUI

/// Non-activating toast when History / Record / Stack are not showing `ToastView`.
@MainActor
final class FloatingToastHost {
    static let shared = FloatingToastHost()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func present(_ message: String, isError: Bool = false) {
        // Prefer in-window toasts when a Memopila surface is already visible.
        if NSApp.windows.contains(where: { $0.isVisible && ($0 is RecordWindow || $0 is StackWindow || $0 is HistoryPanel) }) {
            return
        }

        dismissTask?.cancel()
        let hosting = NSHostingView(rootView: FloatingToastLabel(message: message, isError: isError))
        hosting.frame.size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 48
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
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
