import AppKit
import SwiftUI

/// Phase 1 spike instrument (PLAN §3.1 spike questions): shows the access policy and capture state,
/// and lets you try single pasteboard calls to see which ones raise the system alert.
struct DiagnosticsView: View {
    static let windowID = "diagnostics"

    let monitor: ClipboardMonitor
    @State private var probes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("macOS build", PasteboardAccess.osBuild)
                row("accessBehavior", PasteboardAccess.behaviorName)
                row("Capture access", "\(monitor.access)")
                row("Silent default verified on", Preferences.silentDefaultVerifiedOSBuild ?? "—")
                row("changeCount handled", monitor.coordinator.lastHandledChangeCount.map(String.init) ?? "—")
                row("Reading / destructive", "\(monitor.coordinator.isCapturing) / \(monitor.coordinator.destructiveInProgress)")
                row("Token / skip armed", "\(monitor.coordinator.token.map(String.init) ?? "—") / \(monitor.coordinator.skipArmed)")
                row("Paused", monitor.isPaused ? (monitor.pausedUntil?.formatted() ?? "until resumed") : "no")
                row("History entries", "\(monitor.history.count)")
            }
            .font(.system(.callout, design: .monospaced))

            GroupBox("Probes — each runs one pasteboard call and reports accessBehavior before and after") {
                HStack {
                    Button("changeCount") { probe("changeCount") { "\(NSPasteboard.general.changeCount)" } }
                    Button("types") {
                        probe("types") {
                            let types = NSPasteboard.general.pasteboardItems?.map { $0.types.map(\.rawValue) } ?? []
                            return "\(types.count) item(s), \(types.joined().count) type(s)"
                        }
                    }
                    Button("Read content") {
                        probe("content read") {
                            let item = NSPasteboard.general.pasteboardItems?.first
                            guard let item, let type = item.types.first else { return "empty" }
                            return item.data(forType: type).map { "\($0.count) bytes of \(type.rawValue)" } ?? "nil"
                        }
                    }
                    Spacer()
                    Button("Copy report") { copyReport() }
                }
                List(probes, id: \.self) { Text($0).font(.caption.monospaced()) }
                    .frame(minHeight: 80)
            }

            GroupBox("Capture log (newest first; no clipboard content)") {
                List(monitor.log) { event in
                    Text("\(event.date.formatted(date: .omitted, time: .standard))  \(event.message)")
                        .font(.caption.monospaced())
                }
                .frame(minHeight: 160)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func probe(_ name: String, _ call: () -> String) {
        let before = PasteboardAccess.behaviorName
        let result = call()
        let after = PasteboardAccess.behaviorName
        probes.insert("\(Date().formatted(date: .omitted, time: .standard))  \(name): \(result)  [\(before) → \(after)]", at: 0)
    }

    private func copyReport() {
        let report = ([
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) (\(PasteboardAccess.osBuild))",
            "accessBehavior: \(PasteboardAccess.behaviorName), capture: \(monitor.access)",
        ] + probes + monitor.log.map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)" })
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
    }
}
