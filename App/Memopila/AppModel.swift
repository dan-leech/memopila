import AppKit
import MemopilaCore
import MemopilaServices
import Observation
import SwiftUI

/// Panel overlays (§8.4). Shown inside the panel; a record opens in its own window (§8.5).
enum PanelOverlay: Equatable {
    case rename(HistoryEntry.ID)
    case actions(HistoryEntry.ID)
    case newCollection(addingRecord: UUID?)
    case renameCollection(UUID)
    case confirmDelete([UUID])
    /// Everything shown, from an app or in a collection: favorites kept unless asked.
    case confirmDeleteMany(DeleteManyScope, others: [UUID], favorites: [UUID])
    case confirmDeleteCollection(UUID)
    /// Taking cards out of Favorites deletes those older than History keeps (§6): asked first.
    case confirmUnfavorite([UUID], old: Int)
    case confirmClear
    /// ⌘/ — every shortcut of the panel (§8.3).
    case shortcuts
    case newStack
}

/// What *Delete All…* deletes, for its question.
enum DeleteManyScope: Equatable {
    case shown
    case app(String)
    case collection(String)
}

enum RestoreVariant: Equatable {
    case original
    case plainText
    case textAction(TextAction)
    case recognizedText

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .plainText: String(localized: "Plain Text")
        case .textAction(let action): action.title
        case .recognizedText: String(localized: "Text from Image")
        }
    }
}

/// Five tabs (first-run feedback: seven, with Formats repeating Apps, were too many).
enum SettingsTab: String, Hashable, CaseIterable {
    case general, history, privacy, apps, about
}

enum HotKeyRole: CaseIterable {
    case window, pause, skip
}

