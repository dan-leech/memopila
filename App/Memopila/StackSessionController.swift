import AppKit
import Carbon.HIToolbox
import MemopilaCore
import MemopilaServices
import Observation

/// Armed paste-stack session: DealEngine + single-flight writes + ⌘V/Esc (PLAN §3.11).
/// `@Observable` so panel stack cards / status refresh on arm, advance, and stop (not only the menu bar).
@MainActor
@Observable
final class StackSessionController {
    private(set) var session: DealEngine.Session?
    private(set) var isArmed = false

    private weak var model: AppModel?
    private var escapeHotKeyID: UInt32?
    private var commandVMonitor: Any?
    private var sleepObserver: NSObjectProtocol?
    private var writeTask: Task<Void, Never>?
    /// Bumped on every Choose/advance start and on Stop — in-flight bodies abort after `await` (P21/P34).
    private var writeGeneration = 0
    /// Ignore ⌘V observer until this time (P5: synthetic paste must not double-advance).
    private var ignoreCommandVUntil: Date = .distantPast

    init(model: AppModel) {
        self.model = model
    }

    var progressLabel: String? {
        guard let session, isArmed else { return nil }
        if let progress = session.progress {
            return "\(progress.k)/\(progress.n)"
        }
        return String(localized: "Random")
    }

    var armedStackID: UUID? { isArmed ? session?.stackID : nil }

    var currentMemberID: UUID? { isArmed ? session?.current : nil }

    /// Single definition lives on `AppModel` (P23).
    var memopilaUIKey: Bool { model?.memopilaUIKey ?? false }

    func chooseStack(_ stackID: UUID, paste: Bool? = nil, uiOrder: [UUID]? = nil) {
        Task { await chooseStackAsync(stackID, paste: paste, uiOrder: uiOrder) }
    }

    func chooseStackAsync(_ stackID: UUID, paste: Bool? = nil, uiOrder: [UUID]? = nil) async {
        guard let model else { return }
        if paste == true, !AccessibilityBridge.isTrusted {
            AccessibilityBridge.requestTrust()
            model.toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
            return
        }
        // Prefer an in-memory playlist (editor / optimistic history) so a Choose right after
        // reorder does not race a still-in-flight `setStackMembers` and start from the old order.
        let members: [UUID]
        if let uiOrder, !uiOrder.isEmpty {
            members = uiOrder
        } else if let editor = model.stackEditor, editor.stackID == stackID,
                  !editor.isTruncated, !editor.order.isEmpty {
            members = editor.order
        } else if let local = model.history.stackCard(id: stackID), !local.memberIDs.isEmpty {
            members = local.memberIDs
        } else {
            members = (try? await model.store.stackMemberIDs(stackID)) ?? []
        }
        guard !members.isEmpty else {
            model.toasts.show(String(localized: "This stack is empty."))
            return
        }
        // Prefer the open editor’s optimistic Deal/Loop over a store read that may lag the last write.
        let dealMode: StackDealMode
        let loops: Bool
        if let editor = model.stackEditor, editor.stackID == stackID {
            dealMode = editor.stack.dealMode
            loops = editor.stack.loops
        } else if let local = model.history.stackCard(id: stackID) {
            dealMode = local.dealMode
            loops = local.loops
        } else if let card = try? await model.store.stack(stackID) {
            dealMode = card.dealMode
            loops = card.loops
        } else {
            dealMode = .sequential
            loops = false
        }
        guard let started = DealEngine.startRound(
            stackID: stackID, uiOrder: members, dealMode: dealMode, loops: loops
        ) else { return }

        await runSessionWrite { [self] generation in
            self.disarmInternal(toast: false)
            guard self.generationOK(generation) else { return }
            self.session = started
            guard await self.writeCurrent(started.current, stackID: stackID) else {
                self.session = nil
                return
            }
            guard self.generationOK(generation) else {
                // Stop raced the write: drop stack chrome that writeCurrent just set.
                self.model?.monitor.clearStackIdentity()
                self.session = nil
                return
            }
            try? await model.store.markStackUsed(stackID, at: Date())
            guard self.generationOK(generation) else {
                self.model?.monitor.clearStackIdentity()
                self.session = nil
                return
            }
            self.arm()
            model.history.storeDidChange()
            if self.commandVMonitor == nil {
                model.toasts.show(String(localized: "Stack armed — first item on clipboard. Allow Accessibility to advance on ⌘V. Esc to stop."))
            } else {
                model.toasts.show(String(localized: "Stack armed — Esc to stop"))
            }
            let wantsPaste = paste ?? model.settings.pasteAfterCopy
            let pastes = wantsPaste && AccessibilityBridge.isTrusted
            if model.isPinned {
                model.showStackChooseBadge(stackID, pasted: pastes)
            } else {
                model.panel.close()
            }
            if wantsPaste, !pastes {
                AccessibilityBridge.requestTrust()
                model.toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
            } else if pastes {
                await self.syntheticPasteThenAdvance(generation: generation)
            }
        }
    }

