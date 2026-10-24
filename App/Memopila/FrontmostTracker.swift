import AppKit
import MemopilaCore

/// The frontmost app around the time of a copy, and whether a macOS screenshot agent was active
/// then (PLAN §5). Polling sees a change up to 250 ms late, so it also remembers apps that stopped
/// being frontmost in the meantime.
@MainActor
final class FrontmostTracker {
    /// macOS screenshot agents; their copies are attributed to the Screenshot app, as Pasta does.
    static let screenshotAgents: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.screencapture"]
    static let screenshotApp = AppIdentity.screenshotApp
    /// A screenshot reaches the clipboard a moment after the agent was last seen: the capture
    /// overlay gives the focus back first, then the image is encoded and written.
    private static let screenshotWindow: TimeInterval = 10

    private var recent: [(bundleID: String, until: Date)] = []
    /// The last launch, activation, deactivation or exit of a screenshot agent.
    private var lastScreenshotActivity: Date?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { self?.noteEvent(name, bundleID: bundleID) }
            })
        }
    }

    /// The app to attribute a change detected now to, given the previous tick at `date`.
    func source(since date: Date) -> String? {
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = [current].compactMap { $0 } + recent.filter { $0.until >= date }.map { $0.bundleID }
        if candidates.contains(where: Self.screenshotAgents.contains) { return Self.screenshotApp }
        return current
    }

    /// The Screenshot app when a screenshot agent was active around now; the reader uses it for
    /// image-only changes without a source marker, which the frontmost app did not make.
    func screenshotSource() -> String? {
        let now = Date()
        if let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.screenshotAgents.contains(current) {
            return Self.screenshotApp
        }
        if let lastScreenshotActivity, now.timeIntervalSince(lastScreenshotActivity) < Self.screenshotWindow {
            return Self.screenshotApp
        }
        // An agent that never became frontmost and was started for this capture.
        let launched = NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier, Self.screenshotAgents.contains(bundleID), let launch = app.launchDate else { return false }
            return now.timeIntervalSince(launch) < Self.screenshotWindow
        }
        return launched ? Self.screenshotApp : nil
    }

    private func noteEvent(_ name: Notification.Name, bundleID: String?) {
        let now = Date()
        if let bundleID, Self.screenshotAgents.contains(bundleID) { lastScreenshotActivity = now }
        guard name == NSWorkspace.didDeactivateApplicationNotification else { return }
        recent.removeAll { now.timeIntervalSince($0.until) > 2 }
        if let bundleID { recent.append((bundleID, now)) }
    }
}
