import AppKit
import Foundation
import MemopilaServices
import Observation

/// Card-drag session SSOT (PLAN §3.11 + pinboard order): membership drops, Stack Window
/// positional reorder, and Favorites/Collections pinboard reorder.
///
/// Contract:
/// - Stack Window positional: `isPositionalReorder` (search clear, not truncated) — membership off.
/// - Pinboard positional: `isPinboardReorder` (Favorites / Collection).
///   On a **stack card**, both intents share one drop surface (spatial SSOT):
///   - leading strip → insert-before (reorder gap / phantom);
///   - card body → membership append (`appendHighlight`).
///   Record cards / End / phantoms are reorder-only. Dragging a stack is reorder-only.
/// - History (non-pinboard): record drag is membership (append onto stack card / editor / collection).
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

    /// Phantom insert gap while reordering (Stack Window or pinboard).
    enum ReorderGap: Equatable {
        /// Open a slot immediately before this entry.
        case before(HistoryEntry.ID)
        /// Trailing End slot.
        case end
    }

    private(set) var source: Source?
    private(set) var startedAt: Date?
    /// Captured at begin: member drag inside an editable Stack Window playlist.
    private(set) var isPositionalReorder = false
    /// Favorites / Collection grid reorder (panel).
    private(set) var isPinboardReorder = false
    /// Dim the card being dragged.
    private(set) var reorderDragID: HistoryEntry.ID?
    /// Phantom gap under the pointer (before an entry, or End).
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

    /// Record drag that can join a stack. Off only during Stack Window member reorder.
    /// Pinboard allows append on the stack-card body (leading strip stays reorder).
    var canMembershipAppend: Bool {
        isFresh && !isPositionalReorder && recordID != nil
    }

    func beginRecord(_ id: UUID, positionalReorder: Bool) {
        end(clearChrome: true)
        source = .record(id)
        startedAt = Date()
        isPositionalReorder = positionalReorder
        isPinboardReorder = false
        if positionalReorder {
            reorderDragID = .record(id)
            reorderGap = nil
            installMouseUpMonitor()
        }
    }

    func beginPinboardReorder(_ id: HistoryEntry.ID) {
        end(clearChrome: true)
        switch id {
        case .record(let uuid): source = .record(uuid)
        case .stack(let uuid): source = .stack(uuid)
        }
        startedAt = Date()
        isPositionalReorder = false
        isPinboardReorder = true
        reorderDragID = id
        reorderGap = nil
        installMouseUpMonitor()
    }

    func beginStack(_ id: UUID) {
        end(clearChrome: true)
        source = .stack(id)
        startedAt = Date()
        isPositionalReorder = false
        isPinboardReorder = false
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
        isPinboardReorder = false
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
