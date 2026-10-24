import AppKit
import Carbon

/// AppKit app lifecycle: every window opens only when Memopila asks for it. With SwiftUI scenes the
/// system decided when to show the Settings scene — it appeared at launch and after the panel
/// closed, with no way to suppress it (PLAN §8.7).
@main
@MainActor
enum MemopilaMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no window most of the time: the system must not quit it for that.
        ProcessInfo.processInfo.disableAutomaticTermination("Memopila watches the clipboard")
        NSApp.mainMenu = MainMenu.make(model: model)
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.statusItemDescription = { [weak statusItem] in statusItem?.placementDescription ?? "—" }
        model.start()
        // Opened by hand (Finder, Xcode): show the panel, so the app is visibly running even when the
        // menu bar icon is hidden. Not at login.
        if !Self.launchedAsLoginItem { model.panel.show() }
        // Settings opens at once later on, as in Pasta.
        Task { [model] in
            try? await Task.sleep(for: .seconds(1))
            model.windows.prepare()
        }
    }

    /// ⌘Q asks about unsaved text and carries out a delete waiting for Undo (review findings).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareToQuit { quit in sender.reply(toApplicationShouldTerminate: quit) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.monitor.record("quitting")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Opened again while running (Finder, Spotlight): open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.panel.show()
        return false
    }
}

/// Memopila has no menu bar of its own (it is an agent app), but the main menu still delivers
/// ⌘C, ⌘V, ⌘Z… to text fields in Settings, ⌘W to close a window and ⌘Q to quit.
@MainActor
enum MainMenu {
    static func make(model: AppModel) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(ClosureMenuItem(String(localized: "About Memopila")) { model.openSettings(.about) })
        app.addItem(.separator())
        app.addItem(ClosureMenuItem(String(localized: "Settings…"), key: ",") { model.openSettings() })
        app.addItem(.separator())
        app.addItem(item(String(localized: "Quit Memopila"), #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(submenu(app, title: "Memopila"))

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        edit.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        main.addItem(submenu(edit, title: edit.title))

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"))
        main.addItem(submenu(window, title: window.title))
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
