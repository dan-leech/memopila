import AppKit
import SwiftUI

/// The record window, Settings and Diagnostics (PLAN §8.5, §8.7): AppKit windows that open only when
/// asked, replace the panel and float above other apps until closed — Memopila has no Dock icon and
/// no ⌘Tab entry, so a window that fell behind another app could not be found again. They are built
/// once and kept, and Settings is built shortly after launch, so they open at once, as in Pasta.
@MainActor
final class SecondaryWindows: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var settings: (window: NSWindow, tabs: NSTabViewController)?
    private var diagnostics: NSWindow?
    private var record: RecordWindow?
    /// The app that had the focus before the first window opened; it gets it back after the last closes.
    private var returnApp: NSRunningApplication?
    /// The record went to the clipboard: the window closes without bringing the panel back.
    private var keepsPanelClosed = false

    init(model: AppModel) {
        self.model = model
    }

    var isAnyVisible: Bool {
        settings?.window.isVisible == true || diagnostics?.isVisible == true || record?.isVisible == true
    }

    /// Builds the Settings window without showing it (a second after launch).
    func prepare() {
        if settings == nil { settings = makeSettings() }
    }

    // MARK: Record (§8.5)

    /// Shows the record in `model.itemState`. Opened to look at, nothing in it has the focus, so
    /// ↑ ↓ ← → move to other records; `focusText` puts the cursor in the text (⌘E).
    func showRecord(focusText: Bool) {
        let window = record ?? makeRecord()
        record = window
        present(window)
        guard !focusText else { return }
        window.makeFirstResponder(nil)
        // SwiftUI may still focus the title field once it lays the view out.
        Task { @MainActor in window.makeFirstResponder(nil) }
    }

    func closeRecord(returningToPanel: Bool) {
        guard let record, record.isVisible else { return }
        keepsPanelClosed = !returningToPanel
        record.close()
    }

    private func makeRecord() -> RecordWindow {
        let host = NSHostingController(rootView: RecordWindowContent(model: model))
        // The window keeps the size the user gave it, whatever the record shows.
        host.sizingOptions = []
        let window = RecordWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = host
        window.title = String(localized: "Edit Record")
        window.minSize = NSSize(width: 520, height: 360)
        window.keyHandler = { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard let self, let window else { return false }
                return RecordKeys.handle(event, in: window, model: self.model)
            }
        }
        configure(window, frameName: "MemopilaRecordWindow")
        return window
    }

    // MARK: Settings and Diagnostics (§8.7)

    /// `nil` keeps the tab that was open last.
    func showSettings(tab: SettingsTab?) {
        let settings = settings ?? makeSettings()
        self.settings = settings
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            settings.tabs.selectedTabViewItemIndex = index
        }
        model.monitor.record("Settings window shown")
        present(settings.window)
    }

    func showDiagnostics() {
        let window = diagnostics ?? makeDiagnostics()
        diagnostics = window
        present(window)
    }

    private func makeSettings() -> (window: NSWindow, tabs: NSTabViewController) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let page = NSHostingController(rootView: SettingsPage(model: model, tab: tab))
            // The window shows the selected tab's name, as System Settings panes do.
            page.title = tab.title
            page.preferredContentSize = SettingsPage.size
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        configure(window, frameName: "MemopilaSettingsWindow")
        return (window, tabs)
    }

    private func makeDiagnostics() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: DiagnosticsView(model: model)))
        window.title = String(localized: "Diagnostics")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 520))
        configure(window, frameName: "MemopilaDiagnosticsWindow")
        return window
    }

    // MARK: Shared

    private func present(_ window: NSWindow) {
        if !isAnyVisible {
            returnApp = NSWorkspace.shared.frontmostApplication.flatMap {
                $0.bundleIdentifier == ClipboardMonitor.ownBundleID ? nil : $0
            } ?? model.previousApp
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Floating, kept after closing, and back where the user left it.
    private func configure(_ window: NSWindow, frameName: String) {
        window.level = .floating
        // The window stays above other apps, so its tooltips must work while they are active.
        window.allowsToolTipsWhenApplicationIsInactive = true
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
    }

    // MARK: NSWindowDelegate

    /// The close button or ⌘W on a record with unsaved changes asks first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === record else { return true }
        return model.recordMayClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === record { model.recordWindowDidClose() }
        if window === settings?.window { model.monitor.record("Settings window closed") }
        let returningToPanel = !keepsPanelClosed
        keepsPanelClosed = false
        // After AppKit has finished closing the window, so it no longer counts as visible.
        Task { @MainActor [weak self] in
            guard let self, !isAnyVisible else { return }
            if !model.secondaryWindowDidClose(returningToPanel: returningToPanel), NSApp.isActive {
                // Nothing of Memopila is left on screen: the keyboard goes back to where it was.
                _ = returnApp?.activate()
            }
            returnApp = nil
        }
    }
}
