import AppKit
import Foundation
import Observation

/// Card-drag session SSOT (PLAN §3.11): membership drops + Stack Window positional reorder.
///
/// Contract:
/// - Positional reorder only while the **Stack Window** editor can reorder (search clear, not truncated).
/// - Otherwise a record drag is **membership** (append onto a panel stack card / editor grid / collection).
/// - Reorder chrome (`reorderDragID` / `reorderGap`) lives here — not on `HistoryModel`.
///   Gap is a **phantom slot** (insert-before or trailing End), never a highlight on an existing card.
/// - Membership chrome (`appendHighlight`) highlights the panel stack card or the editor Add / empty state.
/// - SwiftUI `onDrag` has no end callback → mouse-up ends the session after `performDrop`.
@MainActor
@Observable
final class StackDragSession {
    enum Source: Equatable {
        case record(UUID)
        case stack(UUID)
    }

    /// Where a membership append would land under the pointer.
    enum AppendHighlight: Equatable {
        case editor
        case stack(UUID)
    }

    /// Phantom insert gap while reordering in the Stack Window.
    enum ReorderGap: Equatable {
        /// Open a slot immediately before this member.
        case before(UUID)
        /// Trailing End slot.
        case end
    }

    private(set) var source: Source?
    private(set) var startedAt: Date?
    /// Captured at begin: member drag inside an editable Stack Window playlist.
    private(set) var isPositionalReorder = false
    /// Dim the card being dragged in the Stack Window.
    private(set) var reorderDragID: UUID?
    /// Phantom gap under the pointer (before a member, or End).
    private(set) var reorderGap: ReorderGap?
    /// Membership append hover (panel stack card or Stack Window grid / empty).
    private(set) var appendHighlight: AppendHighlight?

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

    /// Record drag that can join a stack (not a positional reorder inside the editor).
    var canMembershipAppend: Bool {
        isFresh && !isPositionalReorder && recordID != nil
    }

    func beginRecord(_ id: UUID, positionalReorder: Bool) {
        end(clearChrome: true)
        source = .record(id)
        startedAt = Date()
        isPositionalReorder = positionalReorder
        if positionalReorder {
            reorderDragID = id
            reorderGap = nil
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

    func setReorderGap(_ gap: ReorderGap?) {
        guard reorderGap != gap else { return }
        reorderGap = gap
    }

    func setAppendHighlight(_ highlight: AppendHighlight?) {
        guard appendHighlight != highlight else { return }
        appendHighlight = highlight
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
            reorderGap = nil
            appendHighlight = nil
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