    /// After ⌘V keyUp: advance deal (separate flight from Choose).
    func onPasteCompleted() {
        Task { await advanceAfterPaste() }
    }

    func stop(toast: Bool = true) {
        // Invalidate in-flight Choose/advance, then tear down immediately (P27/P34).
        writeGeneration += 1
        disarmInternal(toast: toast)
    }

    /// Membership/order changed while armed (P24).
    func rebuildFromStore() {
        guard let session, isArmed, let model else { return }
        let stackID = session.stackID
        Task {
            let members = (try? await model.store.stackMemberIDs(stackID)) ?? []
            await runSessionWrite { [self] generation in
                guard self.generationOK(generation),
                      let current = self.session, current.stackID == stackID else { return }
                guard let rebuilt = DealEngine.rebuild(current, uiOrder: members) else {
                    // Same clipboard policy as exhaust: nothing left to paste.
                    self.disarmInternal(toast: false)
                    model.monitor.clearOwnedClipboard()
                    model.toasts.show(String(localized: "Stack stopped — no members left."))
                    return
                }
                let needsWrite = rebuilt.current != current.current
                self.session = rebuilt
                if needsWrite {
                    guard await self.writeCurrent(rebuilt.current, stackID: stackID) else { return }
                    guard self.generationOK(generation), self.isArmed else {
                        self.model?.monitor.clearStackIdentity()
                        return
                    }
                }
                model.statusStackDidChange()
            }
        }
    }

    /// Deal / Loop changed while armed — keep clipboard current; never close the panel / re-Choose.
    func applyDealSettings(dealMode: StackDealMode, loops: Bool) {
        guard let session, isArmed, let model else { return }
        let stackID = session.stackID
        Task {
            let members = (try? await model.store.stackMemberIDs(stackID)) ?? []
            await runSessionWrite { [self] generation in
                guard self.generationOK(generation),
                      let current = self.session, current.stackID == stackID else { return }
                guard let next = DealEngine.retarget(
                    current, uiOrder: members, dealMode: dealMode, loops: loops
                ) else {
                    self.disarmInternal(toast: false)
                    model.monitor.clearOwnedClipboard()
                    model.toasts.show(String(localized: "Stack stopped — no members left."))
                    return
                }
                let needsWrite = next.current != current.current
                self.session = next
                if needsWrite {
                    guard await self.writeCurrent(next.current, stackID: stackID) else { return }
                    guard self.generationOK(generation), self.isArmed else {
                        self.model?.monitor.clearStackIdentity()
                        return
                    }
                }
                model.statusStackDidChange()
            }
        }
    }

    // MARK: - Private

    /// False when Stop or a newer Choose bumped `writeGeneration`.
    private func generationOK(_ generation: Int) -> Bool {
        generation == writeGeneration
    }

    private func arm() {
        isArmed = true
        installEscapeHotKey()
        installCommandVMonitor()
        installSleepObserver()
        model?.statusStackDidChange()
        refreshEscapeGate()
    }

    private func disarmInternal(toast: Bool) {
        guard isArmed || session != nil else { return }
        isArmed = false
        session = nil
        tearDownEscapeHotKey()
        tearDownCommandVMonitor()
        tearDownSleepObserver()
        model?.monitor.clearStackIdentity()
        model?.statusStackDidChange()
        if toast { model?.toasts.show(String(localized: "Stack stopped")) }
    }

    private func advanceAfterPaste() async {
        await runSessionWrite { [self] generation in
            await self.performAdvance(generation: generation)
        }
    }

