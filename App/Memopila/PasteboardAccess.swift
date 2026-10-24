import AppKit

/// macOS pasteboard access policy (PLAN §3.1). Only the General pasteboard is gated.
@MainActor
enum PasteboardAccess {
    enum State: Equatable {
        /// `.alwaysAllow`, or `.default` verified silent on this OS build.
        case allowed
        /// `.default` not yet verified: background reads could raise an alert, so wait for Enable capture.
        case needsEnable
        /// `.ask`: the user has to choose Always Allow in System Settings.
        case ask
        case denied

        var allowsCapture: Bool { self == .allowed }
    }

    static var behavior: NSPasteboard.AccessBehavior { NSPasteboard.general.accessBehavior }

    static func currentState(verifiedBuild: String?) -> State {
        switch behavior {
        case .alwaysAllow:
            return .allowed
        case .default:
            return verifiedBuild == osBuild ? .allowed : .needsEnable
        case .ask:
            return .ask
        case .alwaysDeny:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// One content read from an explicit user action, discarded (§3.1 bootstrap).
    /// Returns the OS build to remember when the state stayed `.default` (no alert: enforcement is off).
    static func bootstrapRead() -> (didRead: Bool, verifiedBuild: String?) {
        let pasteboard = NSPasteboard.general
        guard let item = pasteboard.pasteboardItems?.first, let first = item.types.first else { return (false, nil) }
        // A small type when there is one — text, the source marker, a link — rather than an image
        // or a document a lazy provider would have to render on the main thread (review finding).
        let small: [NSPasteboard.PasteboardType] = [.string, NSPasteboard.PasteboardType("org.nspasteboard.source"), .URL, .fileURL]
        let type = small.first { item.types.contains($0) } ?? first
        _ = item.data(forType: type)
        return (true, behavior == .default ? osBuild : nil)
    }

    static var behaviorName: String {
        switch behavior {
        case .default: "default"
        case .ask: "ask"
        case .alwaysAllow: "alwaysAllow"
        case .alwaysDeny: "alwaysDeny"
        @unknown default: "unknown(\(behavior.rawValue))"
        }
    }

    /// Opens System Settings → Privacy & Security (the exact pane name is a Phase 1 spike question).
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            External.open(url)
        }
    }

    /// e.g. "25A354" (`kern.osversion`).
    nonisolated static let osBuild: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}
