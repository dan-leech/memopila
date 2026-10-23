import SwiftUI

@main
struct MemopilaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon is an AppKit status item (StatusItemController): a click opens the panel.
        Settings {
            SettingsView(model: appDelegate.model)
        }

        Window("Diagnostics", id: DiagnosticsView.windowID) {
            DiagnosticsView(model: appDelegate.model)
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(model: model)
        model.start()
    }

    /// Dock icon click or relaunch while running: open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.panel.show()
        return false
    }
}
