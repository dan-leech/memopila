import AppKit
import Foundation
import MemopilaCore
import MemopilaServices
import Observation
import SwiftUI

/// Paged card DTOs for the grid, the sidebar lists and the selection (PLAN §7.1, §7.3, §8.2, §3.11).
/// Holds no payload bytes; the pages are dropped when the panel has been closed for a while.
@MainActor
@Observable
final class HistoryModel {
    var scope: HistoryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            // Always drop in-flight reorder — member IDs are not valid across stacks / scopes.
            clearReorderDrag()
            if case .stack = oldValue, case .stack = scope { /* switching stacks */ }
            else if case .stack = scope { /* entering */ }
            else { isReorderingStack = false }
            endReorderDragIfUnavailable()
            reload(selectFirst: true)
        }
    }
    var search = "" {
        didSet {
            guard search != oldValue else { return }
            endReorderDragIfUnavailable()
            scheduleSearch()
        }
    }
    /// The filter bar (§8.2): what kind of records, and since when; combined with the sidebar.
    var kindFilter: KindFilter = .all {
        didSet {
            guard kindFilter != oldValue else { return }
            endReorderDragIfUnavailable()
            reload(selectFirst: true)
        }
    }
    var periodFilter: PeriodFilter = .anyTime {
        didSet {
            guard periodFilter != oldValue else { return }
            endReorderDragIfUnavailable()
            reload(selectFirst: true)
        }
    }
    /// Records only (paged). Load-more offset uses this count (P22).
    private(set) var records: [HistoryCard] = []
    /// Matching stacks (hard-capped, reloaded with the query).
    private(set) var stacks: [StackCard] = []
    /// Unfiltered stacks for membership menus (Add/Remove), not the grid filter.
    private(set) var allStacks: [StackCard] = []
    /// Full UI order while `scope` is `.stack` (for # badges / Move / reorder); empty otherwise.
    private(set) var stackMemberOrder: [UUID] = []
    /// Merge-sorted view of records ∪ stacks (records-only, position order, inside a stack).
    private(set) var entries: [HistoryEntry] = []
    private(set) var recordTotal = 0
    /// Footer: records + stacks.
    var totalCount: Int { max(0, recordTotal - hiddenRecordAdjustment) + stacks.count }
    private var hiddenRecordAdjustment = 0
    /// Grip badges only (PLAN §3.11). Does **not** gate DnD — that uses `canReorderStack`.
    var isReorderingStack = false {
        didSet {
            if isReorderingStack, !canReorderStack { isReorderingStack = false }
        }
    }
    /// Positional-drag chrome (written by `StackDragSession`; observed for dim / End / outline).
    var stackReorderDragID: UUID?
    /// Card under the pointer — blue selection outline means “insert before this card”.
    var stackReorderDropTargetID: UUID?
    /// Trailing “drop at end” slot while a positional member drag is live and not already last.
    var stackReorderShowsEndSlot: Bool {
        guard canReorderStack, let id = stackReorderDragID else { return false }
        return stackMemberOrder.last != id
    }

    func clearReorderDrag() {
        stackReorderDragID = nil
        stackReorderDropTargetID = nil
    }

    /// Drop grips + drag chrome when filters / empty playlist make reorder illegal.
    private func endReorderDragIfUnavailable() {
        if !canReorderStack {
            isReorderingStack = false
            clearReorderDrag()
        }
    }

    /// Optimistic Deal / Loop on `allStacks` so toolbar chrome updates before reload.
    func setStackDealLocally(id: UUID, mode: StackDealMode, loops: Bool) {
        if let index = allStacks.firstIndex(where: { $0.id == id }) {
            allStacks[index] = allStacks[index].withDeal(mode: mode, loops: loops)
        }
        if let index = stacks.firstIndex(where: { $0.id == id }) {
            stacks[index] = stacks[index].withDeal(mode: mode, loops: loops)
        }
    }

    var selectedID: HistoryEntry.ID? {
        didSet {
            guard !isApplyingLoadedSelection else { return }
            selectionRevision += 1
            followsClipboard = false
        }
    }
    private(set) var markedIDs: Set<HistoryEntry.ID> = []
    private(set) var apps: [AppSummary] = []
    private(set) var types: [DisplayType] = []
    private(set) var collections: [CollectionSummary] = []
    /// Collections of the loaded record cards.
    private(set) var memberships: [UUID: Set<UUID>] = [:]
    private(set) var loadError: String?
    /// Columns of the grid at its current width, for ↑ ↓ navigation.
    var columns = 3

    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var isSearchPending = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var isApplyingLoadedSelection = false
    @ObservationIgnored var clipboardRecordID: () -> UUID? = { nil }
    @ObservationIgnored var clipboardStackID: () -> UUID? = { nil }
    @ObservationIgnored private var followsClipboard = false
    @ObservationIgnored private(set) var hiddenIDs: Set<UUID> = []
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isStale = true

    static let pageSize = 60
    static let maxReloadCount = 1_200
    static let maxStacks = 200

    init(store: ClipboardStore) {
        self.store = store
    }

    var query: HistoryQuery {
        // Stacks filter is not a DisplayType set — store gets an untyped query; records are dropped in reload.
        HistoryQuery(
            scope: scope,
            search: search,
            kinds: kindFilter == .stacks ? [] : kindFilter.kinds,
            since: periodFilter.since(now: Date())
        )
    }

    var isFiltered: Bool { scope != .all || kindFilter != .all || periodFilter != .anyTime }

    /// Reorder is safe only on the full non-empty playlist (A1). Empty → append drops stay available.
    var canReorderStack: Bool {
        guard case .stack = scope else { return false }
        return search.isEmpty
            && kindFilter == .all
            && periodFilter == .anyTime
            && !stackMemberOrder.isEmpty
    }

    var scopedStackID: UUID? {
        if case .stack(let id) = scope { return id }
        return nil
    }

    var scopedStack: StackCard? {
        guard let id = scopedStackID else { return nil }
        return allStacks.first { $0.id == id }
    }

    func clearFilters() {
        scope = .all
        kindFilter = .all
        periodFilter = .anyTime
        isReorderingStack = false
    }

    /// Sidebar has no stack rows — map drill-down to no selection (A3).
    /// Ignore `nil` writes so a List sync cannot kick the user out of a stack.
    var sidebarSelection: HistoryScope? {
        get {
            if case .stack = scope { return nil }
            return scope
        }
        set {
            guard let newValue else { return }
            scope = newValue
        }
    }

    /// Open a stack playlist in the main grid (§3.11 drill-down).
    func openStack(_ id: UUID) {
        if kindFilter == .stacks { kindFilter = .all }
        isReorderingStack = false
        if case .stack(let current) = scope, current == id {
            reload(selectFirst: true)
        } else {
            scope = .stack(id)
        }
    }

    /// 1-based UI/deal position in the full stack, or `nil` if not a member.
    func stackPosition(of recordID: UUID) -> Int? {
        guard let index = stackMemberOrder.firstIndex(of: recordID) else { return nil }
        return index + 1
    }

    /// Record cards only (compat for callers that still iterate records).
    var cards: [HistoryCard] { records }

    var selectedEntry: HistoryEntry? {
        selectedID.flatMap { id in entries.first { $0.id == id } }
    }

    var selectedCard: HistoryCard? {
        if case .record(let card) = selectedEntry { return card }
        return nil
    }

    var selectedStack: StackCard? {
        if case .stack(let card) = selectedEntry { return card }
        return nil
    }

    var selectedIndex: Int? {
        selectedID.flatMap { id in entries.firstIndex { $0.id == id } }
    }

    // MARK: Lifecycle

    func activate(keepingState: Bool = false) {
        isActive = true
        guard !keepingState else {
            reload(selectFirst: false)
            reloadSidebar()
            return
        }
        if !search.isEmpty { search = "" }
        searchTask?.cancel()
        isSearchPending = false
        followsClipboard = true
        applyLoadedSelection(defaultSelection())
        reload(selectFirst: true)
        reloadSidebar()
    }

    func clipboardDidChange() {
        if followsClipboard { applyLoadedSelection(defaultSelection()) }
    }

    private func defaultSelection() -> HistoryEntry.ID? {
        guard search.isEmpty else { return entries.first?.id }
        if let stackID = clipboardStackID(), entries.contains(where: { $0.id == .stack(stackID) }) {
            return .stack(stackID)
        }
        guard let id = clipboardRecordID(), entries.contains(where: { $0.id == .record(id) }) else { return nil }
        return .record(id)
    }

    func deactivate() {
        isActive = false
    }

    func purge() {
        guard !isActive else { return }
        generation += 1
        records = []
        stacks = []
        allStacks = []
        stackMemberOrder = []
        entries = []
        apps = []
        collections = []
        memberships = [:]
        isReorderingStack = false
        isStale = true
    }

    func storeDidChange() {
        guard isActive else {
            isStale = true
            return
        }
        reload(selectFirst: false, animated: true)
        reloadSidebar(after: .milliseconds(300))
    }

    func settle() async {
        if isSearchPending {
            searchTask?.cancel()
            isSearchPending = false
            reload(selectFirst: true)
        }
        var pending = reloadTask
        while let task = pending {
            await task.value
            pending = reloadTask == task ? nil : reloadTask
        }
    }

    // MARK: Loading

    func reload(selectFirst: Bool, animated: Bool = false) {
        generation += 1
        let generation = generation
        let revision = selectionRevision
        let query = query
        let limit = min(max(Self.pageSize, records.count), Self.maxReloadCount)
        let stacksOnly = kindFilter == .stacks
        let stackScopeID = scopedStackID
        reloadTask = Task {
            do {
                async let allStackPage = store.stacks(HistoryQuery(), limit: Self.maxStacks)
                if let stackID = stackScopeID {
                    async let page = store.page(query, offset: 0, limit: limit)
                    async let count = store.count(query)
                    async let memberIDs = store.stackMemberIDs(stackID)
                    let (loaded, total, loadedAllStacks, order) = try await (page, count, allStackPage, memberIDs)
                    let memberships = try await store.memberships(of: loaded.map(\.id))
                    guard generation == self.generation else { return }
                    // Stack deleted or pruned while drilled in (A9).
                    if !loadedAllStacks.contains(where: { $0.id == stackID }) {
                        self.scope = .all
                        return
                    }
                    let visibleRecords = loaded.filter { !hiddenIDs.contains($0.id) }
                    hiddenRecordAdjustment = loaded.count - visibleRecords.count
                    withAnimation(animated ? .spring(response: 0.35, dampingFraction: 0.82) : nil) {
                        records = visibleRecords
                        stacks = []
                        allStacks = loadedAllStacks
                        stackMemberOrder = order
                        entries = visibleRecords.map { .record($0) }
                    }
                    endReorderDragIfUnavailable()
                    if let drag = stackReorderDragID, !order.contains(drag) { clearReorderDrag() }
                    self.memberships = memberships
                    recordTotal = total
                } else if stacksOnly {
                    async let stackPage = store.stacks(query, limit: Self.maxStacks)
                    let (loadedStacks, loadedAllStacks) = try await (stackPage, allStackPage)
                    guard generation == self.generation else { return }
                    withAnimation(animated ? .spring(response: 0.35, dampingFraction: 0.82) : nil) {
                        records = []
                        stacks = loadedStacks
                        allStacks = loadedAllStacks
                        stackMemberOrder = []
                        entries = loadedStacks.map { .stack($0) }
                    }
                    memberships = [:]
                    recordTotal = 0
                    hiddenRecordAdjustment = 0
                } else {
                    async let page = store.page(query, offset: 0, limit: limit)
                    async let count = store.count(query)
                    async let stackPage = store.stacks(query, limit: Self.maxStacks)
                    let (loaded, total, loadedStacks, loadedAllStacks) = try await (page, count, stackPage, allStackPage)
                    let memberships = try await store.memberships(of: loaded.map(\.id))
                    guard generation == self.generation else { return }
                    let visibleRecords = loaded.filter { !hiddenIDs.contains($0.id) }
                    hiddenRecordAdjustment = loaded.count - visibleRecords.count
                    withAnimation(animated ? .spring(response: 0.35, dampingFraction: 0.82) : nil) {
                        records = visibleRecords
                        stacks = loadedStacks
                        allStacks = loadedAllStacks
                        stackMemberOrder = []
                        entries = Self.mergeEntries(records: visibleRecords, stacks: loadedStacks)
                    }
                    self.memberships = memberships
                    recordTotal = total
                }
                markedIDs.formIntersection(entries.map(\.id))
                loadError = nil
                isStale = false
                let userMoved = revision != selectionRevision
                if !userMoved, selectFirst || followsClipboard || selectedIndex == nil {
                    applyLoadedSelection(defaultSelection())
                }
            } catch {
                guard generation == self.generation else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private static func mergeEntries(records: [HistoryCard], stacks: [StackCard]) -> [HistoryEntry] {
        var result: [HistoryEntry] = records.map { .record($0) } + stacks.map { .stack($0) }
        result.sort { $0.sortDate > $1.sortDate }
        return result
    }

    private func reloadSidebar(after delay: Duration = .zero) {
        sidebarTask?.cancel()
        sidebarTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            async let apps = store.apps()
            async let types = store.displayTypes()
            async let collections = store.collections()
            guard let result = try? await (apps, types, collections), !Task.isCancelled else { return }
            self.apps = result.0
            self.types = result.1
            self.collections = result.2
        }
    }

    private func applyLoadedSelection(_ id: HistoryEntry.ID?) {
        isApplyingLoadedSelection = true
        selectedID = id
        isApplyingLoadedSelection = false
    }

    /// Next record page when near the end of **records** (P22).
    func entryAppeared(_ entry: HistoryEntry) {
        guard case .record(let card) = entry else { return }
        guard !isLoadingMore, records.count < recordTotal,
              let index = records.lastIndex(where: { $0.id == card.id }), index >= records.count - 12 else { return }
        isLoadingMore = true
        let generation = generation
        let query = query
        let offset = records.count
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await store.page(query, offset: offset, limit: Self.pageSize),
                  generation == self.generation else { return }
            let known = Set(records.map(\.id))
            let added = page.filter { !known.contains($0.id) && !hiddenIDs.contains($0.id) }
            let memberships = (try? await store.memberships(of: added.map(\.id))) ?? [:]
            guard generation == self.generation else { return }
            records += added
            self.memberships.merge(memberships) { _, new in new }
            if case .stack = scope {
                entries = records.map { .record($0) }
            } else {
                entries = Self.mergeEntries(records: records, stacks: stacks)
            }
        }
    }

    /// Compat for callers still passing a card.
    func cardAppeared(_ card: HistoryCard) {
        entryAppeared(.record(card))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        isSearchPending = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            isSearchPending = false
            reload(selectFirst: true)
        }
    }

    // MARK: Collections

    /// Titles of paste stacks that include this record (card badge / a11y).
    func stackNames(of recordID: UUID) -> [String] {
        allStacks.compactMap { stack in
            guard stack.memberIDs.contains(recordID) else { return nil }
            return stack.title.isEmpty ? String(localized: "Stack") : stack.title
        }
    }

    func collectionNames(of recordID: UUID) -> [String] {
        guard let ids = memberships[recordID], !ids.isEmpty else { return [] }
        return collections.filter { ids.contains($0.id) }.map(\.name)
    }

    func setMembershipLocally(record: UUID, collection: UUID, isMember: Bool) {
        var ids = memberships[record] ?? []
        if isMember { ids.insert(collection) } else { ids.remove(collection) }
        memberships[record] = ids
    }

    func refreshCollections() {
        reloadSidebar()
        let ids = records.map(\.id)
        Task {
            guard let loaded = try? await store.memberships(of: ids) else { return }
            memberships.merge(loaded) { _, new in new }
            for id in ids where loaded[id] == nil { memberships[id] = nil }
        }
    }

    // MARK: Selection

    /// Selected entry IDs in grid order.
    var selection: [HistoryEntry.ID] {
        guard !markedIDs.isEmpty else { return selectedID.map { [$0] } ?? [] }
        let chosen = markedIDs.union(selectedID.map { [$0] } ?? [])
        return entries.map(\.id).filter { chosen.contains($0) }
    }

    /// Record IDs only (bulk delete / favorite / New Stack).
    var selectionRecordIDs: [UUID] {
        selection.compactMap {
            if case .record(let id) = $0 { return id }
            return nil
        }
    }

    func isSelected(_ id: HistoryEntry.ID) -> Bool {
        id == selectedID || markedIDs.contains(id)
    }

    /// Compat: record UUID selection check.
    func isSelected(_ recordID: UUID) -> Bool {
        isSelected(.record(recordID))
    }

    func click(_ id: HistoryEntry.ID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            var marked = markedIDs
            if marked.isEmpty, let current = selectedID { marked.insert(current) }
            if marked.contains(id), marked.count > 1 {
                marked.remove(id)
                selectedID = entries.first { marked.contains($0.id) }?.id
            } else {
                marked.insert(id)
                selectedID = id
            }
            markedIDs = marked.count > 1 ? marked : []
        } else if modifiers.contains(.shift), let anchor = selectedIndex, let target = entries.firstIndex(where: { $0.id == id }) {
            let range = min(anchor, target)...max(anchor, target)
            markedIDs = Set(entries[range].map(\.id))
            selectedID = id
        } else {
            markedIDs = []
            selectedID = id
        }
    }

    func click(record id: UUID, modifiers: NSEvent.ModifierFlags) {
        click(.record(id), modifiers: modifiers)
    }

    func extendSelection(by offset: Int) {
        guard let current = selectedID else { return moveSelection(by: offset) }
        var marked = markedIDs
        marked.insert(current)
        moveSelection(by: offset, keepingMarks: true)
        if let next = selectedID { marked.insert(next) }
        markedIDs = marked
    }

    func clearMarks() {
        if !markedIDs.isEmpty { markedIDs = [] }
    }

    func selectAll() {
        let all = Set(entries.map(\.id))
        if all.count > 1, all != markedIDs { markedIDs = all }
    }

    // MARK: Deletion with Undo

    func hide(_ ids: Set<UUID>) {
        hiddenIDs.formUnion(ids)
        removeLocally(ids)
    }

    func unhide(_ ids: Set<UUID>) {
        hiddenIDs.subtract(ids)
        storeDidChange()
    }

    func forgetHidden(_ ids: Set<UUID>) {
        hiddenIDs.subtract(ids)
    }

    func removeLocally(_ ids: Set<UUID>) {
        if let drag = stackReorderDragID, ids.contains(drag) { clearReorderDrag() }
        let selected = selectedIndex
        let remaining = records.enumerated().filter { !ids.contains($0.element.id) }
        let removed = records.count - remaining.count
        withAnimation(.easeOut(duration: 0.2)) {
            records = remaining.map(\.element)
            if case .stack = scope {
                stackMemberOrder.removeAll { ids.contains($0) }
                entries = records.map { .record($0) }
            } else {
                entries = Self.mergeEntries(records: records, stacks: stacks)
            }
        }
        endReorderDragIfUnavailable()
        recordTotal = max(0, recordTotal - removed)
        if let selected, let id = selectedID, case .record(let rid) = id, ids.contains(rid) {
            let next = remaining.first { $0.offset > selected } ?? remaining.last
            selectedID = next.map { .record($0.element.id) }
        }
        markedIDs = markedIDs.filter {
            if case .record(let rid) = $0 { return !ids.contains(rid) }
            return true
        }
    }

    func removeStackLocally(_ id: UUID) {
        stacks.removeAll { $0.id == id }
        allStacks.removeAll { $0.id == id }
        if case .stack(let scoped) = scope, scoped == id {
            scope = .all
            return
        }
        entries = Self.mergeEntries(records: records, stacks: stacks)
        if selectedID == .stack(id) {
            selectedID = entries.first?.id
        }
        markedIDs.remove(.stack(id))
    }

    func replaceLocally(_ card: HistoryCard) {
        if let index = records.firstIndex(where: { $0.id == card.id }) {
            records[index] = card
            if case .stack = scope {
                entries = records.map { .record($0) }
            } else {
                entries = Self.mergeEntries(records: records, stacks: stacks)
            }
        }
    }

    /// Optimistic favorite flip on a loaded record card (heart reacts before store round-trip).
    func setFavoriteLocally(record id: UUID, isFavorite: Bool) {
        guard let card = records.first(where: { $0.id == id }) else { return }
        replaceLocally(card.withFavorite(isFavorite))
    }

    /// Optimistic favorite flip on a stack card (grid + allStacks for menus).
    func setStackFavoriteLocally(id: UUID, isFavorite: Bool) {
        if let index = stacks.firstIndex(where: { $0.id == id }) {
            stacks[index] = stacks[index].withFavorite(isFavorite)
        }
        if let index = allStacks.firstIndex(where: { $0.id == id }) {
            allStacks[index] = allStacks[index].withFavorite(isFavorite)
        }
        if case .stack = scope {
            entries = records.map { .record($0) }
        } else {
            entries = Self.mergeEntries(records: records, stacks: stacks)
        }
    }

    /// Record is a paste-stack member → pinned for retention even after unfavorite (§6).
    func isStackPinned(_ recordID: UUID) -> Bool {
        allStacks.contains { $0.memberIDs.contains(recordID) }
    }

    /// Move a member in the full playlist order (Move Top/Up/Down/Bottom).
    /// Allowed while filtered — operates on `stackMemberOrder`, not the visible page (PLAN).
    func moveStackMember(_ recordID: UUID, by delta: Int) -> [UUID]? {
        guard case .stack = scope else { return nil }
        guard let from = stackMemberOrder.firstIndex(of: recordID) else { return nil }
        let to = min(max(from + delta, 0), stackMemberOrder.count - 1)
        guard from != to else { return stackMemberOrder }
        var next = stackMemberOrder
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        stackMemberOrder = next
        return next
    }

    func moveStackMemberToEnd(_ recordID: UUID, toStart: Bool) -> [UUID]? {
        guard case .stack = scope else { return nil }
        guard let from = stackMemberOrder.firstIndex(of: recordID) else { return nil }
        var next = stackMemberOrder
        next.remove(at: from)
        if toStart { next.insert(recordID, at: 0) } else { next.append(recordID) }
        stackMemberOrder = next
        return next
    }

    func applyStackMemberOrder(_ order: [UUID]) {
        stackMemberOrder = order
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        records = order.compactMap { byID[$0] }
        entries = records.map { .record($0) }
        if case .stack(let stackID) = scope {
            if let index = allStacks.firstIndex(where: { $0.id == stackID }) {
                let first = records.first
                allStacks[index] = allStacks[index].withMemberIDs(
                    order,
                    preview: first?.preview,
                    sensitiveKind: first?.sensitiveKind
                )
            }
        }
    }

    // MARK: Navigation

    func moveSelection(by offset: Int, keepingMarks: Bool = false) {
        guard !entries.isEmpty else { return }
        if !keepingMarks { clearMarks() }
        guard let current = selectedIndex else {
            selectedID = entries.first?.id
            return
        }
        let next = min(max(current + offset, 0), entries.count - 1)
        selectedID = entries[next].id
    }

    func moveSelectionVertically(_ rows: Int) {
        moveSelection(by: rows * max(columns, 1))
    }

    func card(at visibleIndex: Int) -> HistoryCard? {
        guard entries.indices.contains(visibleIndex), case .record(let card) = entries[visibleIndex] else { return nil }
        return card
    }

    func entry(at visibleIndex: Int) -> HistoryEntry? {
        entries.indices.contains(visibleIndex) ? entries[visibleIndex] : nil
    }

    var isStaleForOpen: Bool { isStale }
}

enum KindFilter: CaseIterable, Hashable {
    case all, text, links, images, files, colors, stacks

    var kinds: Set<DisplayType> {
        switch self {
        case .all, .stacks: []
        case .text: [.text, .richText, .mixed]
        case .links: [.url]
        case .images: [.image, .pdf]
        case .files: [.file]
        case .colors: [.color]
        }
    }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .text: String(localized: "Text")
        case .links: String(localized: "Links")
        case .images: String(localized: "Images")
        case .files: String(localized: "Files")
        case .colors: String(localized: "Colors")
        case .stacks: String(localized: "Stacks")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .files: "doc"
        case .colors: "paintpalette"
        case .stacks: "rectangle.stack"
        }
    }
}

enum PeriodFilter: CaseIterable, Hashable {
    case anyTime, today, week, month

    func since(now: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .anyTime: return nil
        case .today: return calendar.startOfDay(for: now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .day, value: -30, to: now)
        }
    }

    var title: String {
        switch self {
        case .anyTime: String(localized: "Any Time")
        case .today: String(localized: "Today")
        case .week: String(localized: "Last 7 Days")
        case .month: String(localized: "Last 30 Days")
        }
    }
}
