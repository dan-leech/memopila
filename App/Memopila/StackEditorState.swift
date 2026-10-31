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
    /// Optimistic patches that must survive a concurrent `reload` (store fetch can finish before write).
    /// Favorite overrides are tagged with the AppModel op generation so superseded ops cannot steal a newer pending.
    @ObservationIgnored private var pendingMemberFavorites: [UUID: (isFavorite: Bool, op: Int)] = [:]
    @ObservationIgnored private var pendingMemberTitles: [UUID: (title: String, op: Int)] = [:]
    @ObservationIgnored private var pendingStackFavorite: (isFavorite: Bool, op: Int)?
    @ObservationIgnored private var pendingStackTitle: (title: String, op: Int)?
    @ObservationIgnored private var pendingStackDeal: (mode: StackDealMode, loops: Bool, op: Int)?
    /// Optimistic playlist order — survives a reload whose store fetch started before the write landed.
    @ObservationIgnored private var pendingOrder: [UUID]?
    @ObservationIgnored private var titleEditGeneration = 0

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

    /// `excluding` is re-applied after the snapshot — a delete during reload must not repaint ghosts.
    func reload(selecting id: UUID? = nil, excluding: @escaping @MainActor () -> Set<UUID> = { [] }) {
        generation += 1
        let generation = generation
        let stackID = stackID
        let preferSelection = id
        Task {
            do {
                // One actor call — three separate reads used to race duplicate/remove mid-reload.
                let hiddenAtStart = excluding()
                guard let snap = try await store.stackSnapshot(
                    stackID, memberLimit: Self.maxMembers, excluding: hiddenAtStart
                ) else {
                    guard generation == self.generation else { return }
                    self.loadError = String(localized: "This stack was deleted.")
                    return
                }
                guard generation == self.generation else { return }
                let stillHidden = excluding()
                let newlyHidden = stillHidden.subtracting(hiddenAtStart)
                let order = snap.order.filter { !stillHidden.contains($0) }
                let byID = Dictionary(uniqueKeysWithValues: snap.members.map { ($0.id, $0) })
                self.stack = snap.stack
                self.totalMemberCount = max(0, snap.totalVisible - newlyHidden.count)
                self.order = order
                self.members = order.compactMap { byID[$0] }
                self.applyPendingOverrides()
                self.loadError = nil
                if let preferSelection, self.order.contains(preferSelection) {
                    self.selectedID = preferSelection
                } else if let selectedID, !self.order.contains(selectedID) {
                    self.selectedID = nil
                }
            } catch {
                guard generation == self.generation else { return }
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Re-paint in-flight optimistic ♥ / titles / deal / order after a store-backed reload.
    private func applyPendingOverrides() {
        if let favorite = pendingStackFavorite {
            stack = stack.withFavorite(favorite.isFavorite)
        }
        if let title = pendingStackTitle {
            patchStackTitle(title.title)
        }
        if let deal = pendingStackDeal {
            stack = stack.withDeal(mode: deal.mode, loops: deal.loops)
        }
        if let pending = pendingOrder {
            let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
            var next = pending.filter { byID[$0] != nil }
            let have = Set(next)
            // Membership added while the reorder was in flight stays at the end.
            for id in order where !have.contains(id) {
                next.append(id)
            }
            paintOrder(next)
        }
        for (id, pending) in pendingMemberFavorites {
            guard let index = members.firstIndex(where: { $0.id == id }) else { continue }
            members[index] = members[index].withFavorite(pending.isFavorite)
        }
        for (id, pending) in pendingMemberTitles {
            guard let index = members.firstIndex(where: { $0.id == id }) else { continue }
            members[index] = members[index].withTitle(pending.title)
        }
    }

    /// True while the inspector title has not yet settled to the store.
    var hasPendingStackTitle: Bool { pendingStackTitle != nil }

    func applyOrder(_ next: [UUID]) {
        pendingOrder = next
        paintOrder(next)
    }

    func settleOrder(_ recordIDs: [UUID]) {
        if pendingOrder == recordIDs { pendingOrder = nil }
    }

    func discardOrderOverride() {
        pendingOrder = nil
    }

    private func paintOrder(_ next: [UUID]) {
        order = next
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        members = next.compactMap { byID[$0] }
        stack = stack.withMemberIDs(
            next,
            preview: members.first?.preview,
            sensitiveKind: members.first?.sensitiveKind
        )
    }

    /// Drop members from the in-memory window immediately (store / reload remain SSOT).
    /// Paint only — do not invent a pending reorder (that stuck across delete/Undo and skewed Choose).
    func removeMembers(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            pendingMemberFavorites.removeValue(forKey: id)
            pendingMemberTitles.removeValue(forKey: id)
        }
        let next = order.filter { !ids.contains($0) }
        let removed = order.count - next.count
        guard removed > 0 else { return }
        if let pending = pendingOrder {
            pendingOrder = pending.filter { !ids.contains($0) }
        }
        paintOrder(next)
        totalMemberCount = max(next.count, totalMemberCount - removed)
        if let selectedID, ids.contains(selectedID) {
            self.selectedID = nil
        }
    }

    /// Merge retarget: keep playlist slot, swap id (pending order included).
    func remapMember(from oldID: UUID, to newID: UUID) {
        if let pending = pendingOrder {
            pendingOrder = pending.map { $0 == oldID ? newID : $0 }
        }
        guard order.contains(oldID) else { return }
        var seen = Set<UUID>()
        let next = order.map { $0 == oldID ? newID : $0 }.filter { seen.insert($0).inserted }
        paintOrder(next)
        if let fav = pendingMemberFavorites.removeValue(forKey: oldID) {
            pendingMemberFavorites[newID] = fav
        }
        if let title = pendingMemberTitles.removeValue(forKey: oldID) {
            pendingMemberTitles[newID] = title
        }
    }

    func applyDeal(mode: StackDealMode, loops: Bool, op: Int) {
        pendingStackDeal = (mode, loops, op)
        stack = stack.withDeal(mode: mode, loops: loops)
    }

    func settleDeal(mode: StackDealMode, loops: Bool, op: Int) {
        guard pendingStackDeal?.mode == mode,
              pendingStackDeal?.loops == loops,
              pendingStackDeal?.op == op else { return }
        pendingStackDeal = nil
    }

    func discardDealOverride(op: Int) {
        guard pendingStackDeal?.op == op else { return }
        pendingStackDeal = nil
    }

    /// Local typing omits `op` (bumps an edit gen); store commits pass AppModel’s rename gen.
    func applyTitle(_ title: String, op: Int? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? "Stack" : trimmed
        let owned: Int
        if let op {
            owned = op
            titleEditGeneration = max(titleEditGeneration, op)
        } else {
            titleEditGeneration += 1
            owned = titleEditGeneration
        }
        pendingStackTitle = (next, owned)
        patchStackTitle(next)
    }

    /// Store committed this title — drop the pending override when this op still owns it.
    func settleTitle(_ title: String, op: Int) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? "Stack" : trimmed
        guard pendingStackTitle?.title == next, pendingStackTitle?.op == op else { return }
        pendingStackTitle = nil
    }

    private func patchStackTitle(_ title: String) {
        stack = stack.withTitle(title)
    }

    func applyFavorite(_ isFavorite: Bool, op: Int) {
        pendingStackFavorite = (isFavorite, op)
        stack = stack.withFavorite(isFavorite)
    }

    func settleFavorite(_ isFavorite: Bool, op: Int) {
        guard pendingStackFavorite?.isFavorite == isFavorite,
              pendingStackFavorite?.op == op else { return }
        pendingStackFavorite = nil
    }

    /// True when this op still owns an in-flight stack ♥. Nil pending is not ownership —
    /// a later settle must not be reverted by a superseded failure.
    func ownsStackFavoritePending(op: Int) -> Bool {
        guard let pending = pendingStackFavorite else { return false }
        return pending.op == op
    }

    /// Optimistic member ♥ — Stack Window cards are not in `HistoryModel.records`.
    func applyMemberFavorite(id: UUID, isFavorite: Bool, op: Int) {
        pendingMemberFavorites[id] = (isFavorite, op)
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        members[index] = members[index].withFavorite(isFavorite)
    }

    func settleMemberFavorite(id: UUID, isFavorite: Bool, op: Int) {
        _ = takeMemberFavoriteOverride(id: id, matching: isFavorite, op: op)
    }

    /// In-flight ♥ override for `id`, if any.
    func memberFavoriteOverride(_ id: UUID) -> (isFavorite: Bool, op: Int)? {
        pendingMemberFavorites[id]
    }

    /// Clears a pending ♥ only if it still belongs to this op.
    @discardableResult
    func takeMemberFavoriteOverride(id: UUID, matching isFavorite: Bool, op: Int) -> Bool {
        guard let pending = pendingMemberFavorites[id],
              pending.isFavorite == isFavorite,
              pending.op == op else { return false }
        pendingMemberFavorites.removeValue(forKey: id)
        return true
    }

    /// Paint without touching pending (revert after a superseded / failed write).
    func paintMemberFavorite(id: UUID, isFavorite: Bool) {
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        members[index] = members[index].withFavorite(isFavorite)
    }

    /// Optimistic member rename — op-tagged like ♥ so a lagged failure cannot wipe a newer pending.
    func applyMemberTitle(id: UUID, title: String, op: Int) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingMemberTitles[id] = (trimmed, op)
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        members[index] = members[index].withTitle(title)
    }

    func settleMemberTitle(id: UUID, title: String, op: Int) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pending = pendingMemberTitles[id],
              pending.title == trimmed,
              pending.op == op else { return }
        pendingMemberTitles.removeValue(forKey: id)
    }

    /// Drop pending title so a reload can show store truth after a failed rename.
    func discardMemberTitleOverride(id: UUID, op: Int) {
        guard pendingMemberTitles[id]?.op == op else { return }
        pendingMemberTitles.removeValue(forKey: id)
    }

    func discardStackTitleOverride(op: Int) {
        guard pendingStackTitle?.op == op else { return }
        pendingStackTitle = nil
    }

    /// In-flight member title override for `id`, if any.
    func memberTitleOverride(_ id: UUID) -> String? {
        pendingMemberTitles[id]?.title
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
