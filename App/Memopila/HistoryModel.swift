import AppKit
import Foundation
import MemopilaCore
import MemopilaServices
import Observation
import SwiftUI

/// Paged card DTOs for the grid, the sidebar lists and the selection (PLAN §7.1, §7.3, §8.2).
/// Holds no payload bytes; the pages are dropped when the panel has been closed for a while.
@MainActor
@Observable
final class HistoryModel {
    var scope: HistoryScope = .all {
        didSet { if scope != oldValue { reload(selectFirst: true) } }
    }
    var search = "" {
        didSet { if search != oldValue { scheduleSearch() } }
    }
    /// The filter bar (§8.2): what kind of records, and since when; combined with the sidebar.
    var kindFilter: KindFilter = .all {
        didSet { if kindFilter != oldValue { reload(selectFirst: true) } }
    }
    var periodFilter: PeriodFilter = .anyTime {
        didSet { if periodFilter != oldValue { reload(selectFirst: true) } }
    }
    private(set) var cards: [HistoryCard] = []
    private(set) var totalCount = 0
    var selectedID: UUID? {
        didSet {
            guard !isApplyingLoadedSelection else { return }
            selectionRevision += 1
            followsClipboard = false
        }
    }
    /// More selected cards besides `selectedID` (⌘-click, ⇧-click, ⇧-arrows): bulk delete,
    /// favorites and collections. Empty = only `selectedID` is selected.
    private(set) var markedIDs: Set<UUID> = []
    private(set) var apps: [AppSummary] = []
    private(set) var types: [DisplayType] = []
    private(set) var collections: [CollectionSummary] = []
    /// Collections of the loaded cards.
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
    /// Bumped by every selection change that did not come from a load, so a load that finishes
    /// late does not undo the user's ↑ ↓ or click.
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var isApplyingLoadedSelection = false
    /// The record the clipboard holds (§8.2): the selection shows it until the user moves it.
    @ObservationIgnored var clipboardRecordID: () -> UUID? = { nil }
    @ObservationIgnored private var followsClipboard = false
    /// Deleted cards waiting for Undo (§8.3): out of the grid, still in the store.
    @ObservationIgnored private var hiddenIDs: Set<UUID> = []
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isStale = true

    static let pageSize = 60
    /// Reloads keep at most this many already loaded cards (§7.3).
    static let maxReloadCount = 1_200

    init(store: ClipboardStore) {
        self.store = store
    }

    var query: HistoryQuery {
        HistoryQuery(scope: scope, search: search, kinds: kindFilter.kinds, since: periodFilter.since(now: Date()))
    }

    /// The sidebar or the filter bar narrows what the grid shows.
    var isFiltered: Bool { scope != .all || kindFilter != .all || periodFilter != .anyTime }

    func clearFilters() {
        scope = .all
        kindFilter = .all
        periodFilter = .anyTime
    }

    /// For `List(selection:)`; deselecting falls back to History.
    var sidebarSelection: HistoryScope? {
        get { scope }
        set { scope = newValue ?? .all }
    }

    var selectedCard: HistoryCard? {
        selectedID.flatMap { id in cards.first { $0.id == id } }
    }

    var selectedIndex: Int? {
        selectedID.flatMap { id in cards.firstIndex { $0.id == id } }
    }

    // MARK: Lifecycle

    /// Panel opens: fresh search, the selection on the card the clipboard holds — none when it holds
    /// something that is not in history (§8.1, §8.2). Coming back from a record or Settings keeps
    /// the search and the selection.
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

    /// The clipboard changed while the panel is open: the selection follows it unless the user moved it.
    func clipboardDidChange() {
        if followsClipboard { applyLoadedSelection(defaultSelection()) }
    }

