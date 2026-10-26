import Foundation
import MemopilaCore
import MemopilaServices
import Observation

/// In-memory copy of one paste stack for the Stack Window (PLAN §3.11). Store remains SSOT.
@MainActor
@Observable
final class StackEditorState {
    private(set) var stackID: UUID
    private(set) var stack: StackCard
    /// UI order for the loaded window (`StackMember.position`). May be a prefix when truncated.
    private(set) var order: [UUID] = []
    /// Loaded member cards aligned with `order` (missing ids omitted until reload).
    private(set) var members: [HistoryCard] = []
    /// True store membership count — may exceed `order.count` when truncated for the window.
    private(set) var totalMemberCount = 0
    /// Filter for the member grid — when non-empty, positional DnD is off.
    var search = ""
    private(set) var loadError: String?
    private(set) var selectedID: UUID?

    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored private var generation = 0

    static let maxMembers = 1_200

    init(stack: StackCard, store: ClipboardStore) {
        self.stackID = stack.id
        self.stack = stack
        self.store = store
    }

    var title: String {
        stack.title.isEmpty ? String(localized: "Stack") : stack.title
    }

    /// Window loaded only a prefix — never persist `order` as the full playlist (data-loss).
    var isTruncated: Bool { totalMemberCount > order.count }

    var canReorder: Bool {
        search.isEmpty && !order.isEmpty && !isTruncated
    }

    var selectedCard: HistoryCard? {
        selectedID.flatMap { id in members.first { $0.id == id } }
    }

    /// Members visible under the current search (order preserved).
    var visibleMembers: [HistoryCard] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return members }
        return members.filter { card in
            words.allSatisfy { word in
                card.preview.localizedStandardContains(word)
                    || (card.customTitle?.localizedStandardContains(word) ?? false)
                    || (card.sourceAppName?.localizedStandardContains(word) ?? false)
            }
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func position(of id: UUID) -> Int? {
        order.firstIndex(of: id).map { $0 + 1 }
    }

    func reload() {
        generation += 1
        let generation = generation
        let stackID = stackID
        Task {
            do {
                let card = try await store.stack(stackID)
                let ids = try await store.stackMemberIDs(stackID)
                let limited = Array(ids.prefix(Self.maxMembers))
                let page = try await store.page(
                    HistoryQuery(scope: .stack(stackID)),
                    offset: 0,
                    limit: max(limited.count, 1)
                )
                guard generation == self.generation else { return }
                guard let card else {
                    self.loadError = String(localized: "This stack was deleted.")
                    return
                }
                let byID = Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) })
                self.stack = card
                self.totalMemberCount = ids.count
                self.order = limited
                self.members = limited.compactMap { byID[$0] }
                self.loadError = nil
                if let selectedID, !limited.contains(selectedID) {
                    self.selectedID = nil
                }
            } catch {
                guard generation == self.generation else { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    func applyOrder(_ next: [UUID]) {
        order = next
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        members = next.compactMap { byID[$0] }
        stack = stack.withMemberIDs(
            next,
            preview: members.first?.preview,
            sensitiveKind: members.first?.sensitiveKind
        )
    }

    func applyDeal(mode: StackDealMode, loops: Bool) {
        stack = stack.withDeal(mode: mode, loops: loops)
    }

    func applyTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        stack = StackCard(
            id: stack.id,
            title: trimmed.isEmpty ? "Stack" : trimmed,
            isFavorite: stack.isFavorite,
            loops: stack.loops,
            dealMode: stack.dealMode,
            createdAt: stack.createdAt,
            lastUsedAt: stack.lastUsedAt,
            memberIDs: stack.memberIDs,
            previewRecordID: stack.previewRecordID,
            memberCount: stack.memberCount,
            collectionIDs: stack.collectionIDs,
            sensitiveKind: stack.sensitiveKind,
            preview: stack.preview
        )
    }

    func applyFavorite(_ isFavorite: Bool) {
        stack = stack.withFavorite(isFavorite)
    }

    func moveMember(_ id: UUID, by delta: Int) -> [UUID]? {
        guard let from = order.firstIndex(of: id) else { return nil }
        let to = min(max(from + delta, 0), order.count - 1)
        guard from != to else { return order }
        var next = order
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        applyOrder(next)
        return next
    }

    func moveMemberToEnd(_ id: UUID, toStart: Bool) -> [UUID]? {
        guard let from = order.firstIndex(of: id) else { return nil }
        var next = order
        next.remove(at: from)
        if toStart { next.insert(id, at: 0) } else { next.append(id) }
        applyOrder(next)
        return next
    }

    func reorder(from fromID: UUID, before targetID: UUID?, atEnd: Bool) -> [UUID]? {
        guard canReorder else { return nil }
        var next = order
        guard let from = next.firstIndex(of: fromID) else { return nil }
        if atEnd {
            if from == next.count - 1 { return next }
            next.remove(at: from)
            next.append(fromID)
        } else {
            guard let targetID, fromID != targetID,
                  next.contains(targetID) else { return next }
            if from + 1 == next.firstIndex(of: targetID) { return next }
            next.remove(at: from)
            guard let newTarget = next.firstIndex(of: targetID) else { return nil }
            next.insert(fromID, at: newTarget)
        }
        applyOrder(next)
        return next
    }
}
