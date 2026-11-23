import AppKit
import Carbon.HIToolbox
import MemopilaCore
import MemopilaServices
import Observation

/// Result of Choose — distinguish write failure from Stop so the Stack Window does not reopen on cancel.
enum StackChooseOutcome: Sendable {
    case armed
    case failed
    case cancelled
}

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
    /// Absorb late synthetic keyUps after `advanceGate` clears (not the primary suppress).
    private var ignoreCommandVUntil: Date = .distantPast
    /// Coalesce ⌘V settle → advance (session flight; set before deliver / manual advance).
    /// Also the SSOT suppress for synthetic ⌘V — time-based ignore alone caused double-advance
    /// when `writeAsync` outlived a 0.5s window.
    private var advanceGate = false

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

    func chooseStack(
        _ stackID: UUID,
        paste: Bool? = nil,
        uiOrder: [UUID]? = nil,
        dealMode: StackDealMode? = nil,
        loops: Bool? = nil
    ) {
        // Ledger: Choose bumps `useCount` / `lastUsedAt` — ⌘Q right after must not lose it.
        model?.writes.run {
            _ = await self.chooseStackAsync(
                stackID, paste: paste, uiOrder: uiOrder, dealMode: dealMode, loops: loops
            )
        }
    }

    /// Callers that closed the Stack Window first reopen only on `.failed` (not Stop/cancel).
    /// Pass `dealMode` / `loops` when the editor was closed before this runs (editor branch is then dead).
    @discardableResult
    func chooseStackAsync(
        _ stackID: UUID,
        paste: Bool? = nil,
        uiOrder: [UUID]? = nil,
        dealMode: StackDealMode? = nil,
        loops: Bool? = nil
    ) async -> StackChooseOutcome {
        guard let model else { return .failed }
        if paste == true, !AccessibilityBridge.isTrusted {
            AccessibilityBridge.requestTrust()
            model.toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
            return .failed
        }
        let hidden = model.history.hiddenIDs
        // Prefer an in-memory playlist (editor / optimistic history) so a Choose right after
        // reorder does not race a still-in-flight `reorderStackMembers` and start from the old order.
        let rawMembers: [UUID]
        if let uiOrder, !uiOrder.isEmpty {
            rawMembers = uiOrder
        } else if let editor = model.stackEditor, editor.stackID == stackID,
                  !editor.isTruncated, !editor.order.isEmpty {
            rawMembers = editor.order
        } else if let local = model.history.stackCard(id: stackID), !local.memberIDs.isEmpty {
            rawMembers = local.memberIDs
        } else {
            rawMembers = (try? await model.store.stackMemberIDs(stackID)) ?? []
        }
        let members = rawMembers.filter { !hidden.contains($0) }
        guard !members.isEmpty else {
            model.toasts.show(String(localized: "This stack is empty."))
            return .failed
        }
        // Captured plan first — Choose from editor closes the window before this awaits.
        let resolvedDeal: StackDealMode
        let resolvedLoops: Bool
        if let dealMode, let loops {
            resolvedDeal = dealMode
            resolvedLoops = loops
        } else if let editor = model.stackEditor, editor.stackID == stackID {
            resolvedDeal = editor.stack.dealMode
            resolvedLoops = editor.stack.loops
        } else if let local = model.history.stackCard(id: stackID) {
            resolvedDeal = local.dealMode
            resolvedLoops = local.loops
        } else if let card = try? await model.store.stack(stackID) {
            resolvedDeal = card.dealMode
            resolvedLoops = card.loops
        } else {
            resolvedDeal = .sequential
            resolvedLoops = false
        }
        guard let started = DealEngine.startRound(
            stackID: stackID, uiOrder: members, dealMode: resolvedDeal, loops: resolvedLoops
        ) else { return .failed }

        var outcome: StackChooseOutcome = .failed
        await runSessionWrite { [self] generation in
            self.disarmInternal(toast: false)
            guard self.generationOK(generation) else {
                outcome = .cancelled
                return
            }
            self.session = started
            guard await self.writeCurrent(started.current, stackID: stackID) else {
                self.session = nil
                outcome = .failed
                return
            }
            guard self.generationOK(generation) else {
                // Stop raced the write: drop stack chrome that writeCurrent just set.
                self.model?.monitor.clearStackIdentity()
                self.session = nil
                outcome = .cancelled
                return
            }
            try? await model.store.markStackUsed(stackID, at: Date())
            guard self.generationOK(generation) else {
                self.model?.monitor.clearStackIdentity()
                self.session = nil
                outcome = .cancelled
                return
            }
            self.arm()
            outcome = .armed
            model.history.storeDidChange()
            if self.commandVMonitor == nil {
                model.toasts.show(String(localized: "Stack armed — first item on clipboard. Allow Accessibility to advance on ⌘V. Esc to stop."))
            } else {
                model.toasts.show(String(localized: "Stack armed — Esc to stop"))
            }
            let wantsPaste = paste ?? model.settings.pasteAfterCopy
            let canPaste = wantsPaste && AccessibilityBridge.isTrusted
            if !model.isPinned {
                model.panel.close()
            } else if canPaste {
                model.panel.yieldKeyFocus()
            }
            if wantsPaste, !canPaste {
                AccessibilityBridge.requestTrust()
                model.toasts.error(String(localized: "To paste, allow Memopila in System Settings → Privacy & Security → Accessibility, then try again."))
                if model.isPinned { model.showStackChooseBadge(stackID, pasted: false) }
            } else if canPaste {
                let delivered = await self.syntheticPasteThenAdvance(generation: generation)
                if model.isPinned { model.showStackChooseBadge(stackID, pasted: delivered) }
                if !delivered {
                    model.toasts.show(String(localized: "On the clipboard. Could not paste into the other app — press ⌘V there."))
                }
            } else if model.isPinned {
                model.showStackChooseBadge(stackID, pasted: false)
            }
        }
        return outcome
    }

    /// After ⌘V keyUp: advance deal (separate flight from Choose).
    func onPasteCompleted() {
        Task { await advanceAfterPaste() }
    }

    func stop(toast: Bool = true) {
        // Invalidate in-flight Choose/advance, then tear down immediately (P27/P34).
        writeGeneration += 1
        advanceGate = false
        disarmInternal(toast: toast)
    }

    /// Membership/order changed while armed (P24).
    func rebuildFromStore() {
        guard let session, isArmed, let model else { return }
        let stackID = session.stackID
        Task {
            // Read members inside the flight so we do not arm on a pre-coalesce snapshot.
            await runSessionWrite { [self] generation in
                guard self.generationOK(generation),
                      let current = self.session, current.stackID == stackID else { return }
                let hidden = model.history.hiddenIDs
                let members = ((try? await model.store.stackMemberIDs(stackID)) ?? [])
                    .filter { !hidden.contains($0) }
                guard self.generationOK(generation),
                      let current = self.session, current.stackID == stackID else { return }
                guard let rebuilt = DealEngine.rebuild(current, uiOrder: members) else {
                    // Same clipboard policy as exhaust: nothing left to paste.
                    self.disarmInternal(toast: false)
                    await model.monitor.clearOwnedClipboardAsync()
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
            await runSessionWrite { [self] generation in
                guard self.generationOK(generation),
                      let current = self.session, current.stackID == stackID else { return }
                let hidden = model.history.hiddenIDs
                let members = ((try? await model.store.stackMemberIDs(stackID)) ?? [])
                    .filter { !hidden.contains($0) }
                guard self.generationOK(generation),
                      let current = self.session, current.stackID == stackID else { return }
                guard let next = DealEngine.retarget(
                    current, uiOrder: members, dealMode: dealMode, loops: loops
                ) else {
                    self.disarmInternal(toast: false)
                    await model.monitor.clearOwnedClipboardAsync()
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
            guard !self.advanceGate else { return }
            self.advanceGate = true
            defer { self.advanceGate = false }
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
            await model?.monitor.clearOwnedClipboardAsync()
            model?.toasts.show(String(localized: "Stack finished"))
        }
    }

    /// - Returns: `true` when synthetic paste delivered (advance may have run).
    @discardableResult
    private func syntheticPasteThenAdvance(generation: Int) async -> Bool {
        guard let model, generationOK(generation), isArmed else { return false }
        // Gate covers the whole deliver + advance: keyUp must not queue a second advance
        // that runs after this gate clears (root cause of stack member skip).
        advanceGate = true
        defer {
            advanceGate = false
            // Late CGEvent keyUps can arrive after defer; absorb briefly.
            ignoreCommandVUntil = Date().addingTimeInterval(0.3)
        }
        if model.isPinned {
            model.panel.yieldKeyFocus()
        }
        let result = await model.pasteIntoPreviousApp(wasActive: NSApp.isActive)
        guard generationOK(generation), isArmed else { return false }
        guard case .delivered = result else { return false }
        await performAdvance(generation: generation)
        return true
    }

    @discardableResult
    private func writeCurrent(_ recordID: UUID, stackID: UUID) async -> Bool {
        guard let model else { return false }
        do {
            var writeID = recordID
            var items: [CanonicalItem]
            var source: String?
            let payload = try await model.store.payload(for: recordID)
            let looksColour = ColorPayload.identity(of: ColorPayload.normalized(payload.items)) != nil
            if looksColour {
                // Clipboard ≡ card: canonicalize colour before stack write (§8.5).
                switch await model.monitor.destructive({ opSeq in
                    try await model.store.ensureCanonicalColorRecord(recordID, opSeq: opSeq)
                }) {
                case .success(let result):
                    writeID = result.id
                    items = result.items
                    source = result.sourceBundleID
                    if writeID != recordID { model.history.storeDidChange() }
                case .failure(.busy):
                    model.toasts.error(String(localized: "Another change is in progress. Try again."))
                    return false
                case .failure(.failed):
                    model.toasts.error(String(localized: "Could not put this on the clipboard."))
                    return false
                }
            } else {
                items = payload.items
                source = payload.sourceBundleID
            }
            switch await model.monitor.writeAsync(
                items,
                sourceBundleID: source,
                recordID: writeID,
                stackID: stackID
            ) {
            case .written:
                // Unconfirmed pasteboard writes clear identity but still return `.written` —
                // do not arm/advance without stack chrome on the pasteboard.
                guard model.monitor.clipboardStackID == stackID,
                      model.monitor.clipboardRecordID == writeID else {
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
        // Wait out the whole chain — a single `if` lets two waiters resume together, bump gen
        // twice, and race (older body then clears the newer write’s stack chrome).
        while let writeTask {
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
                // Primary suppress: session/delivery flight — not a wall clock.
                guard !self.advanceGate else { return }
                if self.model?.pasteDelivery.isInFlight == true { return }
                guard Date() >= self.ignoreCommandVUntil else { return }
                // Caps Lock / fn must not block; only reject ⇧⌥⌃ with ⌘ (P25).
                let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard mods == .command else { return }
                guard event.keyCode == vCode else { return }
                guard self.isArmed, !self.advanceGate, Date() >= self.ignoreCommandVUntil else { return }
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
