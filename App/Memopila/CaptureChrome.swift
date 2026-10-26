import SwiftUI

/// Single priority ladder for capture + armed paste-stack chrome (PLAN §3.11).
/// Menu bar and panel share the same order; glyphs may differ by surface.
@MainActor
enum CaptureChrome {
    enum Kind {
        case blocked
        case paused
        case skip
        case armed
        case capturing
    }

    static func kind(monitor: ClipboardMonitor, stackArmed: Bool) -> Kind {
        if monitor.isCaptureBlocked { return .blocked }
        if monitor.isPaused { return .paused }
        if monitor.skipArmed { return .skip }
        if stackArmed { return .armed }
        return .capturing
    }

    /// Template symbol for the status item (monochrome).
    /// Armed paste stacks keep `list.clipboard` — bolt lives on the stack card / panel footer only.
    static func menuBarSymbol(monitor: ClipboardMonitor, stackArmed: Bool) -> String {
        switch kind(monitor: monitor, stackArmed: stackArmed) {
        case .blocked: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .skip: "forward.end.circle"
        case .armed, .capturing: "list.clipboard"
        }
    }

    /// Panel footer pulse: color + symbol. Blocked/paused stay one orange “not capturing” cue.
    static func panelStatus(
        monitor: ClipboardMonitor,
        stackArmed: Bool,
        progressLabel: String?
    ) -> (symbol: String, tint: Color, help: String) {
        if monitor.storageError != nil || monitor.access != .allowed || monitor.isPaused {
            return (
                "pause.circle.fill",
                .orange,
                String(localized: "Capture is paused: new copies are not added to history")
            )
        }
        if monitor.skipArmed {
            return (
                "forward.end.circle.fill",
                .orange,
                String(localized: "The next copy will be skipped")
            )
        }
        if stackArmed {
            let help = progressLabel.map {
                String(localized: "Paste stack armed (\($0)) — ⌘V advances; Esc stops")
            } ?? String(localized: "Paste stack armed — ⌘V advances; Esc stops")
            return ("bolt.fill", .orange, help)
        }
        return (
            "circle.fill",
            .green,
            String(localized: "Capturing: every copy is added to history")
        )
    }
}
