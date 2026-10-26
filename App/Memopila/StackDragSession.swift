import AppKit
import Foundation
import Observation

/// Card-drag session SSOT (PLAN §3.11): membership drops + Stack Window positional reorder.
///
/// Contract:
/// - Positional reorder only while the **Stack Window** editor can reorder (search clear, not truncated).
/// - Otherwise a record drag is **membership** (append onto a stack card / collection sidebar).
/// - Reorder chrome (`reorderDragID` / `dropTargetID`) lives here — not on `HistoryModel`.
/// - SwiftUI `onDrag` has no end callback → mouse-up ends the session after `performDrop`.
@MainActor
@Observable
final class StackDragSession {
    enum Source: Equatable {
        case record(UUID)
        case stack(UUID)
    }

    private(set) var source: Source?
    private(set) var startedAt: Date?
    /// Captured at begin: member drag inside an editable Stack Window playlist.
    private(set) var isPositionalReorder = false
    /// Dim / outline while reordering in the Stack Window.
    private(set) var reorderDragID: UUID?
    /// Insert-before target under the pointer.
    private(set) var dropTargetID: UUID?

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

    func beginRecord(_ id: UUID, positionalReorder: Bool) {
        end(clearChrome: true)
        source = .record(id)
        startedAt = Date()
        isPositionalReorder = positionalReorder
        if positionalReorder {
            reorderDragID = id
            dropTargetID = nil
            installMouseUpMonitor()
        }
    }

    func beginStack(_ id: UUID) {
        end(clearChrome: true)
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
        dropTargetID = targetID
    }

    func end(clearChrome: Bool = true) {
        tearDownMouseUpMonitor()
        endTask?.cancel()
        endTask = nil
        source = nil
        startedAt = nil
        isPositionalReorder = false
        if clearChrome {
            reorderDragID = nil
            dropTargetID = nil
        }
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
