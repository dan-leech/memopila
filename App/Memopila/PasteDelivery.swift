import AppKit
import Observation

public enum ReadyFail: Sendable, Equatable {
    case memopilaKey
    case noFrontmost
    case activateFailed
    case lostReadyBeforeKey
}

public enum PasteDeliveryResult: Sendable, Equatable {
    case delivered
    case blocked(ReadyFail)
    case cancelled
}

/// Target app for a synthetic ⌘V (activate + readiness).
public struct PasteTarget: Sendable {
    public let app: NSRunningApplication

    public init(app: NSRunningApplication) {
        self.app = app
    }

    @MainActor
    public func activate() -> Bool {
        guard !app.isTerminated else { return false }
        return app.activate()
    }
}

@MainActor
protocol PasteDelivering: AnyObject {
    var isInFlight: Bool { get }
    func deliver(to: PasteTarget) async -> PasteDeliveryResult
}

/// Synthetic ⌘V into another app. Ready = frontmost ∧ !memopilaUIKey; rechecked before keyDown/keyUp.
@MainActor
@Observable
final class PasteDelivery: PasteDelivering {
    private(set) var isInFlight = false

    private let memopilaUIKey: () -> Bool
    private let paste: () -> Void
    private let yieldKeyFocus: () -> Void
    private let settleMs: Int

    init(
        memopilaUIKey: @escaping () -> Bool,
        paste: @escaping () -> Void = { AccessibilityBridge.paste() },
        yieldKeyFocus: @escaping () -> Void = {},
        settleMs: Int = 50
    ) {
        self.memopilaUIKey = memopilaUIKey
        self.paste = paste
        self.yieldKeyFocus = yieldKeyFocus
        self.settleMs = settleMs
    }

    func deliver(to target: PasteTarget) async -> PasteDeliveryResult {
        guard !isInFlight else { return .cancelled }
        isInFlight = true
        defer { isInFlight = false }

        guard !target.app.isTerminated else { return .blocked(.noFrontmost) }
        if memopilaUIKey() {
            yieldKeyFocus()
        }
        guard target.activate() else { return .blocked(.activateFailed) }

        // Give activation a beat when Memopila was key / active.
        if memopilaUIKey() || NSApp.isActive {
            try? await Task.sleep(for: .milliseconds(max(settleMs, 200)))
            if memopilaUIKey() {
                yieldKeyFocus()
                guard target.activate() else { return .blocked(.activateFailed) }
                try? await Task.sleep(for: .milliseconds(settleMs))
            }
        } else {
            try? await Task.sleep(for: .milliseconds(settleMs))
        }

        if memopilaUIKey() { return .blocked(.memopilaKey) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier else {
            return .blocked(.noFrontmost)
        }
        // Recheck immediately before the synthetic keys.
        if memopilaUIKey() { return .blocked(.lostReadyBeforeKey) }
        paste()
        return .delivered
    }
}
