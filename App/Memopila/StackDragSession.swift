import AppKit
import Foundation

/// Single panel card-drag session (SSOT for stack/collection drops + positional reorder).
///
/// Contract (PLAN §3.11):
/// - In `scope.stack`, filters clear, n≥1: dragging a member is **positional** (insert-before / End).
/// - Otherwise a record drag is **membership** (append to stack card / grid, or collection sidebar).
/// - Reorder toolbar button is grips chrome only — not a gesture gate.
/// - SwiftUI `onDrag` has no end callback → mouse-up ends the session after `performDrop`.
@MainActor
final class StackDragSession {
    enum Source: Equatable {
        case record(UUID)
        case stack(UUID)
    }

    private(set) var source: Source?
    private(set) var startedAt: Date?
    /// Captured at begin: member drag inside an unfiltered open playlist.
    private(set) var isPositionalReorder = false

    private weak var history: HistoryModel?
    private var mouseMonitors: [Any] = []
    private var endTask: Task<Void, Never>?

    var recordID: UUID? {
        if case .record(let id) = source { return id }
        return nil
    }

    var stackID: UUID? {
        if case .stack(let id) = source { return id }
        return nil
    }

    /// Fresh enough for sidebar / stack-card membership drops.
    var isFresh: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) < 60
    }

    func beginRecord(_ id: UUID, positionalReorder: Bool, history: HistoryModel) {
        end(clearChrome: true)
        self.history = history
        source = .record(id)
        startedAt = Date()
        isPositionalReorder = positionalReorder
        if positionalReorder {
            history.stackReorderDragID = id
            history.stackReorderDropTargetID = nil
            installMouseUpMonitor()
        }
    }

    func beginStack(_ id: UUID, history: HistoryModel) {
        end(clearChrome: true)
        self.history = history
        source = .stack(id)
        startedAt = Date()
        isPositionalReorder = false
    }

    /// Call at the start of `performDrop` so the mouse-up clearer cannot nil the session first.
    func claimForDrop() {
        endTask?.cancel()
        endTask = nil
    }

    func setDropBefore(_ targetID: UUID?) {
        history?.stackReorderDropTargetID = targetID
    }

    func end(clearChrome: Bool = true) {
        tearDownMouseUpMonitor()
        endTask?.cancel()
        endTask = nil
        source = nil
        startedAt = nil
        isPositionalReorder = false
        if clearChrome {
            history?.clearReorderDrag()
        }
        history = nil
    }

    private func installMouseUpMonitor() {
        tearDownMouseUpMonitor()
        let schedule: () -> Void = { [weak self] in self?.scheduleEndAfterMouseUp() }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
            schedule()
            return event
        }) {
            mouseMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in
            schedule()
        }) {
            mouseMonitors.append(global)
        }
    }

    private func tearDownMouseUpMonitor() {
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors = []
    }

    private func scheduleEndAfterMouseUp() {
        endTask?.cancel()
        endTask = Task { @MainActor in
            // Mouse-up often precedes `performDrop`; give the drop session time to claim.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.source != nil else { return }
            self.end()
        }
    }
}
