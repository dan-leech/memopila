import AppKit

/// The frontmost app around the time of a copy (PLAN §5). Polling sees a change up to 250 ms
/// late, so it also remembers apps that stopped being frontmost in the meantime: a screenshot is
/// copied by macOS's capture agent, which is often gone again by the next tick.
@MainActor
final class FrontmostTracker {
    /// macOS screenshot agents; their copies are attributed to the Screenshot app, as Pasta does.
    static let screenshotAgents: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.screencapture"]
    static let screenshotApp = "com.apple.screenshot.launcher"

    private var recent: [(bundleID: String, until: Date)] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.didDeactivate(bundleID) }
        }
    }

    /// The app to attribute a change detected now to, given the previous tick at `date`.
    func source(since date: Date) -> String? {
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = [current].compactMap { $0 } + recent.filter { $0.until >= date }.map { $0.bundleID }
        if candidates.contains(where: Self.screenshotAgents.contains) { return Self.screenshotApp }
        return current
    }

    private func didDeactivate(_ bundleID: String?) {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.until) > 2 }
        if let bundleID { recent.append((bundleID, now)) }
    }
}
