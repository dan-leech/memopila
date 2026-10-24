import AppKit
import SwiftUI

/// Settings and Diagnostics (PLAN §8.7): AppKit windows that open only when asked and float above
/// other apps until closed — Memopila has no Dock icon and no ⌘Tab entry, so a window that fell
/// behind another app could not be found again. A closed window is released, with its SwiftUI views.
@MainActor
final class SecondaryWindows: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var settings: (window: NSWindow, tabs: NSTabViewController)?
    private var diagnostics: NSWindow?
    /// The tab to show when Settings opens again without asking for one.
    private var lastSettingsTab = 0
    /// The app that had the focus before the first window opened; it gets it back after the last closes.
    private var returnApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
    }

    var isAnyVisible: Bool {
        settings?.window.isVisible == true || diagnostics?.isVisible == true
    }

    /// `nil` keeps the tab that was open last.
    func showSettings(tab: SettingsTab?) {
        let settings = settings ?? makeSettings()
        self.settings = settings
        let index = tab.flatMap { SettingsTab.allCases.firstIndex(of: $0) } ?? lastSettingsTab
        settings.tabs.selectedTabViewItemIndex = index
        model.monitor.record("Settings window shown")
        present(settings.window)
    }

    func showDiagnostics() {
        let window = diagnostics ?? makeDiagnostics()
        diagnostics = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        if !isAnyVisible {
            returnApp = NSWorkspace.shared.frontmostApplication.flatMap {
                $0.bundleIdentifier == ClipboardMonitor.ownBundleID ? nil : $0
            } ?? model.previousApp
        }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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
        configure(window)
        return (window, tabs)
    }

    private func makeDiagnostics() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: DiagnosticsView(model: model)))
        window.title = String(localized: "Diagnostics")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 520))
        configure(window)
        return window
    }

    private func configure(_ window: NSWindow) {
        window.level = .floating
        // The window stays above other apps, so its tooltips must work while they are active.
        window.allowsToolTipsWhenApplicationIsInactive = true
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let isSettings = window === settings?.window
        let isDiagnostics = window === diagnostics
        if isSettings, let tabs = settings?.tabs {
            lastSettingsTab = tabs.selectedTabViewItemIndex
            model.monitor.record("Settings window closed")
        }
        // Release after AppKit has finished closing the window.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Unless it was opened again in the meantime.
            if isSettings, settings?.window.isVisible == false { settings = nil }
            if isDiagnostics, diagnostics?.isVisible == false { diagnostics = nil }
            guard !isAnyVisible else { return }
            if !model.secondaryWindowDidClose(), NSApp.isActive {
                // Nothing of Memopila is left on screen: the keyboard goes back to where it was.
                _ = returnApp?.activate()
            }
            returnApp = nil
        }
    }
}
