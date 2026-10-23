import AppKit
import MemopilaCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettings(monitor: model.monitor)
                .tabItem { Label("Capture", systemImage: "list.clipboard") }
        }
        .frame(width: 520)
        .padding()
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            LabeledContent("Open Memopila") {
                HStack {
                    Button(isRecording ? "Press a shortcut…" : model.shortcut.displayString) {
                        isRecording ? stopRecording() : startRecording()
                    }
                    if model.shortcut != .defaultShortcut {
                        Button("Reset") { model.setShortcut(.defaultShortcut) }
                    }
                }
            }
            if let error = model.hotKeyError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Text("The shortcut needs ⌘ or ⌃. While Memopila holds ⌥⌘V it replaces Finder's Move Item Here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear(perform: stopRecording)
    }

    /// The next key press with ⌘ or ⌃ becomes the shortcut; Esc cancels.
    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard let shortcut = HotKeyCenter.Shortcut(event: event) else { return }
        model.setShortcut(shortcut)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

private struct CaptureSettings: View {
    let monitor: ClipboardMonitor
    @State private var sizeLimit = Preferences.maxSinglePayloadMiB

    var body: some View {
        Form {
            LabeledContent("Clipboard access") {
                VStack(alignment: .trailing) {
                    Text(accessDescription)
                    if monitor.access == .needsEnable {
                        Button("Enable capture") { _ = monitor.enableCapture() }
                    } else if !monitor.access.allowsCapture {
                        Button("Check again") { monitor.refreshAccess() }
                    }
                }
            }
            Stepper(value: $sizeLimit, in: 4...256, step: 4) {
                LabeledContent("Largest item", value: "\(sizeLimit) MB")
            }
            .onChange(of: sizeLimit) { _, value in Preferences.maxSinglePayloadMiB = value }
            Text("Memopila keeps history on this Mac only. History is not encrypted, and apps that do not mark passwords as concealed are not filtered — use Pause or Skip Next Copy for secrets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessDescription: String {
        switch monitor.access {
        case .allowed: "Allowed"
        case .needsEnable: "Not enabled yet"
        case .ask: "Asks every time — choose Always Allow in System Settings"
        case .denied: "Denied in System Settings"
        }
    }
}