/// Wires settings, store, monitor, history and the panel together and owns every user command
/// (PLAN §7.1). Views render DTOs and call these methods; they never touch the store directly.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    let history: HistoryModel
    let toasts = ToastCenter()
    let thumbnails: ThumbnailCache
    @ObservationIgnored private(set) var panel: PanelController!
    @ObservationIgnored private(set) var windows: SecondaryWindows!
    private let recognition: RecognitionService
    /// The history file could not be opened; history is kept in memory until relaunch.
    let storeOpenError: String?
    /// The previous history could not be opened and was moved here; a new one started (§7.2).
    private(set) var storeMovedAside: URL?

    private(set) var overlay: PanelOverlay?
    private(set) var actionsState: ActionsPanelState?
    private(set) var itemState: ItemState?
    var isPinned = false
    /// ⌘ is held in the panel: cards show their ⌘1…⌘9 shortcuts.
    var isCommandHeld = false
    /// ⌥ is held in the panel: the gear menu also offers Diagnostics.
    var isOptionHeld = false
    /// The card just chosen while the window is pinned; it shows a checkmark for a moment.
    private(set) var chooseBadgeCardID: UUID?
    /// Stack card Choose badge (Choose only — not every advance, P37 chrome).
    private(set) var chooseBadgeStackID: UUID?
    /// The badge on that card says Pasted rather than On Clipboard.
    private(set) var chooseBadgeWasPasted = false
    /// Armed paste-stack session (§3.11).
    @ObservationIgnored private(set) var stackSession: StackSessionController!
    /// Panel card-drag SSOT (§3.11 drop contract).
    @ObservationIgnored private(set) var stackDrag = StackDragSession()
    /// Open Stack Window state (nil when closed).
    private(set) var stackEditor: StackEditorState?
    /// Status-item tooltip / Stop affordance bump.
    private(set) var stackStatusRevision = 0
    /// Bumped whenever search should take focus (open, ⌘F, overlay closed).
    private(set) var focusSearchToken = 0
    /// Bumped when a click on a card takes the keyboard from the search to the cards.
    private(set) var focusGridToken = 0
    /// The keyboard is on the cards: plain ⌫ deletes them. In the search it only edits the text,
    /// also when the search is empty (user feedback).
    @ObservationIgnored var gridHasFocus = false
    private(set) var hotKeyErrors: [HotKeyRole: String] = [:]
    var settingsApp: String?

    @ObservationIgnored private var hotKeyIDs: [HotKeyRole: UInt32] = [:]
    @ObservationIgnored private(set) var previousApp: NSRunningApplication?
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var dailyTimer: Timer?
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    /// Where the menu bar icon is, for Diagnostics (a crowded menu bar hides it under the notch).
    @ObservationIgnored var statusItemDescription: (() -> String)?
    /// Settings or Diagnostics hid the panel; it comes back when that window closes (as in Pasta).
    @ObservationIgnored private var panelHiddenForWindow = false

    init() {
        let settings = SettingsStore()
        self.settings = settings
        var openError: String?
        var movedAside: URL?
        let store: ClipboardStore
        do {
            let opened = try ClipboardStore.openRecovering(at: ClipboardStore.defaultURL)
            store = opened.store
            movedAside = opened.movedTo
        } catch {
            openError = error.localizedDescription
            // In-memory fallback keeps the app usable; the banner says history is not kept.
            store = try! ClipboardStore(url: nil)
        }
        storeOpenError = openError
        // The banner stays until dismissed, also after a relaunch (review finding: on the next
        // launch nothing said where the old history went).
        if let movedAside {
            UserDefaults.standard.set(movedAside.path, forKey: Self.movedAsideKey)
            storeMovedAside = movedAside
        } else if let path = UserDefaults.standard.string(forKey: Self.movedAsideKey), FileManager.default.fileExists(atPath: path) {
            storeMovedAside = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.movedAsideKey)
            storeMovedAside = nil
        }
        self.store = store
        monitor = ClipboardMonitor(settings: settings, store: store)
        history = HistoryModel(store: store)
        thumbnails = ThumbnailCache(store: store)
        recognition = RecognitionService(store: store, settings: settings)
        panel = PanelController(model: self)
        windows = SecondaryWindows(model: self)
        stackSession = StackSessionController(model: self)

        // The panel, or a window of Memopila's own while it is the active app (the record window,
        // Settings): what is copied there is Memopila's (review finding: it was Unknown).
        monitor.panelIsKey = { [weak self] in self?.memopilaUIKey ?? false }
        monitor.onSaved = { [weak self] id in self?.didSave(id) }
        monitor.onExternalClipboardChange = { [weak self] in self?.stackSession.stop(toast: true) }
        monitor.onStackIdentitySuperseded = { [weak self] in
            guard let self, self.stackSession.isArmed else { return }
            self.stackSession.stop(toast: true)
        }
        history.clipboardRecordID = { [weak monitor] in monitor?.clipboardRecordID }
        history.clipboardStackID = { [weak monitor] in monitor?.clipboardStackID }
        recognition.onUpdate = { [weak self] id, state in
            if state == .done { self?.history.storeDidChange() }
            // The record window shows the result under the image.
            if self?.itemState?.id == id { self?.recognitionTick += 1 }
        }
        settings.onRetentionChange = { [weak self] in self?.runRetention() }
        settings.onRecognitionChange = { [weak self] bundleID in self?.enableRecognition(forApp: bundleID) }
    }

    func start() {
        for role in HotKeyRole.allCases {
            if let shortcut = shortcut(for: role) { register(shortcut, for: role) }
        }
        monitor.start()
        runRetention()
        prunePreviewFiles(all: true)
        reclassifyRichTextOnce()
        recognition.wake()
        let daily = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runRetention() }
        }
        RunLoop.main.add(daily, forMode: .common)
        dailyTimer = daily
        observeMemoryPressure()
    }

    // MARK: Overlays

    /// Shows an overlay (or `nil` to close it). Search takes focus again when an overlay closes
    /// while the panel stays open — not when the panel itself is closing (`refocusSearch: false`),
    /// or FocusState can re-key an ordered-out panel and skip auto-paste.
    func present(_ next: PanelOverlay?, refocusSearch: Bool = true) {
        if next == nil { pendingStackRecordIDs = nil }
        switch next {
        case .actions(let entryID)?:
            let selection = history.selection
            let items: [ActionItem]
            if selection.count > 1 {
                items = ActionRegistry.selectionActions(selection, model: self)
            } else if case .record(let id) = entryID, let card = history.cards.first(where: { $0.id == id }) {
                items = ActionRegistry.cardActions(card, model: self)
            } else if case .stack(let id) = entryID,
                      let stack = history.stacks.first(where: { $0.id == id })
                        ?? history.allStacks.first(where: { $0.id == id }) {
                items = ActionRegistry.stackActions(stack, model: self)
            } else {
                return
            }
            actionsState = ActionsPanelState(items: items.flatMap { $0.flattened() })
        default:
            actionsState = nil
        }
        overlay = next
        if next == nil, refocusSearch { focusSearch() }
    }

    /// Seed members for New Stack… (one card or multi-select); cleared when the overlay closes.
    @ObservationIgnored private var pendingStackRecordIDs: [UUID]?

    func presentNewStack(records: [UUID]? = nil) {
        pendingStackRecordIDs = records
        present(.newStack)
    }

    func focusSearch() {
        gridHasFocus = false
        focusSearchToken += 1
    }

    func focusGrid() {
        gridHasFocus = true
        focusGridToken += 1
    }

    func runHighlightedAction() {
        guard let action = actionsState?.highlightedAction, action.isEnabled else { return }
        present(nil)
        action.run?()
    }

    // MARK: Record window (§8.5, §3.6)

    /// *Edit Record* (Space, ⌘E, the pencil): the record opens in its own window, which replaces the
    /// panel as Settings does and can be moved and resized. `focusText` puts the cursor in the text (⌘E).
    func openRecord(_ id: UUID, focusText: Bool = false) {
        if let itemState, itemState.id == id {
            hidePanelForWindow()
            windows.showRecord(focusText: false)
            if focusText, itemState.isEditable { itemState.focus() }
            return
        }
        // Another record with unsaved text open: Save / Don't Save / Cancel first (review finding:
        // opening one from the panel replaced the edit without asking).
        if let itemState, itemState.isDirty {
            hidePanelForWindow()
            windows.showRecord(focusText: false)
            return resolveUnsavedChanges { [weak self] in self?.openRecord(id, focusText: focusText) }
        }
        Task { await openRecordAsync(id, focusText: focusText) }
    }

    private func openRecordAsync(_ id: UUID, focusText: Bool) async {
        let card: HistoryCard
        if let local = history.cards.first(where: { $0.id == id })
            ?? stackEditor?.members.first(where: { $0.id == id }) {
            card = local
        } else if let loaded = try? await store.card(id) {
            card = loaded
        } else {
            return
        }
        itemState?.loadTask?.cancel()
        let state = ItemState(card: card, focusOnLoad: focusText && Self.isEditable(card), maxBytes: settings.maxItemBytes)
        itemState = state
        if history.selectedID != .record(id) { history.selectedID = .record(id) }
        hidePanelForWindow()
        windows.showRecord(focusText: state.focusOnLoad)
        guard state.hasText else { return }
        state.loadTask = Task { await loadText(into: state) }
    }

    /// Formatted records open formatted when their RTF or HTML can be read, others as plain text.
    private func loadText(into state: ItemState) async {
        if state.isEditable, (try? await store.itemCount(state.id)) ?? 1 > 1 {
            guard !Task.isCancelled, itemState === state else { return }
            state.makeReadOnly()
        }
        let expectRich = state.card.displayType == .richText
        if expectRich, let rich = await editorRichText(state.id) {
            guard !Task.isCancelled, itemState === state else { return }
            state.load(rich: rich.text, background: rich.background)
        } else if let text = await editorText(state.id) {
            guard !Task.isCancelled, itemState === state else { return }
            state.load(text)
            if expectRich {
                toasts.show(String(localized: "Formatting could not be loaded; showing plain text."))
            }
        } else if itemState === state {
            state.error = String(localized: "The text could not be loaded.")
        }
    }

    /// ‹ › and ← → in the record window: the previous or next record of the panel's list. Close to
    /// the end of what is loaded, the next page loads, so ‹ › go through the whole list.
    func openAdjacentRecord(_ offset: Int, vertically: Bool = false) {
        guard let state = itemState else { return }
        // Unsaved text: Save / Don't Save / Cancel first, then go on (first-run feedback: the arrows
        // simply stopped working).
        guard !state.isDirty else {
            return resolveUnsavedChanges { [weak self] in self?.openAdjacentRecord(offset, vertically: vertically) }
        }
        saveTitle()
        // Record window navigates records only (skips stack entries, §8.4).
        for _ in 0..<max(history.entries.count, 1) {
            if vertically {
                history.moveSelectionVertically(offset)
            } else {
                history.moveSelection(by: offset)
            }
            if let card = history.selectedCard {
                history.cardAppeared(card)
                if card.id != state.id { openRecord(card.id) }
                return
            }
        }
    }

    /// The title saves itself when its field is left or ↩ is pressed, and before the record
    /// window moves on or closes (first-run feedback: a separate Save for a title was one step too many).
    func saveTitle() {
        guard let change = takeTitleChange() else { return }
        Task { await persist(change) }
    }

    /// The changed title, marked saved at once so closing or moving on does not save it twice.
    private func takeTitleChange() -> (id: UUID, title: String)? {
        guard let state = itemState, state.titleChanged else { return nil }
        state.titleSaved()
        return (state.id, state.title)
    }

    private func persist(_ change: (id: UUID, title: String)) async {
        do {
            try await store.rename(change.id, title: change.title)
        } catch {
            toasts.error(error.localizedDescription)
        }
        history.storeDidChange()
    }

    /// Esc, Space: unsaved text asks first (Save / Don't Save / Cancel), then the window closes.
    func dismissRecord() {
        resolveUnsavedChanges { [weak self] in self?.closeRecord() }
    }

    /// The close button or ⌘W: `false` keeps the window open while the sheet asks.
    func recordMayClose() -> Bool {
        if let state = itemState, state.isDirty {
            resolveUnsavedChanges { [weak self] in self?.closeRecord() }
            return false
        }
        saveTitle()
        return true
    }

    /// With unsaved text, the standard sheet: *Save* saves and goes on, *Don't Save* drops the edit
    /// and goes on, *Cancel* stays (first-run feedback: an inline question in the status bar was easy
    /// to miss). Without unsaved text it goes on at once.
    func resolveUnsavedChanges(then proceed: @escaping @MainActor () -> Void, onCancel: @escaping @MainActor () -> Void = {}) {
        guard let state = itemState, state.isDirty else { return proceed() }
        windows.askToSaveRecord { [weak self] choice in
            switch choice {
            case .save:
                Task {
                    guard let self, await self.saveText() else { return onCancel() }
                    proceed()
                }
            case .discard:
                // Only the text: a changed title saves itself, as it would on leaving the field —
                // stored before going on, so quitting does not lose it (review finding).
                guard let self else { return }
                let change = self.takeTitleChange()
                state.revert()
                Task {
                    if let change { await self.persist(change) }
                    proceed()
                }
            case .cancel:
                onCancel()
            }
        }
    }

    /// The panel comes back, unless the record went to the clipboard: then the focus goes back to
    /// the app the user came from, as after a double-click (a pinned panel still comes back).
    func closeRecord(returningToPanel: Bool = true) {
        saveTitle()
        windows.closeRecord(returningToPanel: returningToPanel || isPinned)
    }

    /// The record window closed, whichever way.
    func recordWindowDidClose() {
        itemState = nil
    }

    /// Save (⌘S): the text is saved and the window stays open — only Choose for Clipboard and Esc close it.
    func saveItem() {
        Task { await saveText() }
    }

    /// The title, then the text if it changed. `true` when nothing is left unsaved. A merge into an
    /// existing record (§3.6) shows that record in the window.
    @discardableResult
    func saveText() async -> Bool {
        guard let state = itemState, !state.isSaving else { return false }
        // The title first, awaited: an edit that merges into another record keeps the edited
        // record's new title only if it is stored before the merge (§3.6; review finding).
        if let change = takeTitleChange() { await persist(change) }
        guard state.isTextDirty else { return true }
        guard let text = state.currentText(), !text.isEmpty else {
            state.error = String(localized: "The text is empty.")
            return false
        }
        // Formatted text is saved as RTF and HTML besides the plain text.
        let rich = state.richContent()
        if state.isRich, rich == nil {
            state.error = String(localized: "The formatting could not be saved.")
            return false
        }
        let savedRich = state.isRich ? state.textView?.textStorage?.copy() as? NSAttributedString : nil
        state.isSaving = true
        let error = await saveEdit(state.id, text: text, rich: rich, savedRich: savedRich)
        state.isSaving = false
        state.error = error
        return error == nil
    }

    /// *Choose for Clipboard* in the record window (↩, ⌘↩; ⌥↩ also pastes): unsaved changes are saved first.
    func copyItem(paste: Bool? = nil) {
        guard let state = itemState else { return }
        if state.isDirty {
            // After a merge the window shows the surviving record, which is then the one selected.
            Task { if await saveText() { copyItem(paste: paste) } }
            return
        }
        if paste == true, !AccessibilityBridge.isTrusted {
            AccessibilityBridge.requestTrust()
            toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
            return
        }
        closeRecord(returningToPanel: false)
        restore(state.id, paste: paste)
    }

    /// Once after the update that weighs formatting: rich text cards whose formatting says nothing
    /// (one font in one colour) become text, as new copies are (owner feedback).
    private func reclassifyRichTextOnce() {
        let key = "reclassifiedRichText1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let store = store
        Task {
            guard let changed = try? await store.reclassifyRichText() else { return }
            UserDefaults.standard.set(true, forKey: key)
            if changed > 0 { history.storeDidChange() }
        }
    }

    /// Images and PDFs handed to Preview. They go with their records, and all at launch (review
    /// finding: a screenshot set to be deleted after 15 minutes stayed in the temporary folder).
    private static let previewFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Memopila", isDirectory: true)

    private func prunePreviewFiles(all: Bool = false) {
        let store = store
        let folder = Self.previewFolder
        Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                if !all, let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                   (try? await store.card(id)) != nil { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The image or PDF of a record in Preview, from a temporary file (§8.5).
    func openInPreview(_ id: UUID) {
        Task {
            guard let payload = try? await store.payload(for: id) else {
                return toasts.error(String(localized: "The item no longer exists."))
            }
            let preferred: [(PasteboardType, String)] = [(.pdf, "pdf"), (.png, "png"), (.jpeg, "jpg"), (.heic, "heic"), (.gif, "gif"), (.tiff, "tiff")]
            let representations = payload.items.flatMap(\.representations)
            guard let match = preferred.first(where: { candidate in representations.contains { $0.type == candidate.0 } }),
                  let bytes = representations.first(where: { $0.type == match.0 })?.bytes else {
                return toasts.error(String(localized: "This item has no image to open."))
            }
            let folder = Self.previewFolder
            let url = folder.appendingPathComponent(id.uuidString).appendingPathExtension(match.1)
            // Off the main thread: a large image or PDF takes a while to write (review finding).
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try bytes.write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { return toasts.error(failure) }
            let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
            do {
                External.announce()
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                toasts.error(error.localizedDescription)
            }
        }
    }

    // MARK: Panel lifecycle (§8.1, §7.3)

    /// `keepingState`: back from a record or Settings, with the same search and selection.
    func panelWillShow(keepingState: Bool = false) {
        // Shown by hand (hotkey, menu bar) while a window replaced it: that window no longer owes it.
        panelHiddenForWindow = false
        refreshPreviousApp()
        purgeTask?.cancel()
        present(nil)
        toasts.dismiss()
        history.activate(keepingState: keepingState)
        focusSearch()
    }

    /// The app that keeps the focus behind the non-activating panel: the target of auto-paste after Choose for Clipboard.
    func refreshPreviousApp() {
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.bundleIdentifier == ClipboardMonitor.ownBundleID ? nil : $0
        } ?? monitor.lastOtherApp ?? previousApp
    }

    func panelDidClose() {
        // Do not focus search here: the panel is already ordered out, and focusing the field can
        // make it key again — then auto-paste sees `panel.isKey` and skips ⌘V.
        present(nil, refocusSearch: false)
        endCardDrag()
        isCommandHeld = false
        history.deactivate()
        purgeTask?.cancel()
        purgeTask = Task { [weak self] in
            // Not while a record or Settings replaces the panel: it comes back with the same cards.
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                if !self.windows.isAnyVisible { return self.purgeCaches() }
            }
        }
    }

    private func purgeCaches() {
        history.purge()
        thumbnails.removeAll()
    }

    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thumbnails.removeAll()
                if !self.panel.isVisible { self.history.purge() }
                self.recognition.postpone()
            }
        }
        source.activate()
        memoryPressure = source
    }

    // MARK: Capture follow-ups

    private func didSave(_ id: UUID) {
        rescueFromPendingDeletion(id)
        history.storeDidChange()
        recognition.wake()
        // Age and expiry after a successful ingest (§6), coalesced.
        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.runRetention()
        }
    }

    /// Age, short retention and count cap (§6); re-arms the expiry timer for the nearest `expiresAt`.
    func runRetention() {
        let limits = settings.retentionLimits
        Task {
            do {
                let next = try await store.applyRetention(limits: limits, now: Date())
                history.storeDidChange()
                armExpiry(next)
                prunePreviewFiles()
            } catch {
                // The store failed this time: try again in a minute instead of dropping the timer
                // (review finding: a "delete after 8 hours" secret could outlive it).
                armExpiry(Date().addingTimeInterval(60))
            }
        }
    }

    private func armExpiry(_ date: Date?) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let date else { return }
        let fireDate = max(date, Date().addingTimeInterval(30))
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func enableRecognition(forApp bundleID: String?) {
        Task {
            try? await store.setRecognitionState(forApp: bundleID, enabled: true)
            recognition.wake()
        }
    }

    // MARK: Restore (§3.4)

    /// ↩, ⌘C: waits for a pending search so the restored card is the one the results show. Nothing
    /// selected (the clipboard holds something not in history) → nothing to do; several → an error.
    func restoreSelected(paste: Bool? = nil) {
        Task {
            await history.settle()
            guard let entryID = singleSelection() else { return }
            switch entryID {
            case .record(let id):
                await performRestore(id, paste: paste)
            case .stack(let id):
                chooseStack(id, paste: paste)
            }
        }
    }

    func restoreVisible(_ index: Int) {
        Task {
            await history.settle()
            guard let entry = history.entry(at: index) else { return }
            history.selectedID = entry.id
            switch entry {
            case .record(let card):
                await performRestore(card.id)
            case .stack(let stack):
                chooseStack(stack.id)
            }
        }
    }

    func restore(_ id: UUID, paste: Bool? = nil) {
        Task { await performRestore(id, paste: paste) }
    }

    /// *Choose for Clipboard* from a card's menu: several selected cards cannot all go to the clipboard.
    func choose(_ id: UUID, paste: Bool? = nil) {
        if history.selection.count > 1, history.isSelected(.record(id)) {
            _ = singleSelection()
            return
        }
        restore(id, paste: paste)
    }

    var memopilaUIKey: Bool {
        panel.isKey || windows.anySecondaryIsKey || (NSApp.isActive && NSApp.keyWindow != nil)
    }

    func statusStackDidChange() {
        stackStatusRevision += 1
        stackSession.refreshEscapeGate()
    }

    func showStackChooseBadge(_ stackID: UUID, pasted: Bool) {
        chooseBadgeStackID = stackID
        chooseBadgeCardID = nil
        chooseBadgeWasPasted = pasted
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if self?.chooseBadgeStackID == stackID { self?.chooseBadgeStackID = nil }
        }
    }

    func stopStackSession() {
        stackSession.stop()
    }

    func chooseStack(_ id: UUID, paste: Bool? = nil) {
        resolveUnsavedChanges { [weak self] in
            self?.stackSession.chooseStack(id, paste: paste)
        }
    }

    /// Puts the item on the clipboard, moves it to the top and gives the focus back to the app the
    /// user came from, as in Pasta. *Auto-paste* (off by default) also presses ⌘V there;
    /// `paste` overrides that setting. `true` when the clipboard now holds the item.
    @discardableResult
    private func performRestore(_ id: UUID, paste: Bool? = nil) async -> Bool {
        // Choosing a member card disarms any armed stack (§8.1).
        if stackSession.isArmed { stackSession.stop(toast: false) }
        let wantsPaste = paste ?? settings.pasteAfterCopy
        // ⌥↩ (and Auto-Paste when enabled): without Accessibility do not pretend paste will happen.
        // Explicit ⌥↩ aborts before the clipboard write; the Settings toggle still chooses for
        // clipboard, then explains why ⌘V did not run (ad-hoc rebuilds often drop the TCC grant).
        if paste == true, !AccessibilityBridge.isTrusted {
            AccessibilityBridge.requestTrust()
            toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
            return false
        }
        guard let content = await variantContent(id, variant: .original) else { return false }
        switch monitor.write(content.items, sourceBundleID: content.sourceBundleID, recordID: id) {
        case .failed(let message):
            toasts.error(message)
            return false
        case .written:
            let pastes = wantsPaste && AccessibilityBridge.isTrusted
            // Memopila itself is active after a launch by hand or after Settings: the target app
            // needs a moment to take the focus back before ⌘V reaches it.
            let wasActive = NSApp.isActive
            if isPinned {
                showChooseBadge(id, pasted: pastes)
                // Pinned: the panel stays visible but gives the key focus back to the target app.
                if pastes {
                    // The panel keeps the keyboard while pinned: give it back, or ⌘V would paste
                    // into the search field (review finding).
                    panel.yieldKeyFocus()
                }
            } else {
                panel.close()
            }
            if wantsPaste, !pastes {
                AccessibilityBridge.requestTrust()
                toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
            } else if pastes {
                await pasteIntoPreviousApp(wasActive: wasActive)
            }
            try? await store.markUsed(id, at: Date())
            history.storeDidChange()
            return true
        }
    }

    /// Synthetic ⌘V into the app behind the panel. Re-yields if FocusState re-keyed the panel
    /// after close, then pastes only when Memopila is not the key window.
    func pasteIntoPreviousApp(wasActive: Bool) async {
        let target = previousApp.flatMap { $0.isTerminated ? nil : $0 }
            ?? monitor.lastOtherApp.flatMap { $0.isTerminated ? nil : $0 }
        guard let target else { return }
        _ = target.activate()
        try? await Task.sleep(for: .milliseconds(wasActive || isPinned ? 250 : 80))
        if panel.isKey {
            panel.yieldKeyFocus()
            _ = target.activate()
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !panel.isKey { AccessibilityBridge.paste() }
    }

    /// Text that is not a record yet (text found in an image, a source link, the Diagnostics report)
    /// goes to the clipboard as a new card at the top, so history always shows what the clipboard
    /// holds (§3.4). Copying part of an item keeps the window open, like ⌘C in its text.
    func copyNewText(_ text: String, from id: UUID?) {
        Task {
            let items = PasteboardWriter.plainTextItems(text)
            let sourceBundleID = id.flatMap { id in history.cards.first { $0.id == id } }?.sourceAppBundleID
            switch await ingestDerived(items, from: id) {
            case .saved(let newID):
                switch monitor.write(items, sourceBundleID: sourceBundleID, recordID: newID) {
                case .written:
                    try? await store.markUsed(newID, at: Date())
                    history.storeDidChange()
                    toasts.show(String(localized: "Copied to the clipboard and added to history"))
                case .failed(let message):
                    toasts.error(message)
                }
            case .secretNotSaved:
                // Copied as asked, but kept out of history like any other secret.
                _ = monitor.write(items, sourceBundleID: sourceBundleID, recordID: nil)
                toasts.show(String(localized: "Copied. Not added to history: it contains a secret."))
            case .failed(let message):
                toasts.error(message)
            }
        }
    }

    /// The item, or a plain-text variant of it (§3.4). Reports problems as toasts and returns `nil`.
    private func variantContent(_ id: UUID, variant: RestoreVariant) async -> (items: [CanonicalItem], sourceBundleID: String?)? {
        func fail(_ message: String) -> (items: [CanonicalItem], sourceBundleID: String?)? {
            toasts.error(message)
            return nil
        }
        do {
            switch variant {
            case .original:
                let payload = try await store.payload(for: id)
                return (payload.items, payload.sourceBundleID)
            case .plainText:
                let payload = try await store.payload(for: id)
                guard let text = payload.text else { return fail(String(localized: "This item has no text.")) }
                return (PasteboardWriter.plainTextItems(text), payload.sourceBundleID)
            case .textAction(let action):
                let payload = try await store.payload(for: id)
                guard let text = payload.text else { return fail(String(localized: "This item has no text.")) }
                let result = text.utf8.count > 100_000
                    ? await Task.detached(priority: .userInitiated) { action.apply(to: text) }.value
                    : action.apply(to: text)
                guard let result else { return fail(action.unavailableReason) }
                return (PasteboardWriter.plainTextItems(result), payload.sourceBundleID)
            case .recognizedText:
                guard let details = try await store.details(id, maxTextScalars: 0), let text = details.recognizedText else {
                    return fail(String(localized: "No text was found in this image."))
                }
                return (PasteboardWriter.plainTextItems(text), details.card.sourceAppBundleID)
            }
        } catch StoreError.notFound {
            history.storeDidChange()
            return fail(String(localized: "The item no longer exists."))
        } catch {
            return fail(String(localized: "This item can't go to the clipboard: its stored data is damaged."))
        }
    }

    private func showChooseBadge(_ id: UUID, pasted: Bool) {
        chooseBadgeCardID = id
        chooseBadgeWasPasted = pasted
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if self?.chooseBadgeCardID == id { self?.chooseBadgeCardID = nil }
        }
    }

    /// ⌘+ / ⌘−: bigger or smaller cards through the grid presets.
    func changeGridDensity(by step: Int) {
        let presets = GridSize.presets
        let current = presets.firstIndex(of: settings.gridSize) ?? presets.firstIndex(of: .default) ?? 0
        let next = min(max(current + step, 0), presets.count - 1)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { settings.gridSize = presets[next] }
    }

    /// *Duplicate As ▸* (§3.9): a transformed copy becomes a new card at the top and is selected;
    /// the original stays as it is. Nothing touches the clipboard until the user copies it.
    func duplicate(_ id: UUID, as variant: RestoreVariant) {
        Task {
            guard let content = await variantContent(id, variant: variant) else { return }
            switch await ingestDerived(content.items, from: id) {
            case .saved(let newID):
                history.selectedID = .record(newID)
                history.storeDidChange()
                toasts.show(String(localized: "Duplicated as \(variant.title)"))
            case .secretNotSaved:
                toasts.error(String(localized: "Not duplicated: the text contains a secret and secrets are not saved."))
            case .failed(let message):
                toasts.error(message)
            }
        }
    }

    enum DerivedResult {
        case saved(UUID)
        /// *Secrets: Don't save* applies to it, as to any copy.
        case secretNotSaved
        case failed(String)
    }

    /// Stores content made from a record (or from nothing) as a new record with the record's source;
    /// the secret policy applies as it does to copies from other apps (§3.10).
    private func ingestDerived(_ items: [CanonicalItem], from id: UUID?) async -> DerivedResult {
        let original = id.flatMap { id in history.cards.first { $0.id == id } }
        var appSettings = original?.sourceAppBundleID.map { settings.settings(for: $0) } ?? ResolvedAppSettings()
        var sensitiveKind: SecretKind?
        if let text = TextDecoding.plainText(of: items), settings.secretPolicy != .off,
           let kind = SecretDetector.detect(text, kinds: settings.secretKinds) {
            switch settings.secretPolicy {
            case .off: break
            case .dontSave: return .secretNotSaved
            case .deleteAfter(let minutes):
                appSettings.captureMode = .deleteAfter(minutes: min(minutes, appSettings.retentionMinutes ?? minutes))
            }
            sensitiveKind = kind
        }
        // Hashing and the search text off the main thread: a large record took seconds (review finding).
        let sourceAppName = original?.sourceAppName
        let prepared = await Task.detached(priority: .userInitiated) {
            (hash: MCS1.contentHash(of: items), size: MCS1.payloadSize(of: items), type: DisplayType.classify(items),
             enrichment: IngestEnrichment.make(for: items, sourceAppName: sourceAppName))
        }.value
        let snapshot = OwnedSnapshot(
            changeCount: 0,
            observedAt: Date(),
            identity: AppIdentity(bundleID: original?.sourceAppBundleID, source: .frontmost),
            settings: appSettings,
            items: items,
            contentHash: prepared.hash,
            payloadSizeBytes: prepared.size,
            displayType: prepared.type,
            skippedTypes: [],
            sourceURL: original?.sourceURL,
            sensitiveKind: sensitiveKind
        )
        let enrichment = prepared.enrichment
        switch await store.ingest(snapshot, readerSeq: monitor.coordinator.opSeq, enrichment: enrichment, limits: settings.retentionLimits) {
        case .committed(let newID), .merged(let newID):
            // As for a capture: a pending delete of the same content is undone, retention and its
            // expiry timer run (review finding).
            didSave(newID)
            return .saved(newID)
        case .rejected(let message), .failed(let message):
            return .failed(message)
        case .dropped:
            return .failed(String(localized: "Another change is in progress. Try again."))
        }
    }

    static func isEditable(_ card: HistoryCard) -> Bool {
        [.text, .richText, .url].contains(card.displayType)
    }

    func toggleFavorite(_ id: UUID) {
        toggleFavorites([id])
    }

    /// ⌘⌫: favorites ask first (§8.3). The cards leave the grid at once; the store deletes them
    /// after a few seconds, so the toast's Undo can bring them back (first-run feedback: one
    /// keystroke lost a record for good).
    func delete(_ ids: [UUID], confirmed: Bool = false) {
        guard !ids.isEmpty else { return }
        let favorites = history.cards.filter { ids.contains($0.id) && $0.isFavorite }
        if !confirmed, !favorites.isEmpty {
            present(.confirmDelete(ids))
            return
        }
        if case .confirmDelete? = overlay { present(nil) }
        commitPendingDeletion()
        let set = Set(ids)
        history.hide(set)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, let pending = self.pendingDeletion else { return }
            self.pendingDeletion = nil
            await self.performDeletion(pending.ids)
        }
        pendingDeletion = (set, task)
        let message = ids.count == 1 ? String(localized: "Deleted") : String(localized: "Deleted \(ids.count) items")
        toasts.show(message, actions: [.init(title: String(localized: "Undo")) { [weak self] in self?.undoDeletion() }])
    }

    @ObservationIgnored private var pendingDeletion: (ids: Set<UUID>, task: Task<Void, Never>)?
    /// Favorite Tasks: only the newest op may reconcile (rapid invert allowed; stale reloads skipped).
    @ObservationIgnored private var favoriteOpGeneration = 0

    func undoDeletion() {
        guard let pending = pendingDeletion else { return }
        pending.task.cancel()
        pendingDeletion = nil
        history.unhide(pending.ids)
    }

    /// A record waiting out its Undo period came back — copied again, merged into by an edit or a
    /// derived copy: it is not deleted after all (review finding: the new copy was lost).
    private func rescueFromPendingDeletion(_ id: UUID) {
        guard let pending = pendingDeletion, pending.ids.contains(id) else { return }
        pendingDeletion = (pending.ids.subtracting([id]), pending.task)
        history.unhide([id])
    }

    /// Before quitting: the delete waiting for Undo is carried out, not forgotten.
    func commitPendingDeletionNow() async {
        guard let pending = pendingDeletion else { return }
        pending.task.cancel()
        pendingDeletion = nil
        await performDeletion(pending.ids)
    }

    /// ⌘Q: unsaved text asks first — Cancel keeps Memopila running — and a pending delete is
    /// carried out (review findings: both were lost).
    func prepareToQuit(_ reply: @escaping @MainActor (Bool) -> Void) {
        let quit: @MainActor () -> Void = { [weak self] in
            Task { @MainActor in
                // A title typed in the record window is saved before the app goes (review finding).
                if let self, let change = self.takeTitleChange() { await self.persist(change) }
                await self?.commitPendingDeletionNow()
                reply(true)
            }
        }
        guard let state = itemState, state.isDirty else { return quit() }
        windows.showRecord(focusText: false)
        resolveUnsavedChanges(then: quit) { reply(false) }
    }

    /// A second deletion does not wait for the first.
    private func commitPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pending.task.cancel()
        pendingDeletion = nil
        Task { await performDeletion(pending.ids) }
    }

    private func performDeletion(_ ids: Set<UUID>) async {
        if pendingDeletion?.ids == ids { pendingDeletion = nil }
        let store = store
        let list = Array(ids)
        for attempt in 1...3 {
            switch await monitor.destructive({ opSeq in try await store.delete(list, opSeq: opSeq) }) {
            case .success:
                for id in ids { thumbnails.invalidate(id) }
                history.forgetHidden(ids)
                history.storeDidChange()
                prunePreviewFiles()
                // Rebuild after members are gone — pre-delete rebuild kept stale IDs (P24).
                if stackSession.isArmed { stackSession.rebuildFromStore() }
                return
            case .failure(.busy) where attempt < 3:
                // Another delete, clear or edit is running; this one follows it.
                try? await Task.sleep(for: .milliseconds(500))
            case .failure(let error):
                history.unhide(ids)
                report(error)
                return
            }
        }
    }

    // MARK: Several selected cards

    /// ↩ and Choose for Clipboard with several cards selected: the clipboard holds one record.
    private func singleSelection() -> HistoryEntry.ID? {
        let selection = history.selection
        guard selection.count <= 1 else {
            toasts.error(String(localized: "Only one record can be on the clipboard. Select a single card."))
            return nil
        }
        return selection.first
    }

    /// ⌘D on several cards: all become favorites, or all stop being favorites when they all are.
    /// Out of Favorites, cards older than History keeps are deleted (§6), so that is asked first
    /// (review finding: an old favorite vanished at the next copy, with no warning).
    /// Heart flips in the projection immediately; store + retention run in a Task.
    func toggleFavorites(_ ids: [UUID], confirmed: Bool = false) {
        let cards = history.cards.filter { ids.contains($0.id) }
        guard !cards.isEmpty else { return }
        let makeFavorite = !cards.allSatisfy(\.isFavorite)
        let limits = settings.retentionLimits
        let cutoff = Date().addingTimeInterval(-limits.maxAge)
        let deletableOld: (HistoryCard) -> Bool = { [history] card in
            card.lastCopiedAt < cutoff && !history.isStackPinned(card.id)
        }
        if !makeFavorite, !confirmed {
            let old = cards.filter(deletableOld).count
            if old > 0 { return present(.confirmUnfavorite(cards.map(\.id), old: old)) }
        }
        if case .confirmUnfavorite? = overlay { present(nil) }

        let changing = cards.filter { $0.isFavorite != makeFavorite }
        guard !changing.isEmpty else { return }
        let previous = Dictionary(uniqueKeysWithValues: changing.map { ($0.id, $0) })
        let changingIDs = Set(changing.map(\.id))
        // Age-delete victims only (store pin rule). Favorites-scope exit hides all changing ids.
        let ageVictims = makeFavorite ? Set<UUID>() : Set(changing.filter(deletableOld).map(\.id))
        let hideIDs: Set<UUID> = {
            if !makeFavorite, case .favorites = history.scope { return changingIDs }
            return ageVictims
        }()

        for card in changing {
            history.setFavoriteLocally(record: card.id, isFavorite: makeFavorite)
        }
        if !hideIDs.isEmpty { history.hide(hideIDs) }

        favoriteOpGeneration += 1
        let gen = favoriteOpGeneration
        let target = makeFavorite
        Task { [weak self] in
            guard let self else { return }
            do {
                for id in changingIDs {
                    guard gen == self.favoriteOpGeneration else { return }
                    try await self.store.setFavorite(id, target, limits: limits, now: Date())
                }
            } catch {
                guard gen == self.favoriteOpGeneration else { return }
                self.toasts.error(error.localizedDescription)
                for (id, card) in previous {
                    self.history.setFavoriteLocally(record: id, isFavorite: card.isFavorite)
                }
                let pending = self.pendingDeletion?.ids ?? []
                let restoreHide = hideIDs.subtracting(pending)
                if !restoreHide.isEmpty {
                    self.history.unhide(restoreHide)
                } else {
                    self.history.storeDidChange()
                }
                return
            }
            guard gen == self.favoriteOpGeneration else { return }
            let pending = self.pendingDeletion?.ids ?? []
            self.history.forgetHidden(hideIDs.subtracting(pending))
            self.history.storeDidChange()
        }
    }

    /// Collections ▸ with several cards: adds them all, or takes them all out when they all are in.
    func setMembership(_ ids: [UUID], collection: UUID, isMember: Bool) {
        for id in ids { history.setMembershipLocally(record: id, collection: collection, isMember: isMember) }
        Task {
            for id in ids { try? await store.setMembership(record: id, collection: collection, isMember: isMember) }
            history.refreshCollections()
            history.storeDidChange()
        }
    }

    /// Deletes what is selected: one card or several.
    func deleteSelection() {
        let recordIDs = history.selectionRecordIDs
        let stackIDs = history.selection.compactMap { if case .stack(let id) = $0 { return id }; return nil }
        if !recordIDs.isEmpty { delete(recordIDs) }
        for id in stackIDs { deleteStack(id) }
    }

    func deleteStack(_ id: UUID) {
        if stackSession.armedStackID == id { stackSession.stop(toast: false) }
        if stackEditor?.stackID == id {
            stackEditor = nil
            windows.closeStack(returningToPanel: true)
        }
        history.removeStackLocally(id)
        Task {
            try? await store.deleteStacks([id])
            history.storeDidChange()
        }
        toasts.show(String(localized: "Stack deleted"))
    }

    func toggleStackFavorite(_ id: UUID) {
        guard let stack = history.allStacks.first(where: { $0.id == id })
            ?? history.stacks.first(where: { $0.id == id })
            ?? (stackEditor?.stackID == id ? stackEditor?.stack : nil) else { return }
        let makeFavorite = !stack.isFavorite
        let previous = stack
        history.setStackFavoriteLocally(id: id, isFavorite: makeFavorite)
        if stackEditor?.stackID == id { stackEditor?.applyFavorite(makeFavorite) }
        let leftFavorites = !makeFavorite && history.scope == .favorites
        if leftFavorites { history.removeStackLocally(id) }

        favoriteOpGeneration += 1
        let gen = favoriteOpGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                guard gen == self.favoriteOpGeneration else { return }
                try await self.store.setStackFavorite(id, makeFavorite)
            } catch {
                guard gen == self.favoriteOpGeneration else { return }
                self.toasts.error(error.localizedDescription)
                self.history.setStackFavoriteLocally(id: id, isFavorite: previous.isFavorite)
                if self.stackEditor?.stackID == id { self.stackEditor?.applyFavorite(previous.isFavorite) }
                self.history.storeDidChange()
                return
            }
            guard gen == self.favoriteOpGeneration else { return }
            self.history.storeDidChange()
        }
    }

    /// Open Stack / Edit Stack — Stack Window (replaces panel drill-down).
    func openStack(_ id: UUID) {
        openStackEditor(id)
    }

    func openStackEditor(_ id: UUID) {
        if let itemState, itemState.isDirty {
            hidePanelForWindow()
            windows.showRecord(focusText: false)
            return resolveUnsavedChanges { [weak self] in self?.openStackEditor(id) }
        }
        Task { await openStackEditorAsync(id) }
    }

    private func openStackEditorAsync(_ id: UUID) async {
        // Panel no longer drills into stacks — clear a leftover scope if any.
        if case .stack = history.scope { history.scope = .all }
        let card: StackCard
        if let local = history.allStacks.first(where: { $0.id == id })
            ?? history.stacks.first(where: { $0.id == id }) {
            card = local
        } else if let loaded = try? await store.stack(id) {
            card = loaded
        } else {
            toasts.error(String(localized: "This stack was deleted."))
            return
        }
        if let existing = stackEditor, existing.stackID == id {
            hidePanelForWindow()
            windows.showStack()
            existing.reload()
            return
        }
        let state = StackEditorState(stack: card, store: store)
        stackEditor = state
        state.reload()
        hidePanelForWindow()
        windows.showStack()
        windows.updateStackTitle(state.title)
    }

    func closeStackEditor(returningToPanel: Bool = true) {
        windows.closeStack(returningToPanel: returningToPanel || isPinned)
    }

    func stackWindowDidClose() {
        stackEditor = nil
        endCardDrag()
    }

    func chooseStackFromEditor(paste: Bool) {
        guard let id = stackEditor?.stackID else { return }
        closeStackEditor(returningToPanel: false)
        chooseStack(id, paste: paste)
    }

    func presentStackRename() {
        guard let id = stackEditor?.stackID else { return }
        // Rename overlay lives on the panel — keep editing title in the window field instead.
        windows.updateStackTitle(stackEditor?.title ?? "")
        _ = id
    }

    func beginStackEditorDrag(_ id: UUID) {
        guard let state = stackEditor, state.canReorder else {
            beginCardDrag(id)
            return
        }
        stackDrag.beginRecord(id, positionalReorder: true, history: history)
    }

    @discardableResult
    func dropStackEditorReorder(before targetID: UUID?, atEnd: Bool) -> Bool {
        stackDrag.claimForDrop()
        guard let state = stackEditor,
              state.canReorder,
              stackDrag.isPositionalReorder,
              let fromID = stackDrag.recordID,
              let order = state.reorder(from: fromID, before: targetID, atEnd: atEnd) else {
            endCardDrag()
            return false
        }
        defer { endCardDrag() }
        persistStackMemberOrder(state.stackID, recordIDs: order)
        windows.updateStackTitle(state.title)
        return true
    }

    func moveStackEditorMember(_ recordID: UUID, toStart: Bool? = nil, by delta: Int = 0) {
        guard let state = stackEditor else { return }
        let order: [UUID]?
        if let toStart {
            order = state.moveMemberToEnd(recordID, toStart: toStart)
        } else {
            order = state.moveMember(recordID, by: delta)
        }
        guard let order else { return }
        persistStackMemberOrder(state.stackID, recordIDs: order)
    }

    func reloadStackEditorIfNeeded() {
        stackEditor?.reload()
        if let state = stackEditor {
            windows.updateStackTitle(state.title)
        }
    }

    func renameStack(_ id: UUID, title: String) {
        stackEditor?.applyTitle(title)
        if stackEditor?.stackID == id {
            windows.updateStackTitle(stackEditor?.title ?? title)
        }
        Task {
            try? await store.renameStack(id, title: title)
            history.storeDidChange()
        }
    }

    func setStackDeal(_ id: UUID, mode: StackDealMode, loops: Bool) {
        history.setStackDealLocally(id: id, mode: mode, loops: loops)
        if stackEditor?.stackID == id {
            stackEditor?.applyDeal(mode: mode, loops: loops)
        }
        Task {
            do {
                try await store.setStackDeal(id, dealMode: mode, loops: loops)
                history.storeDidChange()
                if stackSession.armedStackID == id {
                    stackSession.applyDealSettings(dealMode: mode, loops: loops)
                }
            } catch {
                history.storeDidChange()
                reloadStackEditorIfNeeded()
                toasts.error(error.localizedDescription)
            }
        }
    }

    /// New Stack… from one card or a multi-select (records only); opens the Stack Window.
    func createStackFromSelection(title: String) {
        let ids = pendingStackRecordIDs ?? history.selectionRecordIDs
        pendingStackRecordIDs = nil
        guard !ids.isEmpty else {
            toasts.show(String(localized: "Select records to put in a stack."))
            return
        }
        Task {
            do {
                let stackID = try await store.createStack(title: title, recordIDs: ids)
                history.storeDidChange()
                openStackEditor(stackID)
                toasts.show(String(localized: "Stack created — drop cards onto the stack card to add them"))
            } catch {
                toasts.error(error.localizedDescription)
            }
        }
    }

    /// Everything a query finds — the panel's current list, an app, a collection — after a
    /// question that says how many and keeps favorites unless asked (first-run feedback: there
    /// was no way to clean up by filter). Undo works as for any delete.
    func deleteAll(matching query: HistoryQuery, scope: DeleteManyScope) {
        let store = store
        Task {
            guard let found = try? await store.ids(query) else { return }
            let hidden = history.hiddenIDs
            let others = found.others.filter { !hidden.contains($0) }
            let favorites = found.favorites.filter { !hidden.contains($0) }
            guard !others.isEmpty || !favorites.isEmpty else {
                return toasts.show(String(localized: "Nothing to delete"))
            }
            present(.confirmDeleteMany(scope, others: others, favorites: favorites))
        }
    }

    /// The panel's list as filtered and searched now.
    func deleteAllShown() {
        deleteAll(matching: history.query, scope: .shown)
    }


    func rename(_ id: UUID, title: String) {
        present(nil)
        Task {
            do {
                try await store.rename(id, title: title)
            } catch {
                toasts.error(error.localizedDescription)
            }
            history.storeDidChange()
        }
    }

    /// Preview language override (§8.5): `nil` = automatic, `"plain"` = none, else a `CodeLanguage`.
    func setCodeLanguage(_ id: UUID, _ language: String?) {
        Task { try? await store.setCodeLanguage(id, language) }
    }

    /// The stored image or PDF page, downsampled to the preview size off the main actor (§7.3).
    func previewImage(_ id: UUID, maxPixelSize: Int) async -> NSImage? {
        guard let input = try? await store.recognitionInput(for: id) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> Transfer<CGImage>? in
            let image = input.isPDF
                ? Thumbnailer.renderPDFPage(input.data, maxPixelSize: maxPixelSize)?.image
                : Thumbnailer.downsampledImage(from: input.data, maxPixelSize: maxPixelSize)
            return image.map { Transfer(value: $0) }
        }.value
        return image.map { NSImage(cgImage: $0.value, size: .zero) }
    }

    /// Edit save (§3.6). Returns an error message, or `nil` on success; the window stays open.
    /// `savedRich` is the formatted text as saved: typing during the save stays unsaved.
    func saveEdit(_ id: UUID, text: String, rich: RichContent? = nil, savedRich: NSAttributedString? = nil) async -> String? {
        let store = store
        let maxBytes = settings.maxItemBytes
        let policy = settings.secretPolicy
        let kinds = settings.secretKinds
        // *Don't save* holds for typed secrets too (review finding).
        if policy == .dontSave, SecretDetector.detect(text, kinds: kinds) != nil {
            return String(localized: "The text contains a secret, and Settings say not to save secrets.")
        }
        switch await monitor.destructive({ opSeq in
            try await store.editText(id, text: text, rich: rich, opSeq: opSeq, maxBytes: maxBytes, secretPolicy: policy, secretKinds: kinds)
        }) {
        case .success(.updated):
            monitor.recordChanged(id)
            history.storeDidChange()
            // A secret typed in may now expire: the timer follows (§3.10).
            if case .deleteAfter = policy { runRetention() }
            if stackSession.isArmed { stackSession.rebuildFromStore() }
            if let state = itemState, state.id == id {
                // Saved in place: what was saved is the new starting point.
                state.textSaved(text, rich: savedRich)
                toasts.show(String(localized: "Saved"))
            }
            return nil
        case .success(.merged(let survivor)):
            monitor.recordChanged(id)
            history.removeLocally([id])
            rescueFromPendingDeletion(survivor)
            history.selectedID = .record(survivor)
            history.storeDidChange()
            // Merge retargets StackMember rows — refresh the deal queue if armed.
            if stackSession.isArmed { stackSession.rebuildFromStore() }
            toasts.show(String(localized: "Merged with an existing record"))
            await showRecord(survivor)
            return nil
        case .success(.rejected(let message)):
            return message
        case .failure(.busy):
            return String(localized: "Another change is in progress. Try again.")
        case .failure(.failed(let message)):
            return message
        }
    }

    /// The record window switches to `id`, also when the panel has not loaded that card.
    private func showRecord(_ id: UUID) async {
        var card = history.cards.first { $0.id == id }
        if card == nil { card = await details(id, maxTextScalars: 0)?.card }
        guard let card else { return closeRecord() }
        let state = ItemState(card: card, focusOnLoad: false, maxBytes: settings.maxItemBytes)
        itemState = state
        windows.showRecord(focusText: false)
        if state.hasText { await loadText(into: state) }
    }

    /// Full text for the editor and preview (≤ 20 000 scalars in the preview, §7.4).
    func details(_ id: UUID, maxTextScalars: Int = 20_000) async -> RecordDetails? {
        try? await store.details(id, maxTextScalars: maxTextScalars)
    }

    func editorText(_ id: UUID) async -> String? {
        guard let payload = try? await store.payload(for: id) else { return nil }
        return payload.text
    }

    /// The richest readable formatted text of a record (§3.6): RTFD → RTF → HTML → web archive.
    /// Above 4 MB it opens as plain text. HTML/archives are isolated before WebKit (§9).
    func editorRichText(_ id: UUID) async -> (text: NSAttributedString, background: NSColor?)? {
        guard let payload = try? await store.payload(for: id) else { return nil }
        let pairs: [(PasteboardType, Data)] = payload.items.flatMap(\.representations).compactMap { rep in
            guard let data = rep.bytes else { return nil }
            return (rep.type, data)
        }
        return await EditorRichText.load(from: pairs)
    }

    func clear(_ scope: ClearScope) {
        Task {
            let store = store
            switch await monitor.destructive({ opSeq in try await store.clear(scope, opSeq: opSeq) }) {
            case .success:
                thumbnails.removeAll()
                history.storeDidChange()
                prunePreviewFiles()
                toasts.show(scope == .all ? String(localized: "History cleared") : String(localized: "History cleared except favorites"))
            case .failure(let error):
                report(error)
            }
        }
    }

    private func report(_ error: ClipboardMonitor.DestructiveError) {
        switch error {
        case .busy: toasts.error(String(localized: "Another change is in progress. Try again."))
        case .failed(let message): toasts.error(message)
        }
    }

    // MARK: Collections (§8.2)

    func createCollection(named name: String, adding recordID: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .newCollection? = overlay { present(nil) }
        Task {
            do {
                let id = try await store.createCollection(named: trimmed)
                if let recordID {
                    try await store.setMembership(record: recordID, collection: id, isMember: true)
                    history.setMembershipLocally(record: recordID, collection: id, isMember: true)
                }
            } catch {
                toasts.error(error.localizedDescription)
            }
            history.refreshCollections()
            history.storeDidChange()
        }
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        present(nil)
        Task {
            try? await store.renameCollection(id, to: trimmed)
            history.refreshCollections()
        }
    }

    /// After *Delete Collection?* — the records stay in history.
    func deleteCollection(_ id: UUID) {
        present(nil)
        Task {
            try? await store.deleteCollection(id)
            if history.scope == .collection(id) { history.scope = .all }
            history.refreshCollections()
            history.storeDidChange()
        }
    }

    func setMembership(_ recordID: UUID, collection: UUID, isMember: Bool) {
        history.setMembershipLocally(record: recordID, collection: collection, isMember: isMember)
        Task {
            try? await store.setMembership(record: recordID, collection: collection, isMember: isMember)
            history.refreshCollections()
            history.storeDidChange()
        }
    }

    // MARK: Card drag (StackDragSession SSOT — PLAN §3.11)

    /// Begin dragging a history record. Positional reorder when the open playlist is unfiltered.
    func beginCardDrag(_ id: UUID) {
        let positional = history.canReorderStack
        stackDrag.beginRecord(id, positionalReorder: positional, history: history)
    }

    func beginStackDrag(_ id: UUID) {
        stackDrag.beginStack(id, history: history)
    }

    func endCardDrag() {
        stackDrag.end()
    }

    /// Insert before `targetID`, or at end when `atEnd`. Only while a positional session is live.
    @discardableResult
    func dropReorder(before targetID: UUID?, atEnd: Bool = false) -> Bool {
        stackDrag.claimForDrop()
        guard let stackID = history.scopedStackID,
              history.canReorderStack,
              stackDrag.isPositionalReorder,
              let fromID = stackDrag.recordID else {
            endCardDrag()
            return false
        }
        defer { endCardDrag() }
        var order = history.stackMemberOrder
        guard let from = order.firstIndex(of: fromID) else { return false }
        if atEnd {
            if from == order.count - 1 { return true }
            order.remove(at: from)
            order.append(fromID)
        } else {
            guard let targetID, fromID != targetID,
                  order.contains(targetID) else { return true }
            if from + 1 == order.firstIndex(of: targetID) { return true }
            order.remove(at: from)
            guard let newTarget = order.firstIndex(of: targetID) else { return false }
            order.insert(fromID, at: newTarget)
        }
        history.applyStackMemberOrder(order)
        persistStackMemberOrder(stackID, recordIDs: order)
        return true
    }

    /// Sidebar collection drop (record or stack card).
    func dropDraggedCard(on collection: UUID) -> Bool {
        stackDrag.claimForDrop()
        guard stackDrag.isFresh, let source = stackDrag.source else { return false }
        defer { endCardDrag() }
        let name = history.collections.first { $0.id == collection }?.name ?? ""
        switch source {
        case .stack(let stackID):
            setStackMembership(stack: stackID, collection: collection, isMember: true)
            toasts.show(String(localized: "Added to “\(name)”"))
        case .record(let recordID):
            if history.memberships[recordID]?.contains(collection) != true {
                setMembership(recordID, collection: collection, isMember: true)
                toasts.show(String(localized: "Added to “\(name)”"))
            }
        }
        return true
    }

    /// Drop onto a stack *card*, or onto the open playlist grid (append non-members).
    /// Priority: positional miss → no-op; already-member on open grid → no-op; else append / move-to-end.
    func dropDraggedCard(onStack stackID: UUID) -> Bool {
        stackDrag.claimForDrop()
        guard stackDrag.isFresh, let recordID = stackDrag.recordID else { return false }

        if history.scopedStackID == stackID {
            if stackDrag.isPositionalReorder || history.stackMemberOrder.contains(recordID) {
                endCardDrag()
                return true
            }
        }

        endCardDrag()
        Task {
            let members = (try? await store.stackMemberIDs(stackID)) ?? []
            if members.contains(recordID) {
                var order = members.filter { $0 != recordID }
                order.append(recordID)
                do {
                    try await store.setStackMembers(stackID, recordIDs: order)
                    history.storeDidChange()
                    if stackSession.armedStackID == stackID { stackSession.rebuildFromStore() }
                    toasts.show(String(localized: "Moved to end of stack"))
                } catch {
                    history.storeDidChange()
                    toasts.error(error.localizedDescription)
                }
            } else {
                addRecord(recordID, toStack: stackID, toast: true)
            }
        }
        return true
    }

    /// Playlist membership (§3.11): join clears `expiresAt`; leave does not restore it (§6).
    func addRecord(_ recordID: UUID, toStack stackID: UUID, toast: Bool = false) {
        Task {
            do {
                try await store.appendStackMember(stackID, recordID: recordID)
                history.storeDidChange()
                if stackEditor?.stackID == stackID { reloadStackEditorIfNeeded() }
                if stackSession.armedStackID == stackID { stackSession.rebuildFromStore() }
                if toast { toasts.show(String(localized: "Added to stack")) }
            } catch {
                history.storeDidChange()
                toasts.error(error.localizedDescription)
            }
        }
    }

    func removeRecord(_ recordID: UUID, fromStack stackID: UUID) {
        Task {
            do {
                try await store.removeStackMember(stackID, recordID: recordID)
                history.storeDidChange()
                if stackEditor?.stackID == stackID { reloadStackEditorIfNeeded() }
                if stackSession.armedStackID == stackID { stackSession.rebuildFromStore() }
            } catch {
                history.storeDidChange()
                reloadStackEditorIfNeeded()
                toasts.error(error.localizedDescription)
            }
        }
    }

    /// Persist UI order after optimistic `applyStackMemberOrder`. No full reload — page already matches.
    func setStackMemberOrder(_ stackID: UUID, recordIDs: [UUID]) {
        persistStackMemberOrder(stackID, recordIDs: recordIDs)
    }

    private func persistStackMemberOrder(_ stackID: UUID, recordIDs: [UUID]) {
        Task {
            do {
                try await store.setStackMembers(stackID, recordIDs: recordIDs)
                history.storeDidChange()
                if stackSession.armedStackID == stackID { stackSession.rebuildFromStore() }
            } catch {
                history.storeDidChange()
                reloadStackEditorIfNeeded()
                toasts.error(error.localizedDescription)
            }
        }
    }

    func setStackMembership(stack stackID: UUID, collection: UUID, isMember: Bool) {
        Task {
            try? await store.setStackMembership(stack: stackID, collection: collection, isMember: isMember)
            history.storeDidChange()
        }
    }

    // MARK: Per-app quick actions (§5.1)

    func setCaptureMode(_ mode: CaptureMode, for bundleID: String) {
        let undo = settings.snapshot
        settings.updateProfile(bundleID) { $0.captureMode = mode }
        let name = AppInfo.displayName(for: bundleID)
        let message: String = switch mode {
        case .save: String(localized: "Saving from \(name) again")
        case .dontSave: String(localized: "Won't save from \(name)")
        case .deleteAfter(let minutes): String(localized: "\(name): delete after \(RetentionText.duration(minutes: minutes))")
        }
        guard mode != .save else {
            toasts.show(message, actions: [undoAction(undo)])
            return
        }
        Task {
            let existing = (try? await store.countRecords(fromApp: bundleID)) ?? 0
            var actions = [undoAction(undo)]
            if existing > 0 {
                actions.append(.init(title: String(localized: "Also Delete \(existing) Existing")) { [weak self] in
                    self?.deleteRecords(fromApp: bundleID)
                })
            }
            toasts.show(message, actions: actions)
        }
    }

    func deleteAndDontSave(_ id: UUID, bundleID: String) {
        delete([id], confirmed: true)
        setCaptureMode(.dontSave, for: bundleID)
    }

    func deleteRecords(fromApp bundleID: String) {
        Task {
            let store = store
            switch await monitor.destructive({ opSeq in try await store.deleteRecords(fromApp: bundleID, opSeq: opSeq) }) {
            case .success(let count):
                thumbnails.removeAll()
                history.storeDidChange()
                toasts.show(String(localized: "Deleted \(count) items from \(AppInfo.displayName(for: bundleID))"))
            case .failure(let error):
                report(error)
            }
        }
    }

    func addFormatRule(_ rule: FormatRule, app name: String) {
        let undo = settings.snapshot
        settings.addRule(rule)
        let format = rule.typePattern.map(FormatNames.name) ?? String(localized: "all formats")
        let message = rule.action == .skip
            ? String(localized: "\(name): won't save \(format)")
            : String(localized: "\(name): will keep \(format)")
        toasts.show(message, actions: [undoAction(undo)])
    }

    func setSizeLimit(_ mib: Int, for bundleID: String, name: String) {
        let undo = settings.snapshot
        settings.updateProfile(bundleID) { $0.sizeLimitMiB = mib }
        toasts.show(String(localized: "\(name): items up to \(mib) MB"), actions: [undoAction(undo)])
    }

    /// Counts recognitions of the record in the record window, so it shows the new text.
    private(set) var recognitionTick = 0

    func setRecognition(_ enabled: Bool, for bundleID: String, name: String) {
        let undo = settings.snapshot
        settings.updateProfile(bundleID) { $0.recognizeText = enabled }
        toasts.show(
            enabled ? String(localized: "\(name): recognizing text in images") : String(localized: "\(name): not recognizing text in images"),
            actions: [undoAction(undo)]
        )
    }

    private func undoAction(_ snapshot: SettingsStore.Snapshot) -> ToastCenter.Toast.Action {
        .init(title: String(localized: "Undo")) { [weak self] in self?.settings.restore(snapshot) }
    }

    // MARK: Settings window

    /// Other windows never open under the floating panel: it hides first, pinned or not, as Pasta does,
    /// and returns when the window closes.
    func openSettings(_ tab: SettingsTab? = nil, app: String? = nil) {
        if let app { settingsApp = app }
        hidePanelForWindow()
        windows.showSettings(tab: tab)
    }

    func openDiagnostics() {
        hidePanelForWindow()
        windows.showDiagnostics()
    }

    private func hidePanelForWindow() {
        if panel.isVisible { panelHiddenForWindow = true }
        // The window that replaces the panel takes the focus.
        panel.close(returningFocus: false)
    }

    /// The last of the record, Settings and Diagnostics closed; `true` when the panel they replaced
    /// came back. `returningToPanel: false` (a record went to the clipboard) leaves it closed.
    func secondaryWindowDidClose(returningToPanel: Bool = true) -> Bool {
        guard panelHiddenForWindow else { return false }
        panelHiddenForWindow = false
        guard returningToPanel else { return false }
        panel.show(keepingState: true)
        return true
    }

    private static let movedAsideKey = "storeMovedAsidePath"

    func dismissStoreRecovery() {
        storeMovedAside = nil
        UserDefaults.standard.removeObject(forKey: Self.movedAsideKey)
    }


    // MARK: Hotkeys (§2): the new combination registers while the old one stays active.

    func shortcut(for role: HotKeyRole) -> HotKeyCenter.Shortcut? {
        switch role {
        case .window: settings.shortcut
        case .pause: settings.pauseShortcut
        case .skip: settings.skipShortcut
        }
    }

    @discardableResult
    func setShortcut(_ shortcut: HotKeyCenter.Shortcut?, for role: HotKeyRole) -> Bool {
        let previousID = hotKeyIDs[role]
        if let shortcut {
            guard shortcut != self.shortcut(for: role) || previousID == nil else { return true }
            if let conflict = HotKeyRole.allCases.first(where: { $0 != role && self.shortcut(for: $0) == shortcut }) {
                hotKeyErrors[role] = String(localized: "\(shortcut.displayString) is already used for \(conflict.title).")
                return false
            }
            guard register(shortcut, for: role) else { return false }
        } else {
            hotKeyIDs[role] = nil
            hotKeyErrors[role] = nil
        }
        if let previousID, previousID != hotKeyIDs[role] { HotKeyCenter.shared.unregister(previousID) }
        switch role {
        case .window: settings.shortcut = shortcut ?? .defaultShortcut
        case .pause: settings.pauseShortcut = shortcut
        case .skip: settings.skipShortcut = shortcut
        }
        return true
    }

    @discardableResult
    private func register(_ shortcut: HotKeyCenter.Shortcut, for role: HotKeyRole) -> Bool {
        let result = HotKeyCenter.shared.register(shortcut) { [weak self] in
            guard let self else { return }
            switch role {
            case .window: panel.toggle()
            case .pause: monitor.togglePause()
            case .skip: monitor.toggleSkip()
            }
        }
        switch result {
        case .success(let id):
            hotKeyIDs[role] = id
            hotKeyErrors[role] = nil
            return true
        case .failure(let error):
            hotKeyErrors[role] = error.message(for: shortcut)
            return false
        }
    }
}

extension HotKeyRole {
    var title: String {
        switch self {
        case .window: String(localized: "Open Memopila")
        case .pause: String(localized: "Pause or Resume Capture")
        case .skip: String(localized: "Skip Next Copy")
        }
    }
}
