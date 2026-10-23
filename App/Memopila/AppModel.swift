import AppKit
import MemopilaCore
import MemopilaServices
import Observation
import SwiftUI

/// Panel overlays (§8.4, §8.5, §3.6). Shown inside the panel, never as separate windows.
enum PanelOverlay: Equatable {
    case preview(UUID)
    case editor(UUID)
    case rename(UUID)
    case actions(UUID)
    case newCollection(addingRecord: UUID?)
    case renameCollection(UUID)
    case confirmDelete([UUID])
    case confirmClear
}

enum RestoreVariant: Equatable {
    case original
    case plainText
    case textAction(TextAction)
    case recognizedText
}

enum SettingsTab: String, Hashable {
    case general, capture, apps, formats, recognition, storage, about
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
    private let recognition: RecognitionService
    /// The history file could not be opened; history is kept in memory until relaunch.
    let storeOpenError: String?
    /// The previous history could not be opened and was moved here; a new one started (§7.2).
    private(set) var storeMovedAside: URL?

    private(set) var overlay: PanelOverlay?
    private(set) var actionsState: ActionsPanelState?
    private(set) var editorState: EditorState?
    var isPinned = false
    /// ⌘ is held in the panel: cards show their ⌘1…⌘9 shortcuts.
    var isCommandHeld = false
    /// Bumped whenever search should take focus (open, ⌘F, overlay closed).
    private(set) var focusSearchToken = 0
    private(set) var hotKeyErrors: [HotKeyRole: String] = [:]
    var settingsTab: SettingsTab = .general
    var settingsApp: String?

    @ObservationIgnored private var hotKeyIDs: [HotKeyRole: UInt32] = [:]
    @ObservationIgnored private(set) var previousApp: NSRunningApplication?
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var dailyTimer: Timer?
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?
    @ObservationIgnored var openWindowAction: OpenWindowAction?

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
        storeMovedAside = movedAside
        self.store = store
        monitor = ClipboardMonitor(settings: settings, store: store)
        history = HistoryModel(store: store)
        thumbnails = ThumbnailCache(store: store)
        recognition = RecognitionService(store: store, settings: settings)
        panel = PanelController(model: self)

