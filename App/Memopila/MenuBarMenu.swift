import AppKit
import SwiftUI

/// Menu bar menu (PLAN §8.8).
struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var monitor: ClipboardMonitor { model.monitor }

    var body: some View {
        Button("Open Memopila (\(model.settings.shortcut.displayString))") { model.panel.show() }
        if monitor.access == .needsEnable {
            Button("Enable Capture") { monitor.enableCapture() }
        }
        if monitor.storageError != nil {
            Button("Resume After Storage Error") { monitor.resumeAfterStorageError() }
        }
        Divider()
        if monitor.isPaused {
            if let until = monitor.pausedUntil {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
            }
            Button("Resume Capture") { monitor.resume() }
        } else {
            Menu("Pause") {
                Button("5 Minutes") { monitor.pause(minutes: 5) }
                Button("15 Minutes") { monitor.pause(minutes: 15) }
                Button("1 Hour") { monitor.pause(minutes: 60) }
                Button("Until I Resume") { monitor.pauseIndefinitely() }
            }
        }
        if monitor.skipArmed {
            Button("Cancel Skip") { monitor.toggleSkip() }
        } else {
            Button("Skip Next Copy") { monitor.toggleSkip() }
        }
        Divider()
        Button("Settings…") {
            model.openSettingsAction = openSettings
            model.openSettings()
        }
        .keyboardShortcut(",")
        Button("Diagnostics…") {
            model.panel.close()
            NSApp.activate()
            openWindow(id: DiagnosticsView.windowID)
        }
        Divider()
        Button("Quit Memopila") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
