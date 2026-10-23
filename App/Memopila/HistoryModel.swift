import Foundation
import MemopilaCore
import MemopilaServices
import Observation

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
    private(set) var cards: [HistoryCard] = []
    private(set) var totalCount = 0
    var selectedID: UUID?
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
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isStale = true

    static let pageSize = 60
    /// Reloads keep at most this many already loaded cards (§7.3).
    static let maxReloadCount = 1_200

    init(store: ClipboardStore) {
        self.store = store
    }

    var query: HistoryQuery { HistoryQuery(scope: scope, search: search) }

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

    /// Panel opens: fresh search, selection on the first card (§8.1).
    func activate() {
        isActive = true
        if !search.isEmpty { search = "" }
        searchTask?.cancel()
        reload(selectFirst: true)
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
        if isActive { reload(selectFirst: false) } else { isStale = true }
    }

    // MARK: Loading

    func reload(selectFirst: Bool) {
        generation += 1
        let generation = generation
        let query = query
        let limit = min(max(Self.pageSize, cards.count), Self.maxReloadCount)
        Task {
            do {
                async let page = store.page(query, offset: 0, limit: limit)
                async let count = store.count(query)
                async let apps = store.apps()
                async let types = store.displayTypes()
                async let collections = store.collections()
                let result = try await (page, count, apps, types, collections)
                let memberships = try await store.memberships(of: result.0.map(\.id))
                guard generation == self.generation else { return }
                cards = result.0
                self.memberships = memberships
                totalCount = result.1
                self.apps = result.2
                self.types = result.3
                self.collections = result.4
                loadError = nil
                isStale = false
                if selectFirst || selectedIndex == nil { selectedID = cards.first?.id }
            } catch {
                guard generation == self.generation else { return }
                loadError = error.localizedDescription
            }
        }
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
            let added = page.filter { !known.contains($0.id) }
            let memberships = (try? await store.memberships(of: added.map(\.id))) ?? [:]
            guard generation == self.generation else { return }
            cards += added
            self.memberships.merge(memberships) { _, new in new }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            reload(selectFirst: true)
        }
    }

    // MARK: Local updates after a command

    /// Removes deleted cards right away; the selection moves to the next card (§8.3 ⌘⌫).
    func removeLocally(_ ids: Set<UUID>) {
        let selected = selectedIndex
        let remaining = cards.enumerated().filter { !ids.contains($0.element.id) }
        let removed = cards.count - remaining.count
        cards = remaining.map(\.element)
        totalCount = max(0, totalCount - removed)
        if let selected, let id = selectedID, ids.contains(id) {
            let next = remaining.first { $0.offset > selected } ?? remaining.last
            selectedID = next?.element.id
        }
    }

    func replaceLocally(_ card: HistoryCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card }
    }

    // MARK: Selection (§8.3)

    func moveSelection(by offset: Int) {
        guard !cards.isEmpty else { return }
        let current = selectedIndex ?? 0
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
