import AppKit
import MemopilaServices
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
        super.init()
        // Opening System Settings, Finder or a browser from a floating window: the window steps down
        // until Memopila is active again, so what it opened is not hidden under it (review finding).
        let center = NotificationCenter.default
        _ = center.addObserver(forName: External.willOpen, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloating(false) }
        }
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloating(true) }
        }
    }

    private func setFloating(_ floating: Bool) {
        let level: NSWindow.Level = floating ? .floating : .normal
        for window in [settings?.window, diagnostics, record].compactMap({ $0 }) where window.level != level {
            window.level = level
        }
    }

    /// The Settings window, for views that refresh when it comes forward again.
    static let settingsIdentifier = NSUserInterfaceItemIdentifier("MemopilaSettingsWindow")

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
        // The dot in the close button follows the record's unsaved text.
        window.isDocumentEdited = model.itemState?.isDirty ?? false
        if let card = model.itemState?.card { updateRecordTitle(card) }
        present(window)
        guard !focusText else { return }
        window.makeFirstResponder(nil)
        // SwiftUI may still focus the title field once it lays the view out.
        Task { @MainActor in window.makeFirstResponder(nil) }
    }

    /// The record's name and where it came from, so the window says what it shows.
    func updateRecordTitle(_ card: HistoryCard) {
        guard let record else { return }
        record.title = card.customTitle ?? card.displayType.title
        record.subtitle = card.sourceAppName ?? ""
    }

    func closeRecord(returningToPanel: Bool) {
        guard let record, record.isVisible else { return }
        keepsPanelClosed = !returningToPanel
        record.close()
    }

    enum UnsavedChoice {
        case save, discard, cancel
    }

    /// *Do you want to save the changes?* as the standard sheet on the record window: ↩ saves, Esc
    /// cancels, ⌘D does not save.
    func askToSaveRecord(_ answer: @escaping @MainActor (UnsavedChoice) -> Void) {
        guard let record, record.isVisible else { return answer(.cancel) }
        // Already asking (a second Esc or ⌘W while the sheet is up), or another sheet is open:
        // the answer is Cancel, so whoever asked is never left waiting (⌘Q).
        guard record.attachedSheet == nil else { return answer(.cancel) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes to this record?")
        alert.informativeText = String(localized: "Your changes to the text will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: String(localized: "Don’t Save"))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: record) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: answer(.save)
                case .alertThirdButtonReturn: answer(.discard)
                default: answer(.cancel)
                }
            }
        }
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
        // Setting the controller sized the window to its view, which has no size of its own: 0 × 0,
        // an invisible window that still counted as open (first-run bug).
        window.setContentSize(Self.recordSize)
        window.title = String(localized: "Edit Record")
        window.minSize = NSSize(width: 640, height: 400)
        window.keyHandler = { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard let self, let window else { return false }
                return RecordKeys.handle(event, in: window, model: self.model)
            }
        }
        configure(window, frameName: "MemopilaRecordWindow", defaultSize: Self.recordSize)
        return window
    }

    private static let recordSize = NSSize(width: 860, height: 560)

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
        window.identifier = Self.settingsIdentifier
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
        configure(window, frameName: "MemopilaDiagnosticsWindow", defaultSize: NSSize(width: 640, height: 520))
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

    /// Floating, kept after closing, and back where the user left it — unless that frame is too
    /// small or on no screen any more, then centered at `defaultSize`.
    private func configure(_ window: NSWindow, frameName: String, defaultSize: NSSize? = nil) {
        window.level = .floating
        // The window stays above other apps, so its tooltips must work while they are active.
        window.allowsToolTipsWhenApplicationIsInactive = true
        // Over a full-screen app it opens in that Space instead of switching to a desktop
        // (review finding).
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.isReleasedWhenClosed = false
        window.delegate = self
        let restored = window.setFrameUsingName(frameName)
        let frame = window.frame
        let usable = frame.width >= max(window.minSize.width, 100) && frame.height >= max(window.minSize.height, 100)
            && NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !restored || !usable {
            if let defaultSize { window.setContentSize(defaultSize) }
            window.center()
        }
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

/// Opens something in another app — System Settings, Finder, a browser, Preview — announcing it
/// first, so Memopila's floating windows step down below it.
@MainActor
enum External {
    static let willOpen = Notification.Name("MemopilaWillOpenExternally")

    static func announce() {
        NotificationCenter.default.post(name: willOpen, object: nil)
    }

    static func open(_ url: URL) {
        announce()
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ urls: [URL]) {
        announce()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
