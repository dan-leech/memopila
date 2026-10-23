import SwiftUI

@main
struct MemopilaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.monitor.statusSymbol)
                .accessibilityLabel(Text("Memopila"))
        }

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Dock icon click or relaunch while running: open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.panel.show()
        return false
    }
}