    /// Empty search: the card the clipboard holds, or nothing. A search: its first result.
    private func defaultSelection() -> UUID? {
        guard search.isEmpty else { return cards.first?.id }
        guard let id = clipboardRecordID(), cards.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func deactivate() {
        isActive = false
    }

    /// Window closed for 10 s or memory pressure (§7.3).
    func purge() {
        guard !isActive else { return }
        generation += 1
        cards = []
        apps = []
        collections = []
        memberships = [:]
        isStale = true
    }

    /// Something in the store changed. Reloads now if the panel is visible, else on next open.
    func storeDidChange() {
        guard isActive else {
            isStale = true
            return
        }
        reload(selectFirst: false, animated: true)
        reloadSidebar(after: .milliseconds(300))
    }

    /// Waits until the grid shows the results for the current search, so ↩ and ⌘1…⌘9 act on
    /// what the user typed rather than on the previous query (§3.4).
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

    /// Cards and count for the current query. The sidebar lists scan the whole history, so they
    /// reload separately (on open and after store changes), never per keystroke (§8.6).
    /// - Parameter animated: new and removed cards fade and scale in (store changes, not searches).
    func reload(selectFirst: Bool, animated: Bool = false) {
        generation += 1
        let generation = generation
        let revision = selectionRevision
        let query = query
        let limit = min(max(Self.pageSize, cards.count), Self.maxReloadCount)
        reloadTask = Task {
            do {
                async let page = store.page(query, offset: 0, limit: limit)
                async let count = store.count(query)
                let (loaded, total) = try await (page, count)
                let memberships = try await store.memberships(of: loaded.map(\.id))
                guard generation == self.generation else { return }
                let visible = loaded.filter { !hiddenIDs.contains($0.id) }
                withAnimation(animated ? .spring(response: 0.35, dampingFraction: 0.82) : nil) { cards = visible }
                self.memberships = memberships
                totalCount = max(0, total - (loaded.count - visible.count))
                markedIDs.formIntersection(visible.map(\.id))
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

    private func applyLoadedSelection(_ id: UUID?) {
        isApplyingLoadedSelection = true
        selectedID = id
        isApplyingLoadedSelection = false
    }

    /// Next page when one of the last cards appears.
    func cardAppeared(_ card: HistoryCard) {
        guard !isLoadingMore, cards.count < totalCount,
              let index = cards.lastIndex(where: { $0.id == card.id }), index >= cards.count - 12 else { return }
        isLoadingMore = true
        let generation = generation
        let query = query
        let offset = cards.count
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await store.page(query, offset: offset, limit: Self.pageSize),
                  generation == self.generation else { return }
            let known = Set(cards.map(\.id))
            let added = page.filter { !known.contains($0.id) && !hiddenIDs.contains($0.id) }
            let memberships = (try? await store.memberships(of: added.map(\.id))) ?? [:]
            guard generation == self.generation else { return }
            cards += added
            self.memberships.merge(memberships) { _, new in new }
        }
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

    // MARK: Collections (§3.5)

    /// Names of the collections a loaded card is in, in sidebar order.
    func collectionNames(of recordID: UUID) -> [String] {
        guard let ids = memberships[recordID], !ids.isEmpty else { return [] }
        return collections.filter { ids.contains($0.id) }.map(\.name)
    }

    /// Shows a membership change at once, also while the panel is hidden behind a record window.
    func setMembershipLocally(record: UUID, collection: UUID, isMember: Bool) {
        var ids = memberships[record] ?? []
        if isMember { ids.insert(collection) } else { ids.remove(collection) }
        memberships[record] = ids
    }

    /// Collections and the memberships of the loaded cards, even while the panel is closed (the
    /// record window shows them).
    func refreshCollections() {
        reloadSidebar()
        let ids = cards.map(\.id)
        Task {
            guard let loaded = try? await store.memberships(of: ids) else { return }
            memberships.merge(loaded) { _, new in new }
            for id in ids where loaded[id] == nil { memberships[id] = nil }
        }
    }

    // MARK: Several selected cards

    /// The selected cards in grid order: the marked ones and the cursor.
    var selection: [UUID] {
        guard !markedIDs.isEmpty else { return selectedID.map { [$0] } ?? [] }
        let chosen = markedIDs.union(selectedID.map { [$0] } ?? [])
        return cards.map(\.id).filter { chosen.contains($0) }
    }

    func isSelected(_ id: UUID) -> Bool {
        id == selectedID || markedIDs.contains(id)
    }

    /// A click: alone selects one card, ⌘ adds or removes one, ⇧ selects the range from the cursor.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            var marked = markedIDs
            if marked.isEmpty, let current = selectedID { marked.insert(current) }
            if marked.contains(id), marked.count > 1 {
                marked.remove(id)
                selectedID = cards.first { marked.contains($0.id) }?.id
            } else {
                marked.insert(id)
                selectedID = id
            }
            markedIDs = marked.count > 1 ? marked : []
        } else if modifiers.contains(.shift), let anchor = selectedIndex, let target = cards.firstIndex(where: { $0.id == id }) {
            let range = min(anchor, target)...max(anchor, target)
            markedIDs = Set(cards[range].map(\.id))
            selectedID = id
        } else {
            markedIDs = []
            selectedID = id
        }
    }

    /// ⇧-arrows: the selection grows with the cursor.
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

    // MARK: Deletion with Undo (§8.3)

    func hide(_ ids: Set<UUID>) {
        hiddenIDs.formUnion(ids)
        removeLocally(ids)
    }

    /// Undo: the cards come back.
    func unhide(_ ids: Set<UUID>) {
        hiddenIDs.subtract(ids)
        storeDidChange()
    }

    /// The store deleted them: nothing to hide any more.
    func forgetHidden(_ ids: Set<UUID>) {
        hiddenIDs.subtract(ids)
    }

    // MARK: Local updates after a command

    /// Removes deleted cards right away; the selection moves to the next card (§8.3 ⌘⌫).
    func removeLocally(_ ids: Set<UUID>) {
        let selected = selectedIndex
        let remaining = cards.enumerated().filter { !ids.contains($0.element.id) }
        let removed = cards.count - remaining.count
        withAnimation(.easeOut(duration: 0.2)) { cards = remaining.map(\.element) }
        totalCount = max(0, totalCount - removed)
        if let selected, let id = selectedID, ids.contains(id) {
            let next = remaining.first { $0.offset > selected } ?? remaining.last
            selectedID = next?.element.id
        }
        markedIDs.subtract(ids)
    }

    func replaceLocally(_ card: HistoryCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card }
    }

    // MARK: Selection (§8.3)

    func moveSelection(by offset: Int, keepingMarks: Bool = false) {
        guard !cards.isEmpty else { return }
        if !keepingMarks { clearMarks() }
        // Nothing selected (the clipboard holds something else): the first move lands on the first card.
        guard let current = selectedIndex else {
            selectedID = cards.first?.id
            return
        }
        let next = min(max(current + offset, 0), cards.count - 1)
        selectedID = cards[next].id
    }

    func moveSelectionVertically(_ rows: Int) {
        moveSelection(by: rows * max(columns, 1))
    }

    func card(at visibleIndex: Int) -> HistoryCard? {
        cards.indices.contains(visibleIndex) ? cards[visibleIndex] : nil
    }

    var isStaleForOpen: Bool { isStale }
}

/// The kinds in the filter bar (§8.2). PDFs count as images, mixed copies as text.
enum KindFilter: CaseIterable, Hashable {
    case all, text, links, images, files, colors

    var kinds: Set<DisplayType> {
        switch self {
        case .all: []
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
        }
    }
}

/// The period in the filter bar (§8.2), by when a record was last copied.
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
