import AppKit
import Observation

/// Wires the monitor, the history panel and the global hotkey together (PLAN §7.1).
@MainActor
@Observable
final class AppModel {
    let monitor = ClipboardMonitor()
    @ObservationIgnored private(set) var panel: PanelController!

    private(set) var shortcut: HotKeyCenter.Shortcut
    private(set) var hotKeyError: String?
    @ObservationIgnored private var hotKeyID: UInt32?

    // Panel UI state, reset on every open (§8.1).
    var searchText = ""
    var selectedID: HistoryEntry.ID?
    var isPinned = false
    /// Bumped on every open so the panel re-focuses search.
    private(set) var openCount = 0

    init() {
        shortcut = Preferences.shortcut ?? .defaultShortcut
        panel = PanelController(model: self)
    }

    func start() {
        registerHotKey(shortcut)
        monitor.start()
    }

    var filteredHistory: [HistoryEntry] {
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return monitor.history }
        return monitor.history.filter { entry in
            words.allSatisfy { entry.searchText.localizedStandardContains($0) }
        }
    }

    func restoreSelected(plainText: Bool = false) {
        guard let id = selectedID ?? filteredHistory.first?.id,
              let entry = monitor.history.first(where: { $0.id == id }) else { return }
        restore(entry, plainText: plainText)
    }

    func restore(_ entry: HistoryEntry, plainText: Bool = false) {
        guard monitor.restore(entry, plainText: plainText) else { return }
        if !isPinned { panel.close() }
    }

    func copy(text: String?, from entry: HistoryEntry) {
        guard let text, monitor.copy(text: text, from: entry) else { return }
        if !isPinned { panel.close() }
    }

    func moveSelection(by offset: Int) {
        let entries = filteredHistory
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selectedID } ?? 0
        selectedID = entries[min(max(current + offset, 0), entries.count - 1)].id
    }

    func panelWillShow() {
        searchText = ""
        selectedID = monitor.history.first?.id
        openCount += 1
    }

    // MARK: Hotkey (§2): the new combination is registered while the old one stays active.

    @discardableResult
    func setShortcut(_ newShortcut: HotKeyCenter.Shortcut) -> Bool {
        guard newShortcut != shortcut || hotKeyID == nil else { return true }
        let previousID = hotKeyID
        guard registerHotKey(newShortcut) else { return false }
        if let previousID { HotKeyCenter.shared.unregister(previousID) }
        shortcut = newShortcut
        Preferences.shortcut = newShortcut
        return true
    }

    @discardableResult
    private func registerHotKey(_ shortcut: HotKeyCenter.Shortcut) -> Bool {
        switch HotKeyCenter.shared.register(shortcut, action: { [weak self] in self?.panel.toggle() }) {
        case .success(let id):
            hotKeyID = id
            hotKeyError = nil
            return true
        case .failure(let error):
            hotKeyError = error.message(for: shortcut)
            return false
        }
    }
}
