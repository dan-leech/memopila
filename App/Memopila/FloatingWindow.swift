import AppKit
import SwiftUI

/// Keeps a Memopila window above other apps until it is closed. Memopila has no Dock icon and no
/// ⌘Tab entry, so a Settings window that fell behind another app could not be found again (PLAN §8.1).
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloatingWindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FloatingWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
    }
}