    /// Shared by ⌘V advance and Choose+auto-paste (same generation — do not nest `runSessionWrite`).
    private func performAdvance(generation: Int) async {
        guard generationOK(generation), isArmed, let session else { return }
        switch DealEngine.afterPaste(session) {
        case .write(let id, let next):
            guard await writeCurrent(id, stackID: next.stackID) else { return }
            guard generationOK(generation), isArmed else {
                model?.monitor.clearStackIdentity()
                return
            }
            self.session = next
            model?.statusStackDidChange()
        case .exhausted:
            // Disarm first so the clear is not treated as an external pasteboard change.
            disarmInternal(toast: false)
            model?.monitor.clearOwnedClipboard()
            model?.toasts.show(String(localized: "Stack finished"))
        }
    }

    private func syntheticPasteThenAdvance(generation: Int) async {
        guard let model, generationOK(generation), isArmed else { return }
        let wasActive = NSApp.isActive
        if model.isPinned {
            model.panel.yieldKeyFocus()
        }
        // P5: CGEvent ⌘V keyUp would also hit the global monitor — suppress it.
        ignoreCommandVUntil = Date().addingTimeInterval(0.5)
        await model.pasteIntoPreviousApp(wasActive: wasActive)
        guard generationOK(generation), isArmed else { return }
        // P1: delay after synthetic paste before advance.
        try? await Task.sleep(for: .milliseconds(80))
        guard generationOK(generation), isArmed else { return }
        await performAdvance(generation: generation)
    }

    @discardableResult
    private func writeCurrent(_ recordID: UUID, stackID: UUID) async -> Bool {
        guard let model else { return false }
        do {
            let payload = try await model.store.payload(for: recordID)
            switch model.monitor.write(
                payload.items,
                sourceBundleID: payload.sourceBundleID,
                recordID: recordID,
                stackID: stackID
            ) {
            case .written:
                // Unconfirmed pasteboard writes clear identity but still return `.written` —
                // do not arm/advance without stack chrome on the pasteboard.
                guard model.monitor.clipboardStackID == stackID,
                      model.monitor.clipboardRecordID == recordID else {
                    model.toasts.error(String(localized: "Could not put this on the clipboard."))
                    return false
                }
                return true
            case .failed(let message):
                model.toasts.error(message)
                return false
            }
        } catch {
            model.toasts.error(String(localized: "This item can't go to the clipboard: its stored data is damaged."))
            return false
        }
    }

    private func runSessionWrite(_ body: @escaping (_ generation: Int) async -> Void) async {
        // Wait first, then bump: bumping before await would invalidate the in-flight body
        // (second ⌘V aborted the first advance mid-write and cleared stack chrome).
        if let writeTask {
            await writeTask.value
        }
        writeGeneration += 1
        let generation = writeGeneration
        let task = Task { await body(generation) }
        writeTask = task
        await task.value
        if writeTask == task { writeTask = nil }
    }

    private func installEscapeHotKey() {
        tearDownEscapeHotKey()
        let result = HotKeyCenter.shared.register(.escapeStop) { [weak self] in
            guard let self, self.isArmed else { return }
            if self.memopilaUIKey { return }
            self.stop()
        }
        if case .success(let id) = result {
            escapeHotKeyID = id
        }
    }

    private func tearDownEscapeHotKey() {
        if let escapeHotKeyID {
            HotKeyCenter.shared.unregister(escapeHotKeyID)
            self.escapeHotKeyID = nil
        }
    }

    func refreshEscapeGate() {
        guard isArmed else { return }
        if memopilaUIKey {
            tearDownEscapeHotKey()
        } else if escapeHotKeyID == nil {
            installEscapeHotKey()
        }
    }

    private func installCommandVMonitor() {
        tearDownCommandVMonitor()
        let vCode = AccessibilityBridge.keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)
        commandVMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                guard self.isArmed, !self.memopilaUIKey else { return }
                guard Date() >= self.ignoreCommandVUntil else { return }
                // Caps Lock / fn must not block; only reject ⇧⌥⌃ with ⌘ (P25).
                let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard mods == .command else { return }
                guard event.keyCode == vCode else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard self.isArmed, Date() >= self.ignoreCommandVUntil else { return }
                self.onPasteCompleted()
            }
        }
    }

    private func tearDownCommandVMonitor() {
        if let commandVMonitor {
            NSEvent.removeMonitor(commandVMonitor)
            self.commandVMonitor = nil
        }
    }

    private func installSleepObserver() {
        tearDownSleepObserver()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(toast: false) }
        }
    }

    private func tearDownSleepObserver() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
    }
}
