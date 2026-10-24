import AppKit
import MemopilaServices
import SwiftUI

/// Phase 1 spike instrument (PLAN §3.1 spike questions): shows the access policy and capture state,
/// and lets you try single pasteboard calls to see which ones raise the system alert.
struct DiagnosticsView: View {
    static let windowID = "diagnostics"

    let model: AppModel
    @State private var probes: [String] = []
    @State private var recordCount: Int?

    private var monitor: ClipboardMonitor { model.monitor }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("macOS build", PasteboardAccess.osBuild)
                row("accessBehavior", PasteboardAccess.behaviorName)
                row("Capture access", "\(monitor.access)")
                row("Silent default verified on", model.settings.silentDefaultVerifiedOSBuild ?? "—")
                row("changeCount handled", monitor.coordinator.lastHandledChangeCount.map(String.init) ?? "—")
                row("Reading / destructive", "\(monitor.coordinator.isCapturing) / \(monitor.coordinator.destructiveInProgress)")
                row("Token / skip armed", "\(monitor.coordinator.token.map(String.init) ?? "—") / \(monitor.coordinator.skipArmed)")
                row("Paused", monitor.isPaused ? (monitor.pausedUntil?.formatted() ?? "until resumed") : "no")
                row("Records in store", recordCount.map(String.init) ?? "—")
                row("Loaded cards", "\(model.history.cards.count)")
                row("Accessibility", AccessibilityBridge.isTrusted ? "trusted" : "not trusted")
                row("Store file", ClipboardStore.defaultURL.path)
            }
            .font(.system(.callout, design: .monospaced))

            GroupBox("Probes — each runs one pasteboard call and reports accessBehavior before and after") {
                HStack {
                    Button("changeCount") { probe("changeCount") { "\(NSPasteboard.general.changeCount)" } }
                    Button("types") {
                        probe("types") {
                            // Type names only: they are metadata, never clipboard content.
                            let types = NSPasteboard.general.pasteboardItems?.map { $0.types.map(\.rawValue) } ?? []
                            let list = types.enumerated().map { "item \($0.offset + 1): \($0.element.joined(separator: ", "))" }
                            return "\(types.count) item(s); " + list.joined(separator: "; ")
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
        .background(FloatingWindow())
        .task { recordCount = try? await model.store.count(HistoryQuery()) }
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
        // Through the writer, so the report is suppressed by the token and not added to history.
        _ = monitor.write(PasteboardWriter.plainTextItems(report), sourceBundleID: nil)
    }
}
