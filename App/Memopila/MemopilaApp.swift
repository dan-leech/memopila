import SwiftUI

@main
struct MemopilaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.monitor.statusSymbol)
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }

        Window("Diagnostics", id: DiagnosticsView.windowID) {
            DiagnosticsView(monitor: appDelegate.model.monitor)
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
}
