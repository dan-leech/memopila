import AppKit
import SwiftUI

/// Menu bar menu (PLAN §8.8).
struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var monitor: ClipboardMonitor { model.monitor }

    var body: some View {
        Button("Open Memopila (\(model.shortcut.displayString))") { model.panel.show() }
        if monitor.access == .needsEnable {
            Button("Enable Capture") { _ = monitor.enableCapture() }
        }
        Divider()
        if monitor.isPaused {
            Button("Resume Capture") { monitor.resume() }
        } else {
            Menu("Pause") {
                Button("5 Minutes") { monitor.pause(minutes: 5) }
                Button("15 Minutes") { monitor.pause(minutes: 15) }
                Button("1 Hour") { monitor.pause(minutes: 60) }
                Button("Until I Resume") { monitor.pauseIndefinitely() }
            }
        }
        Button(monitor.skipArmed ? "Cancel Skip" : "Skip Next Copy") { monitor.toggleSkip() }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Diagnostics…") {
            NSApp.activate()
            openWindow(id: DiagnosticsView.windowID)
        }
        Divider()
        Button("Quit Memopila") { NSApp.terminate(nil) }
    }
}
