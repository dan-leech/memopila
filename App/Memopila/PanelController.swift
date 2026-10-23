import AppKit
import SwiftUI

/// Non-activating panel: the previous app stays frontmost while the panel takes keyboard input (PLAN §8.1).
final class HistoryPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 490),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 360)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var panel: HistoryPanel?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.panelWillShow()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Esc: clear a non-empty search, otherwise close (§3.4).
    func cancel() {
        if model.searchText.isEmpty { close() } else { model.searchText = "" }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !model.isPinned { close() }
    }

    private func makePanel() -> HistoryPanel {
        let panel = HistoryPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))
        return panel
    }

    /// Centered on the screen with the mouse pointer.
    private func position(_ panel: HistoryPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        panel.setFrame(frame, display: false)
    }
}
