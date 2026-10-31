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
            // Entering Favorites/Collections: clear leftover History filters so reorder is obvious.
            if scope.isPinboard {
                let resetKind = kindFilter != .all
                let resetSearch = !search.isEmpty
                if resetKind { kindFilter = .all }
                if resetSearch { search = "" }
                if resetKind || resetSearch { return } // didSets reload
            }
            reload(selectFirst: true)
        }
    }
    var search = "" {
        didSet {
            guard search != oldValue else { return }
            scheduleSearch()
        }
    }
    /// The filter bar (§8.2): what kind of records, and since when; combined with the sidebar.
    var kindFilter: KindFilter = .all {
        didSet {
            guard kindFilter != oldValue else { return }
            reload(selectFirst: true)
        }
    }
    var periodFilter: PeriodFilter = .anyTime {
        didSet {
            guard periodFilter != oldValue else { return }
            reload(selectFirst: true)
        }
    }
    /// History Arrange (§8.2). Persisted via SettingsStore; not part of `isFiltered`.
    var sortMode: HistorySortMode = .recent {
        didSet {
            guard sortMode != oldValue else { return }
            onSortModeChange?(sortMode)
            reload(selectFirst: true)
        }
    }
    /// Persist Arrange when the user changes it (wired from AppModel → SettingsStore).
    @ObservationIgnored var onSortModeChange: ((HistorySortMode) -> Void)?
    /// Records only (paged). Load-more offset uses this count (P22).
    private(set) var records: [HistoryCard] = []
    /// Matching stacks (hard-capped, reloaded with the query).
    private(set) var stacks: [StackCard] = []
    /// Unfiltered stacks for membership menus (Add/Remove), not the grid filter.
    private(set) var allStacks: [StackCard] = []
    /// Merge-sorted view of records ∪ stacks (records-only, position order, inside a stack).
    private(set) var entries: [HistoryEntry] = []
    private(set) var recordTotal = 0
    /// Footer: records + stacks.
    var totalCount: Int { max(0, recordTotal - hiddenRecordAdjustment) + stacks.count }
    private var hiddenRecordAdjustment = 0

    /// Optimistic Deal / Loop on `allStacks` so toolbar chrome updates before reload.
    func setStackDealLocally(id: UUID, mode: StackDealMode, loops: Bool) {
        if let index = allStacks.firstIndex(where: { $0.id == id }) {
            allStacks[index] = allStacks[index].withDeal(mode: mode, loops: loops)
        }
        if let index = stacks.firstIndex(where: { $0.id == id }) {
            stacks[index] = stacks[index].withDeal(mode: mode, loops: loops)
        }
    }

    /// Optimistic playlist patch — face stays the first UI member (PLAN §3.11).
    func setStackMembersLocally(
        id: UUID,
        recordIDs: [UUID],
        preview: String?,
        sensitiveKind: String?
    ) {
        func patch(_ stack: StackCard) -> StackCard {
            guard stack.id == id else { return stack }
            return stack.withMemberIDs(recordIDs, preview: preview, sensitiveKind: sensitiveKind)
        }
        stacks = stacks.map(patch)
        allStacks = allStacks.map(patch)
        refreshEntriesAfterStackPatch()
    }

    /// Drop a member from one stack card only (Remove from Stack — not every stack that held it).
    /// `faceCard` resolves the new first member when it is not on the loaded History page
    /// (e.g. open Stack Window members — same dual-projection rule as favorites).
    func removeRecordFromStackLocally(
        stackID: UUID,
        recordID: UUID,
        faceCard: ((UUID) -> HistoryCard?)? = nil
    ) {
        func patch(_ stack: StackCard) -> StackCard {
            guard stack.id == stackID else { return stack }
            let next = stack.memberIDs.filter { $0 != recordID }
            guard next.count != stack.memberIDs.count else { return stack }
            let first = face(of: next.first, lookup: faceCard)
            return stack.withMemberIDs(
                next,
                preview: first?.preview,
                sensitiveKind: first?.sensitiveKind
            )
        }
        stacks = stacks.map(patch)
        allStacks = allStacks.map(patch)
        refreshEntriesAfterStackPatch()
    }

    /// Drop deleted records from every loaded stack card; preview follows the new first.
    /// `faceCard` — see `removeRecordFromStackLocally`.
    func removeRecordsFromStacksLocally(
        _ ids: Set<UUID>,
        faceCard: ((UUID) -> HistoryCard?)? = nil
    ) {
        guard !ids.isEmpty else { return }
        var changed = false
        func patch(_ stack: StackCard) -> StackCard {
            let next = stack.memberIDs.filter { !ids.contains($0) }
            guard next.count != stack.memberIDs.count else { return stack }
            changed = true
            let first = face(of: next.first, lookup: faceCard)
            return stack.withMemberIDs(
                next,
                preview: first?.preview,
                sensitiveKind: first?.sensitiveKind
            )
        }
        stacks = stacks.map(patch)
        allStacks = allStacks.map(patch)
        if changed { refreshEntriesAfterStackPatch() }
    }

    /// History page first; optional live projection (Stack Window) when the face is off-page.
    private func face(of id: UUID?, lookup: ((UUID) -> HistoryCard?)?) -> HistoryCard? {
        guard let id else { return nil }
        return records.first(where: { $0.id == id }) ?? lookup?(id)
    }

    private func refreshEntriesAfterStackPatch() {
        if case .stack = scope {
            entries = records.map { .record($0) }
        } else if scope.isPinboard {
            // Keep pinboard slot order; only refresh stack payloads in place.
            entries = entries.map { entry in
                guard case .stack(let stack) = entry,
                      let updated = stacks.first(where: { $0.id == stack.id }) ?? allStacks.first(where: { $0.id == stack.id })
                else { return entry }
                return .stack(updated)
            }
        } else {
            entries = Self.mergeEntries(records: records, stacks: stacks, sort: sortMode)
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
        // Pinboards ignore period (ordered slots, not clipboard age).
        HistoryQuery(
            scope: scope,
            search: search,
            kinds: kindFilter == .stacks ? [] : kindFilter.kinds,
            since: scope.isPinboard ? nil : periodFilter.since(now: Date()),
            sort: scope.isPinboard ? .recent : sortMode
        )
    }

    var isFiltered: Bool {
        if scope.isPinboard {
            return kindFilter != .all || !search.isEmpty
        }
        // Arrange is not a filter — Show All leaves Frequently chosen alone.
        return scope != .all || kindFilter != .all || periodFilter != .anyTime
    }

    /// In-grid pinboard reorder chrome (Favorites / Collection). Always on in those scopes;
    /// search/kind only affect which cards are visible (persist splices into the full board).
    var canReorderPinboard: Bool { scope.isPinboard }

    /// `HistoryScope.stack` is a store-query scope only (Stack Window loads members itself).
    var scopedStackID: UUID? {
        if case .stack(let id) = scope { return id }
        return nil
    }

    func clearFilters() {
        scope = .all
        kindFilter = .all
        periodFilter = .anyTime
    }

    /// Sidebar has no stack rows — map leftover `.stack` scope to no selection.
    /// Ignore `nil` writes so a List sync cannot clear the sidebar.
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

    /// Visible grid card first, then sidebar/cache — for Choose before a store round-trip.
    func stackCard(id: UUID) -> StackCard? {
        if let stack = stacks.first(where: { $0.id == id }) { return stack }
        return allStacks.first(where: { $0.id == id })
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
        entries = []
        apps = []
        collections = []
        memberships = [:]
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
        let pinboard = scope.isPinboard
        reloadTask = Task {
            do {
                async let allStackPage = store.stacks(HistoryQuery(), limit: Self.maxStacks)
                if let stackID = stackScopeID {
                    // Leftover `.stack` scope (store query only) — panel never drills in; bounce home if gone.
                    async let page = store.page(query, offset: 0, limit: limit)
                    async let count = store.count(query)
                    let (loaded, total, loadedAllStacks) = try await (page, count, allStackPage)
                    let memberships = try await store.memberships(of: loaded.map(\.id))
                    guard generation == self.generation else { return }
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
                        entries = visibleRecords.map { .record($0) }
                    }
                    self.memberships = memberships
                    recordTotal = total
                } else if pinboard {
                    async let board = store.pinboardEntries(query, limit: ClipboardStore.maxPinboardEntries)
                    let (loadedEntries, loadedAllStacks) = try await (board, allStackPage)
                    guard generation == self.generation else { return }
                    var visible = loadedEntries.filter { entry in
                        if case .record(let card) = entry { return !hiddenIDs.contains(card.id) }
                        return true
                    }
                    if stacksOnly {
                        visible = visible.filter {
                            if case .stack = $0 { return true }
                            return false
                        }
                    }
                    let visibleRecords = visible.compactMap { entry -> HistoryCard? in
                        if case .record(let card) = entry { return card }
                        return nil
                    }
                    let visibleStacks = visible.compactMap { entry -> StackCard? in
                        if case .stack(let card) = entry { return card }
                        return nil
                    }
                    hiddenRecordAdjustment = 0
                    withAnimation(animated ? .spring(response: 0.35, dampingFraction: 0.82) : nil) {
                        records = visibleRecords
                        stacks = visibleStacks
                        allStacks = loadedAllStacks
                        entries = visible
                    }
                    memberships = try await store.memberships(of: visibleRecords.map(\.id))
                    recordTotal = visibleRecords.count
                } else if stacksOnly {
                    async let stackPage = store.stacks(query, limit: Self.maxStacks)
                    let (loadedStacks, loadedAllStacks) = try await (stackPage, allStackPage)
                    guard generation == self.generation else { return }
                    withAnimation(animated ? .spring(response: 0.35, dampingFraction: 0.82) : nil) {
                        records = []
                        stacks = loadedStacks
                        allStacks = loadedAllStacks
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
                        entries = Self.mergeEntries(records: visibleRecords, stacks: loadedStacks, sort: sortMode)
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

    private static func mergeEntries(
        records: [HistoryCard],
        stacks: [StackCard],
        sort: HistorySortMode = .recent
    ) -> [HistoryEntry] {
        var result: [HistoryEntry] = records.map { .record($0) } + stacks.map { .stack($0) }
        switch sort {
        case .recent:
            result.sort {
                if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
                return Self.entryIDTieBreak($0, $1)
            }
        case .mostUsed:
            result.sort {
                if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
                if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
                return Self.entryIDTieBreak($0, $1)
            }
        }
        return result
    }

    /// Stable merge when dates / useCounts match (UUID string).
    private static func entryIDTieBreak(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        switch (a.id, b.id) {
        case (.record(let x), .record(let y)): x.uuidString < y.uuidString
        case (.stack(let x), .stack(let y)): x.uuidString < y.uuidString
        case (.record, .stack): true
        case (.stack, .record): false
        }
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

    /// Next record page when near the end of **records** (P22). Pinboards are not paged.
    func entryAppeared(_ entry: HistoryEntry) {
        guard !scope.isPinboard else { return }
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
                entries = Self.mergeEntries(records: records, stacks: stacks, sort: sortMode)
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
        let selected = selectedIndex
        let remaining = records.enumerated().filter { !ids.contains($0.element.id) }
        let removed = records.count - remaining.count
        withAnimation(.easeOut(duration: 0.2)) {
            records = remaining.map(\.element)
            rebuildEntriesPreservingPinboardOrder(removingRecordIDs: ids)
        }
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
        if scope.isPinboard {
            entries.removeAll { $0.id == .stack(id) }
        } else {
            entries = Self.mergeEntries(records: records, stacks: stacks, sort: sortMode)
        }
        if selectedID == .stack(id) {
            selectedID = entries.first?.id
        }
        markedIDs.remove(.stack(id))
    }

    /// Undo an optimistic Favorites-scope stack removal when the store write never happened.
    func reinsertStackLocally(_ stack: StackCard) {
        let id = stack.id
        if let index = allStacks.firstIndex(where: { $0.id == id }) {
            allStacks[index] = stack
        } else {
            allStacks.insert(stack, at: 0)
        }
        if scope == .favorites {
            stacks.removeAll { $0.id == id }
            stacks.insert(stack, at: 0)
            entries.removeAll { $0.id == .stack(id) }
            entries.insert(.stack(stack), at: 0)
        } else if let index = stacks.firstIndex(where: { $0.id == id }) {
            stacks[index] = stack
            refreshEntriesAfterStackPatch()
        } else {
            stacks.insert(stack, at: 0)
            refreshEntriesAfterStackPatch()
        }
    }

    func replaceLocally(_ card: HistoryCard) {
        if let index = records.firstIndex(where: { $0.id == card.id }) {
            records[index] = card
            if scope.isPinboard {
                if let entryIndex = entries.firstIndex(where: { $0.id == .record(card.id) }) {
                    entries[entryIndex] = .record(card)
                }
            } else if case .stack = scope {
                entries = records.map { .record($0) }
            } else {
                entries = Self.mergeEntries(records: records, stacks: stacks, sort: sortMode)
            }
        }
    }

    /// Optimistic rename on a loaded record card (History grid + pinboards).
    func setTitleLocally(record id: UUID, title: String) {
        guard let card = records.first(where: { $0.id == id }) else { return }
        replaceLocally(card.withTitle(title))
    }

    /// Optimistic stack rename (grid + allStacks for menus).
    func setStackTitleLocally(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = trimmed.isEmpty ? "Stack" : trimmed
        let patched: (StackCard) -> StackCard = { $0.id == id ? $0.withTitle(nextTitle) : $0 }
        stacks = stacks.map(patched)
        allStacks = allStacks.map(patched)
        if let entryIndex = entries.firstIndex(where: { $0.id == .stack(id) }),
           case .stack(let stack) = entries[entryIndex] {
            entries[entryIndex] = .stack(stack.withTitle(nextTitle))
        }
    }

    /// Optimistic favorite flip on a loaded record card (heart reacts before store round-trip).
    func setFavoriteLocally(record id: UUID, isFavorite: Bool) {
        guard let card = records.first(where: { $0.id == id }) else { return }
        let updated = card.withFavorite(isFavorite)
        replaceLocally(updated)
        if scope == .favorites {
            if isFavorite {
                // Join at front of pinboard.
                entries.removeAll { $0.id == .record(id) }
                entries.insert(.record(updated), at: 0)
                if !records.contains(where: { $0.id == id }) {
                    records.insert(updated, at: 0)
                }
            } else {
                entries.removeAll { $0.id == .record(id) }
                records.removeAll { $0.id == id }
            }
        }
    }

    /// Optimistic favorite flip on a stack card (grid + allStacks for menus).
    func setStackFavoriteLocally(id: UUID, isFavorite: Bool) {
        let patched: (StackCard) -> StackCard = { $0.id == id ? $0.withFavorite(isFavorite) : $0 }
        stacks = stacks.map(patched)
        allStacks = allStacks.map(patched)
        if scope == .favorites {
            if isFavorite, let stack = (stacks + allStacks).first(where: { $0.id == id }) {
                entries.removeAll { $0.id == .stack(id) }
                entries.insert(.stack(stack.withFavorite(true)), at: 0)
                if !stacks.contains(where: { $0.id == id }) {
                    stacks.insert(stack.withFavorite(true), at: 0)
                }
            } else if !isFavorite {
                entries.removeAll { $0.id == .stack(id) }
                stacks.removeAll { $0.id == id }
            }
        } else if case .stack = scope {
            entries = records.map { .record($0) }
        } else if !scope.isPinboard {
            entries = Self.mergeEntries(records: records, stacks: stacks, sort: sortMode)
        } else {
            refreshEntriesAfterStackPatch()
        }
    }

    private func rebuildEntriesPreservingPinboardOrder(removingRecordIDs ids: Set<UUID> = []) {
        if case .stack = scope {
            entries = records.map { .record($0) }
        } else if scope.isPinboard {
            entries = entries.compactMap { entry in
                switch entry {
                case .record(let card):
                    guard !ids.contains(card.id),
                          let updated = records.first(where: { $0.id == card.id }) else { return nil }
                    return .record(updated)
                case .stack(let stack):
                    guard let updated = stacks.first(where: { $0.id == stack.id }) else { return .stack(stack) }
                    return .stack(updated)
                }
            }
        } else {
            entries = Self.mergeEntries(records: records, stacks: stacks, sort: sortMode)
        }
    }

    /// Apply a pinboard reorder optimistically, then persist. No animation — grid cells stay put.
    func applyPinboardOrderLocally(_ order: [HistoryEntry.ID]) {
        guard scope.isPinboard else { return }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let next = order.compactMap { byID[$0] }
        guard next.count == entries.count else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            entries = next
            records = next.compactMap {
                if case .record(let card) = $0 { return card }
                return nil
            }
            stacks = next.compactMap {
                if case .stack(let card) = $0 { return card }
                return nil
            }
        }
    }

    /// Record is a paste-stack member → pinned for retention even after unfavorite (§6).
    func isStackPinned(_ recordID: UUID) -> Bool {
        allStacks.contains { $0.memberIDs.contains(recordID) }
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

extension HistorySortMode {
    /// Full menu row label (button uses short “Frequent”).
    var menuTitle: String {
        switch self {
        case .recent: String(localized: "Newest first")
        case .mostUsed: String(localized: "Frequently chosen")
        }
    }
}
