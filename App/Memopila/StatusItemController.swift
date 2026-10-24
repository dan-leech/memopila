import AppKit
import Observation

/// The menu bar icon (PLAN §8.8). A click opens the panel, as in Pasta; the gear menu in the panel
/// holds the commands. Right-click or ⌃-click shows a short menu, so Quit and Resume stay reachable
/// even when the panel cannot open.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        // macOS remembers where the user ⌘-dragged the icon.
        item.autosaveName = "MemopilaStatusItem"
        item.isVisible = true
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(String(localized: "Memopila"))
        button.toolTip = String(localized: "Memopila: click to open, right-click for the menu")
        trackIcon()
    }

    /// For Diagnostics: a new icon lands left of the others and a full menu bar hides it under the notch.
    var placementDescription: String {
        guard let frame = item.button?.window?.frame else { return "not placed" }
        let screen = item.button?.window?.screen
        let hiddenByNotch = screen.map { screen in
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
            return frame.minX < right.minX && frame.maxX > left.maxX
        } ?? false
        return "visible \(item.isVisible), x \(Int(frame.minX))" + (hiddenByNotch ? ", under the notch" : "")
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            model.panel.toggle()
        }
    }

    /// Re-renders the icon whenever the capture state behind it changes.
    private func trackIcon() {
        let symbol = withObservationTracking {
            model.monitor.statusSymbol
        } onChange: {
            // The controller lives as long as the app, so a strong capture is fine.
            Task { @MainActor in self.trackIcon() }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: "Memopila"))
        image?.isTemplate = true
        item.button?.image = image
    }

    private func showMenu() {
        let monitor = model.monitor
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Open Memopila (\(model.settings.shortcut.displayString))")) { [model] in
            model.panel.show()
        })
        if monitor.access == .needsEnable {
            menu.addItem(ClosureMenuItem(String(localized: "Enable Capture")) { monitor.enableCapture() })
        }
        if monitor.storageError != nil {
            menu.addItem(ClosureMenuItem(String(localized: "Resume After Storage Error")) { monitor.resumeAfterStorageError() })
        }
        menu.addItem(.separator())
        if monitor.isPaused {
            menu.addItem(ClosureMenuItem(String(localized: "Resume Capture")) { monitor.resume() })
        } else {
            let pause = NSMenuItem(title: String(localized: "Pause"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(ClosureMenuItem(String(localized: "5 Minutes")) { monitor.pause(minutes: 5) })
            submenu.addItem(ClosureMenuItem(String(localized: "15 Minutes")) { monitor.pause(minutes: 15) })
            submenu.addItem(ClosureMenuItem(String(localized: "1 Hour")) { monitor.pause(minutes: 60) })
            submenu.addItem(ClosureMenuItem(String(localized: "Until I Resume")) { monitor.pauseIndefinitely() })
            pause.submenu = submenu
            menu.addItem(pause)
        }
        menu.addItem(ClosureMenuItem(monitor.skipArmed ? String(localized: "Cancel Skip") : String(localized: "Skip Next Copy")) {
            monitor.toggleSkip()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Settings…")) { [model] in model.openSettings() })
        // A tool for reporting problems: with ⌥ held, as in many Mac apps.
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(ClosureMenuItem(String(localized: "Diagnostics…")) { [model] in model.openDiagnostics() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Quit Memopila")) { NSApp.terminate(nil) })
        if let button = item.button {
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }
}

/// `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Menu actions arrive on the main thread.
    @MainActor @objc private func run() {
        handler()
    }
}
