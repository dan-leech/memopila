import AppKit
import SwiftUI

/// Keeps a Memopila window above other apps until it is closed: Memopila has no Dock icon and no
/// ⌘Tab entry, so a Settings window that fell behind another app could not be found again (PLAN §8.1).
/// It only sets the level; showing the window is up to whoever opens it. (SwiftUI builds the Settings
/// window before it is shown, so ordering it front here opened Settings at launch.)
struct FloatingWindow: NSViewRepresentable {
    /// The window closed, for example to bring back the panel it replaced.
    var onClose: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = FloatingWindowView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FloatingWindowView)?.onClose = onClose
    }
}

private final class FloatingWindowView: NSView {
    var onClose: (@MainActor () -> Void)?
    private var closeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }
}
