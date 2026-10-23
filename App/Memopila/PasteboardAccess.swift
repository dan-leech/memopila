import AppKit

/// macOS pasteboard access policy (PLAN §3.1). Only the General pasteboard is gated.
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

    @MainActor
    static var behavior: NSPasteboard.AccessBehavior { NSPasteboard.general.accessBehavior }

    @MainActor
    static func currentState() -> State {
        switch behavior {
        case .alwaysAllow:
            return .allowed
        case .default:
            return Preferences.silentDefaultVerifiedOSBuild == osBuild ? .allowed : .needsEnable
        case .ask:
            return .ask
        case .alwaysDeny:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// One content read from an explicit user action, discarded (§3.1 bootstrap).
    /// Returns `false` when the pasteboard has nothing to read.
    @MainActor
    @discardableResult
    static func bootstrapRead() -> Bool {
        let pasteboard = NSPasteboard.general
        guard let item = pasteboard.pasteboardItems?.first, let type = item.types.first else { return false }
        _ = item.data(forType: type)
        if behavior == .default { Preferences.silentDefaultVerifiedOSBuild = osBuild }
        return true
    }

    @MainActor
    static var behaviorName: String {
        switch behavior {
        case .default: "default"
        case .ask: "ask"
        case .alwaysAllow: "alwaysAllow"
        case .alwaysDeny: "alwaysDeny"
        @unknown default: "unknown(\(behavior.rawValue))"
        }
    }

    /// e.g. "25A354" (`kern.osversion`).
    static let osBuild: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
}
