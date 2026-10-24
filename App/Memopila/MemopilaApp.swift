import Carbon
import SwiftUI

@main
struct MemopilaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon is an AppKit status item (StatusItemController): a click opens the panel.
        Settings {
            SettingsView(model: appDelegate.model)
        }
        // No window comes back by itself at launch; the panel is the only thing that opens then.
        .restorationBehavior(.disabled)

        Window("Diagnostics", id: DiagnosticsView.windowID) {
            DiagnosticsView(model: appDelegate.model)
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.statusItemDescription = { [weak statusItem] in statusItem?.placementDescription ?? "—" }
        model.start()
        // Opened by hand (Finder, Xcode): show the panel, so the app is visibly running even when the
        // menu bar icon is hidden. Not at login.
        if !Self.launchedAsLoginItem { model.panel.show() }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Dock icon click or relaunch while running: open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.panel.show()
        return false
    }
}
