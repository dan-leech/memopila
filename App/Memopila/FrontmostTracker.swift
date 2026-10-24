import AppKit
import Darwin
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
    /// The last launch, activation, deactivation or exit of a screenshot agent, or the last time
    /// one was seen working.
    private var lastScreenshotActivity: Date?
    private var observers: [NSObjectProtocol] = []
    /// Running screenshot agents and the CPU time each had used at the last sample.
    private var agentCPU: [pid_t: UInt64] = [:]
    /// CPU time in Mach units that counts as work: taking a screenshot uses tens of milliseconds
    /// or more, an idle agent next to none.
    private let busyCPU: UInt64 = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanoseconds: UInt64 = 15_000_000
        return timebase.numer == 0 ? nanoseconds : nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer)
    }()

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
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                let pid = app?.processIdentifier
                MainActor.assumeIsolated { self?.noteEvent(name, bundleID: bundleID, pid: pid) }
            })
        }
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier.map(Self.screenshotAgents.contains) == true {
            agentCPU[app.processIdentifier] = cpuTime(of: app.processIdentifier) ?? 0
        }
    }

    /// On every clipboard poll, before a change is read. A screenshot agent that keeps running
    /// between screenshots neither launches nor activates for one taken with the keyboard, so its
    /// work shows only in its CPU time (first-run feedback: such a screenshot taken over Finder
    /// was attributed to Finder). One system call per running agent.
    func sampleScreenshotAgents() {
        for (pid, previous) in agentCPU {
            guard let current = cpuTime(of: pid) else {
                agentCPU[pid] = nil
                continue
            }
            if current > previous, current - previous >= busyCPU { lastScreenshotActivity = Date() }
            agentCPU[pid] = current
        }
    }

    /// User and system CPU time of a process, in Mach units.
    private func cpuTime(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? usage.ri_user_time + usage.ri_system_time : nil
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

    private func noteEvent(_ name: Notification.Name, bundleID: String?, pid: pid_t?) {
        let now = Date()
        if let bundleID, Self.screenshotAgents.contains(bundleID) {
            lastScreenshotActivity = now
            if let pid {
                if name == NSWorkspace.didTerminateApplicationNotification {
                    agentCPU[pid] = nil
                } else if agentCPU[pid] == nil {
                    agentCPU[pid] = cpuTime(of: pid) ?? 0
                }
            }
        }
        guard name == NSWorkspace.didDeactivateApplicationNotification else { return }
        recent.removeAll { now.timeIntervalSince($0.until) > 2 }
        if let bundleID { recent.append((bundleID, now)) }
    }
}