        monitor.panelIsKey = { [weak self] in self?.panel.isKey ?? false }
        monitor.onSaved = { [weak self] _ in self?.didSave() }
        recognition.onUpdate = { [weak self] _ in self?.history.storeDidChange() }
        settings.onRetentionChange = { [weak self] in self?.runRetention() }
        settings.onRecognitionChange = { [weak self] bundleID in self?.enableRecognition(forApp: bundleID) }
    }

    func start() {
        applyActivationPolicy()
        for role in HotKeyRole.allCases {
            if let shortcut = shortcut(for: role) { register(shortcut, for: role) }
        }
        monitor.start()
        runRetention()
        recognition.wake()
        let daily = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runRetention() }
        }
        RunLoop.main.add(daily, forMode: .common)
        dailyTimer = daily
        observeMemoryPressure()
    }

    // MARK: Overlays

    /// Shows an overlay (or `nil` to close it); search takes focus again when it closes.
    func present(_ next: PanelOverlay?) {
        switch next {
        case .actions(let id)?:
            guard let card = history.cards.first(where: { $0.id == id }) else { return }
            actionsState = ActionsPanelState(items: ActionRegistry.cardActions(card, model: self).flatMap { $0.flattened() })
            editorState = nil
        case .editor(let id)?:
            guard let card = history.cards.first(where: { $0.id == id }), Self.isEditable(card) else { return }
            if editorState?.id != id { openEditor(card) }
            actionsState = nil
        default:
            actionsState = nil
            editorState = nil
        }
        overlay = next
        if next == nil { focusSearchToken += 1 }
    }

    func focusSearch() {
        focusSearchToken += 1
    }

    func runHighlightedAction() {
        guard let action = actionsState?.highlightedAction, action.isEnabled else { return }
        present(nil)
        action.run?()
    }

    private func openEditor(_ card: HistoryCard) {
        let state = EditorState(id: card.id, hasFormatting: card.displayType == .richText)
        editorState = state
        Task {
            if let text = await editorText(card.id) {
                state.load(text)
            } else {
                state.error = String(localized: "The text could not be loaded.")
            }
        }
    }

    func saveEditor(thenCopy: Bool) {
        guard let state = editorState, !state.isSaving, let text = state.currentText() else { return }
        guard !text.isEmpty else {
            state.error = String(localized: "The text is empty.")
            return
        }
        state.isSaving = true
        Task {
            let error = await saveEdit(state.id, text: text, thenCopy: thenCopy)
            state.isSaving = false
            state.error = error
        }
    }

    // MARK: Panel lifecycle (§8.1, §7.3)

    func panelWillShow() {
        refreshPreviousApp()
        purgeTask?.cancel()
        present(nil)
        toasts.dismiss()
        history.activate()
        focusSearchToken += 1
    }

    /// The app that keeps the focus behind the non-activating panel: the target of Paste after restore.
    func refreshPreviousApp() {
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.bundleIdentifier == ClipboardMonitor.ownBundleID ? nil : $0
        } ?? previousApp
    }

    func panelDidClose() {
        present(nil)
        isCommandHeld = false
        history.deactivate()
        purgeTask?.cancel()
        purgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.purgeCaches()
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

    private func didSave() {
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
            let next = (try? await store.applyRetention(limits: limits, now: Date())) ?? nil
            history.storeDidChange()
            armExpiry(next)
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

    /// ↩ / ⇧↩: waits for a pending search so the restored card is the one the results show.
    func restoreSelected(variant: RestoreVariant = .original) {
        Task {
            await history.settle()
            guard let id = history.selectedID ?? history.cards.first?.id else { return }
            await performRestore(id, variant: variant)
        }
    }

    func restoreVisible(_ index: Int) {
        Task {
            await history.settle()
            guard let card = history.card(at: index) else { return }
            history.selectedID = card.id
            await performRestore(card.id, variant: .original)
        }
    }

    func restore(_ id: UUID, variant: RestoreVariant = .original) {
        Task { await performRestore(id, variant: variant) }
    }

    private func performRestore(_ id: UUID, variant: RestoreVariant) async {
        let items: [CanonicalItem]
        var sourceBundleID: String?
        do {
            switch variant {
            case .original:
                let payload = try await store.payload(for: id)
                items = payload.items
                sourceBundleID = payload.sourceBundleID
            case .plainText:
                let payload = try await store.payload(for: id)
                guard let text = payload.text else { return toasts.error(String(localized: "This item has no text.")) }
                items = PasteboardWriter.plainTextItems(text)
                sourceBundleID = payload.sourceBundleID
            case .textAction(let action):
                let payload = try await store.payload(for: id)
                guard let text = payload.text else { return toasts.error(String(localized: "This item has no text.")) }
                let result = text.utf8.count > 100_000
                    ? await Task.detached(priority: .userInitiated) { action.apply(to: text) }.value
                    : action.apply(to: text)
                guard let result else { return toasts.error(action.unavailableReason) }
                items = PasteboardWriter.plainTextItems(result)
                sourceBundleID = payload.sourceBundleID
            case .recognizedText:
                guard let details = try await store.details(id, maxTextScalars: 0), let text = details.recognizedText else {
                    return toasts.error(String(localized: "No text was found in this image."))
                }
                items = PasteboardWriter.plainTextItems(text)
                sourceBundleID = details.card.sourceAppBundleID
            }
        } catch StoreError.notFound {
            history.storeDidChange()
            return toasts.error(String(localized: "The item no longer exists."))
        } catch {
            return toasts.error(String(localized: "This item can't be restored: its stored data is damaged."))
        }

        switch monitor.write(items, sourceBundleID: sourceBundleID) {
        case .failed(let message):
            toasts.error(message)
        case .written:
            let target = previousApp
            if isPinned {
                // Pinned: the panel stays visible but gives the key focus back to the target app.
                if settings.pasteAfterRestore { _ = target?.activate() }
            } else {
                panel.close()
            }
            if settings.pasteAfterRestore {
                try? await Task.sleep(for: .milliseconds(80))
                AccessibilityBridge.paste(to: target)
            }
            try? await store.markUsed(id, at: Date())
            history.storeDidChange()
        }
    }

    // MARK: Record commands

    static func isEditable(_ card: HistoryCard) -> Bool {
        [.text, .richText, .url].contains(card.displayType)
    }

    func toggleFavorite(_ id: UUID) {
        guard let card = history.cards.first(where: { $0.id == id }) else { return }
        let limits = settings.retentionLimits
        Task {
            do {
                try await store.setFavorite(id, !card.isFavorite, limits: limits, now: Date())
            } catch {
                toasts.error(error.localizedDescription)
            }
            history.storeDidChange()
        }
    }

    /// ⌘⌫: favorites ask first (§8.3).
    func delete(_ ids: [UUID], confirmed: Bool = false) {
        guard !ids.isEmpty else { return }
        let favorites = history.cards.filter { ids.contains($0.id) && $0.isFavorite }
        if !confirmed, !favorites.isEmpty {
            present(.confirmDelete(ids))
            return
        }
        if case .confirmDelete? = overlay { present(nil) }
        Task {
            let store = store
            switch await monitor.destructive({ opSeq in try await store.delete(ids, opSeq: opSeq) }) {
            case .success:
                for id in ids { thumbnails.invalidate(id) }
                history.removeLocally(Set(ids))
                history.storeDidChange()
            case .failure(let error):
                report(error)
            }
        }
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

    /// Edit save (§3.6). Returns an error message to keep the editor open, or `nil` on success.
    func saveEdit(_ id: UUID, text: String, thenCopy: Bool) async -> String? {
        let store = store
        let maxBytes = settings.maxItemBytes
        switch await monitor.destructive({ opSeq in try await store.editText(id, text: text, opSeq: opSeq, maxBytes: maxBytes) }) {
        case .success(.updated):
            present(nil)
            history.storeDidChange()
            if thenCopy { await performRestore(id, variant: .original) }
            return nil
        case .success(.merged(let survivor)):
            present(nil)
            history.selectedID = survivor
            history.removeLocally([id])
            history.storeDidChange()
            toasts.show(String(localized: "Merged with an existing record"))
            if thenCopy { await performRestore(survivor, variant: .original) }
            return nil
        case .success(.rejected(let message)):
            return message
        case .failure(.busy):
            return String(localized: "Another change is in progress. Try again.")
        case .failure(.failed(let message)):
            return message
        }
    }

    /// Full text for the editor and preview (≤ 20 000 scalars in the preview, §7.4).
    func details(_ id: UUID, maxTextScalars: Int = 20_000) async -> RecordDetails? {
        try? await store.details(id, maxTextScalars: maxTextScalars)
    }

    func editorText(_ id: UUID) async -> String? {
        guard let payload = try? await store.payload(for: id) else { return nil }
        return payload.text
    }

    func clear(_ scope: ClearScope) {
        Task {
            let store = store
            switch await monitor.destructive({ opSeq in try await store.clear(scope, opSeq: opSeq) }) {
            case .success:
                thumbnails.removeAll()
                history.storeDidChange()
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
        present(nil)
        Task {
            do {
                let id = try await store.createCollection(named: trimmed)
                if let recordID { try await store.setMembership(record: recordID, collection: id, isMember: true) }
            } catch {
                toasts.error(error.localizedDescription)
            }
            history.storeDidChange()
        }
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        present(nil)
        Task {
            try? await store.renameCollection(id, to: trimmed)
            history.storeDidChange()
        }
    }

    func deleteCollection(_ id: UUID) {
        Task {
            try? await store.deleteCollection(id)
            if history.scope == .collection(id) { history.scope = .all }
            history.storeDidChange()
        }
    }

    func setMembership(_ recordID: UUID, collection: UUID, isMember: Bool) {
        Task {
            try? await store.setMembership(record: recordID, collection: collection, isMember: isMember)
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

    /// Other windows never open under the floating panel: it hides first, pinned or not, as Pasta does.
    func openSettings(_ tab: SettingsTab? = nil, app: String? = nil) {
        if let tab { settingsTab = tab }
        if let app { settingsApp = app }
        panel.close()
        NSApp.activate()
        if let openSettingsAction { openSettingsAction() }
    }

    func openDiagnostics() {
        panel.close()
        NSApp.activate()
        if let openWindowAction { openWindowAction(id: DiagnosticsView.windowID) }
    }

    func dismissStoreRecovery() {
        storeMovedAside = nil
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
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
