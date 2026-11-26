import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MemopilaCore
import os

/// One line per convert: which path ran and how it ended — never text content.
/// `log stream --predicate 'subsystem == "io.github.dan-leech.Memopila" && category == "layout-convert"'`
private struct ConvertTrace {
    var host = "?"
    /// editor (Memopila card) · native (AX) · keys (Electron / no AX model) · fake-ax · terminal
    var kind = "?"
    /// selection · caret · whole-text
    var mode = "?"
    /// ax · typed · pasted · backspace:<semantics> · terminal · none
    var delivery = "none"
    var notes: [String] = []
}

/// In-place anchored layout cycle (⌥⌘B): editor or global selection.
@MainActor
final class LayoutConvertController {
    private enum SessionScope: Equatable {
        case editor
        case global(pid_t)
    }

    private weak var model: AppModel?
    private var session: LayoutConverter.CycleSession?
    private var sessionScope: SessionScope?
    private var sessionRange: CFRange?
    /// Field used for the last global replace — language HUD steals `AXFocusedUIElement`.
    private var sessionElement: AXUIElement?
    private var sessionExpires: ContinuousClock.Instant?
    private var inFlight = false
    /// One coalesced follow-up while a cycle runs (inject-of-live-selection is safe to repeat).
    private var pendingCycle = false
    /// Whether the next queued run selects the target input source (any hotkey press → true).
    private var pendingSwitchLayout = true
    /// Pasteboard types of the last selection ⌘C (terminal detection inside Electron hosts).
    private var lastSelectionCopyTypes: [String] = []
    /// Caret-mode convert: text between the converted span and the caret. The next press with no
    /// selection continues the orbit when the line still ends with `lastOutput + tail`.
    private var sessionCaretTail: String?
    private var trace = ConvertTrace()
    private static let log = Logger(subsystem: "io.github.dan-leech.Memopila", category: "layout-convert")
    private var selectionRestoreTask: Task<Void, Never>?
    /// Electron/Cursor: AX tree walks always miss (~300ms, logs visited≈480). Skip after first probe.
    private var axTreeMutePIDs: Set<pid_t> = []
    /// Native hosts whose AX selection is decoupled from the real one (refuse AX writes; the AX
    /// range reads back whatever we set): Telegram/WhatsApp. Their selection is read via ⌘C —
    /// Telegram reported our last output as AX-“selected” while nothing was; typing
    /// over it duplicated the text.
    private var axSelectionFakeBundles: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "LayoutConvertFakeAXBundles") ?? []
    )

    /// How a fake-AX host's keys treat a selection, learned from the first ⌫ and persisted:
    /// "standard" (⌫/typing replace it — type over it next time, no ⌫, so no smart delete) or
    /// "caretAtEnd" (keys ignore it, insertion point at its end — Telegram: ⌫ × length).
    private var keySemanticsByBundle: [String: String] =
        UserDefaults.standard.dictionary(forKey: "LayoutConvertKeySemantics") as? [String: String] ?? [:]

    private func rememberKeySemantics(_ semantics: LayoutConvertDelivery.BackspaceSemantics, pid: pid_t) {
        let value = semantics.rawValue
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              keySemanticsByBundle[bundle] != value else { return }
        keySemanticsByBundle[bundle] = value
        UserDefaults.standard.set(keySemanticsByBundle, forKey: "LayoutConvertKeySemantics")
    }

    /// Keyed by bundle ID and persisted: survives Memopila/host restarts (no re-learning press).
    private func isAXSelectionFake(_ pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return axSelectionFakeBundles.contains(bundle)
    }

    private func markAXSelectionFake(_ pid: pid_t) {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              axSelectionFakeBundles.insert(bundle).inserted else { return }
        UserDefaults.standard.set(Array(axSelectionFakeBundles).sorted(), forKey: "LayoutConvertFakeAXBundles")
    }
    /// Bumps on every hotkey so a late Task cannot paste an older step over a newer one.
    private var cycleGeneration: UInt64 = 0

    /// Long enough to come back to a phrase and toggle it again (card test: 12 s gap → the orbit
    /// was lost and a new span picked).
    private static let sessionTTL: Duration = .seconds(60)

    private func isAXTreeMute(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return axTreeMutePIDs.contains(pid)
    }

    private func noteAXTreeMute(_ pid: pid_t) {
        axTreeMutePIDs.insert(pid)
    }

    init(model: AppModel) {
        self.model = model
    }

    /// Build layout maps off the hot path so the first ⌥⌘B is not a UCKeyTranslate hitch.
    func warmCaches() {
        InputSourceController.warmMaterials()
    }

    /// `switchLayout`: the hotkey also selects the target input source (keep typing in it); the
    /// editor toolbar button only converts (user: “only the hotkey switches the layout”).
    func cycle(switchLayout: Bool = true) {
        selectionRestoreTask?.cancel()
        selectionRestoreTask = nil
        // Set inFlight before any other work — duplicate hotkey deliveries same-tick must coalesce.
        if inFlight {
            pendingCycle = true
            pendingSwitchLayout = pendingSwitchLayout || switchLayout
            return
        }
        inFlight = true
        pendingSwitchLayout = switchLayout
        Task { @MainActor in
            defer { inFlight = false }
            repeat {
                pendingCycle = false
                cycleGeneration &+= 1
                let generation = cycleGeneration
                let switchNow = pendingSwitchLayout
                pendingSwitchLayout = false
                trace = ConvertTrace()
                let started = ContinuousClock.now
                let ok = await runCycle(generation: generation, switchLayout: switchNow)
                let t = trace
                Self.log.info("""
                    convert #\(generation) host=\(t.host, privacy: .public) kind=\(t.kind, privacy: .public) \
                    mode=\(t.mode, privacy: .public) delivery=\(t.delivery, privacy: .public) ok=\(ok) \
                    ms=\(Self.ms(since: started)) \(t.notes.joined(separator: " "), privacy: .public)
                    """)
            } while pendingCycle
        }
    }

    // MARK: - Cycle

    /// Returns `true` when a convert step landed.
    @discardableResult
    private func runCycle(generation: UInt64, switchLayout: Bool) async -> Bool {
        guard let model else { return false }
        guard generation == cycleGeneration else { return false }

        if model.windows.recordIsKey, let state = model.itemState, state.isEditable, state.isLoaded {
            return await cycleInEditor(state, model: model, switchLayout: switchLayout)
        }

        if IsSecureEventInputEnabled() {
            present(String(localized: "Can’t convert layout in a secure field."), error: true)
            return false
        }

        guard AccessibilityBridge.isTrusted else {
            AccessibilityBridge.requestTrust()
            present(
                String(localized: "To convert layout in other apps, allow Memopila in System Settings → Privacy & Security → Accessibility."),
                error: true
            )
            return false
        }

        let materials = await InputSourceController.cycleMaterials()
        guard materials.ids.count >= 2 else {
            present(
                String(localized: "Add another keyboard layout in System Settings → Keyboard → Input Sources."),
                error: true
            )
            return false
        }
        // Cycle only layouts that actually produced a key map — empty shells waste orbit steps.
        let layoutIDs = materials.ids.filter { (materials.charsets[$0]?.count ?? 0) > 0 }
        guard layoutIDs.count >= 2 else {
            present(
                String(localized: "Could not read keyboard layout maps. Try toggling an input source once."),
                error: true
            )
            return false
        }
        // Orbit = current + previously used layout (the ⌃Space pair); all layouts only when the
        // history is unknown or the text was typed in neither (caret mode falls back itself).
        let orbitIDs = Self.recentPair(layoutIDs) ?? layoutIDs
        var cycleLayoutIDs = orbitIDs

        let targetApp = Self.targetApplication(lastOther: model.monitor.lastOtherApp)
        guard let pid = targetApp?.processIdentifier else {
            // No other app to target — ⌘C/⌘V would hit Memopila itself.
            present(selectHint(model), error: false)
            return false
        }
        // Host class decides the path (PLAN §3.9.1). Act on keyDown everywhere: held hotkey
        // modifiers are not merged into our explicit-flag events (receiver proof).
        if let bundle = targetApp?.bundleIdentifier, Self.isKnownAXMuteBundle(bundle) {
            noteAXTreeMute(pid)
        } else if let app = targetApp, Self.bundlesElectron(app) {
            // Any Electron app (Slack, Discord, Signal, Claude, Postman…): same AX lies as Cursor
            // (partial spans, writes that “succeed” without changing the text) → ⌘C / keystrokes.
            noteAXTreeMute(pid)
        }
        trace.host = targetApp?.bundleIdentifier ?? "pid \(pid)"
        trace.kind = targetApp.flatMap(\.bundleIdentifier).map(Self.isTerminalBundle) == true ? "terminal"
            : isAXSelectionFake(pid) ? "fake-ax"
            : isAXTreeMute(pid) ? "keys" : "native"
        let fallbackElement: AXUIElement? = {
            guard case .global(let sessionPID) = sessionScope, sessionPID == pid else { return nil }
            return sessionElement
        }()
        let fallbackRange: CFRange? = {
            guard case .global(let sessionPID) = sessionScope, sessionPID == pid else { return nil }
            return sessionRange
        }()
        let readOutcome = await readSelection(
            pid: pid,
            fallback: fallbackElement,
            fallbackRange: fallbackRange,
            monitor: model.monitor
        )
        let read: SelectionRead
        var caretBoundaryID: String?
        var caretSourceID: String?
        var caretTail: String?
        var caretAXElement: AXUIElement?
        switch readOutcome {
        case .selection(let live) where !LayoutConverter.letters(in: live.text).isEmpty:
            read = live
            trace.mode = "selection"
            // Copied from elsewhere and typed in a layout outside the pair → cycle all layouts.
            cycleLayoutIDs = Self.orbit(for: live.text, pair: orbitIDs, all: layoutIDs, charsets: materials.charsets)
        case .empty:
            // Terminals have no editable line under AX/keys (iTerm: the AX path read the
            // screen buffer, ⌫×8 + typed, readback differed) — caret mode is off for them in every
            // path; select the typed text instead (⌫ + retype, see deliverIntoTerminal).
            if let bundle = targetApp?.bundleIdentifier, Self.isTerminalBundle(bundle) {
                present(selectHint(model), error: false, anchorPID: pid)
                return false
            }
            // Native host: AX gives the caret and the text before it — no keystrokes, no wait.
            var picked: CaretPick?
            if !isAXTreeMute(pid) {
                picked = readCaretSpanAX(
                    pid: pid, layoutIDs: orbitIDs, allLayoutIDs: layoutIDs,
                    charsets: materials.charsets, maps: materials.maps
                )
            }
            // (Not a terminal signal: Slack also writes nothing for ⌘C without a selection —
            // and was refused. A terminal stops by itself below: the prefix ⌘C copies
            // nothing and is not retried.)
            // No selection: convert back to the first correctly typed letter (macOS flipped the
            // layout after it), else the last word. Selected and proven via ⌘C before replace.
            if picked == nil {
                picked = await readCaretSpan(
                    pid: pid,
                    bundleID: targetApp?.bundleIdentifier,
                    monitor: model.monitor,
                    layoutIDs: orbitIDs,
                    allLayoutIDs: layoutIDs,
                    charsets: materials.charsets,
                    maps: materials.maps
                )
            }
            guard let caret = picked else {
                present(selectHint(model), error: false, anchorPID: pid, range: fallbackRange, element: fallbackElement)
                return false
            }
            read = caret.read
            trace.mode = "caret"
            caretBoundaryID = caret.boundaryLayoutID
            caretSourceID = caret.sourceLayoutID
            caretTail = caret.tail
            caretAXElement = caret.axElement
            cycleLayoutIDs = caret.orbitIDs
        case .secret:
            trace.notes.append("concealed")
            present(
                String(localized: "Can’t convert concealed text (password manager)."),
                error: true,
                anchorPID: pid
            )
            return false
        case .selection:
            present(selectHint(model), error: false, anchorPID: pid, range: fallbackRange, element: fallbackElement)
            return false
        }
        guard LayoutConverter.isConvertibleLength(read.text) else {
            present(
                String(localized: "Select a shorter fragment (up to 120 characters)."),
                error: true,
                anchorPID: pid,
                range: read.range,
                element: read.element ?? fallbackElement
            )
            return false
        }

        let scope: SessionScope? = .global(pid)
        let prior = continuingSession(
            selection: read.text,
            scope: scope,
            range: read.range,
            element: read.element ?? fallbackElement
        )
        let orbitCharsets = Self.charsets(for: cycleLayoutIDs, in: materials.charsets)
        // Caret span: `from` is the layout that typed the span (detected from the text), not
        // necessarily the current one — our previous TIS often already switched to the target.
        let currentID = caretSourceID ?? InputSourceController.currentLayoutID()
        let step = LayoutConverter.cycle(
            selection: read.text,
            layoutIDs: cycleLayoutIDs,
            maps: materials.maps,
            charsets: orbitCharsets,
            currentID: currentID,
            session: prior,
            preferredTargetID: caretBoundaryID
        )

        switch step {
        case .failed(let failure):
            // Stale orbit + tiny live selection (logs: clipboard 1 vs session 6) must not linger.
            clearSession()
            present(
                failureMessage(failure),
                error: true,
                anchorPID: pid,
                range: read.range,
                element: read.element ?? fallbackElement
            )
            return false
        case .output(let text, let targetID, let next, _):
            let length = (text as NSString).length
            let pasteRead = read
            let identity = text == read.text
            // Live ⌘C keeps the highlight — inject replaces it. Never ⇧←-restore (mute landmine).
            let keepRange = pasteRead.range.map { CFRange(location: $0.location, length: length) }

            guard generation == cycleGeneration else { return false }

            // Terminal: a selection there is not editable — ⌫ deletes before the prompt cursor.
            // Delete as many characters as were selected (the user selects what they just typed
            // at the end of the line), then type the result.
            if caretTail == nil, !identity, isTerminalTarget(bundleID: targetApp?.bundleIdentifier, pid: pid) {
                guard await deliverIntoTerminal(text: text, previous: pasteRead.text, pid: pid) else {
                    present(
                        String(localized: "Could not replace the selection."),
                        error: true,
                        anchorPID: pid
                    )
                    return false
                }
                remember(session: next, scope: scope, range: nil, element: nil)
                switchInputSource(to: targetID, pid: pid)
                return true
            }

            let replaced: ReplaceResult
            if identity {
                replaced = ReplaceResult(ok: true, element: pasteRead.element ?? fallbackElement)
            } else if let caretAXElement, let caretTail, let spanRange = pasteRead.range {
                replaced = await replaceCaretSpanNative(
                    text: text, previous: pasteRead.text, pid: pid,
                    element: caretAXElement, range: spanRange, tail: caretTail
                )
            } else {
                replaced = await replaceSelection(
                    text: text,
                    previous: pasteRead.text,
                    pid: pid,
                    range: pasteRead.range,
                    preferred: pasteRead.element ?? fallbackElement,
                    keystrokesOnly: caretTail != nil && caretAXElement == nil,
                    keepSelection: caretTail == nil
                )
            }
            guard replaced.ok else {
                if replaced.retry {
                    pendingCycle = true
                    pendingSwitchLayout = pendingSwitchLayout || switchLayout
                    return false
                }
                present(
                    String(localized: "Could not replace the selection."),
                    error: true,
                    anchorPID: pid,
                    range: pasteRead.range,
                    element: pasteRead.element ?? fallbackElement
                )
                return false
            }

            if let caretTail {
                // No selection was made by the user: put the caret back where they typed (a kept
                // selection would be typed over). The next press continues the orbit from memory.
                if let caretAXElement, let spanRange = pasteRead.range {
                    let caretAt = spanRange.location + length + (caretTail as NSString).length
                    _ = AccessibilityBridge.setSelectedTextRange(
                        on: caretAXElement, range: CFRange(location: caretAt, length: 0)
                    )
                } else if !caretTail.isEmpty {
                    // The caret sits at the end of the converted span — step over the tail, and let
                    // the host apply it before the switch (a later caret move hides the indicator;
                    // Cursor chat applies keys ~30 ms late).
                    AccessibilityBridge.moveRight(characters: caretTail.count)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                remember(session: next, scope: scope, range: nil, element: nil)
                sessionCaretTail = caretTail
                switchInputSource(to: targetID, pid: pid)
                return true
            }

            // Hosts whose AX selection is fake (Telegram, WhatsApp): the keystroke delivery already
            // re-selected the result; any AX range “stick” here moved the real selection onto
            // stale offsets (Telegram: every next press saw a shifted 6-char window,
            // “live ≠ orbit”, and the text degenerated). TIS only.
            if isAXSelectionFake(pid) {
                remember(session: next, scope: scope, range: nil, element: nil)
                switchInputSource(to: targetID, pid: pid)
                return true
            }

            var field = AccessibilityBridge.resolveField(
                pid: pid,
                preferred: replaced.element ?? pasteRead.element ?? fallbackElement
            )
            // Clipboard replace often leaves no AX handle — recover via system-wide focus before TIS.
            if field == nil {
                field = AccessibilityBridge.systemFocusedElement()
                    ?? AccessibilityBridge.focusedElement(of: pid)
            }
            var computedRange = selectionRangeAfterReplace(
                element: field,
                pid: pid,
                previousRange: pasteRead.range,
                replacementLength: length
            )
            if computedRange == nil, let field,
               let live = AccessibilityBridge.selectedText(on: field),
               live.text == text {
                computedRange = live.range
            }
            if computedRange == nil, let field,
               let live = AccessibilityBridge.selectedTextRange(on: field),
               live.length == length {
                computedRange = live
            }
            let newRange = computedRange ?? keepRange

            // Lock session *before* TIS: the next ⌥⌘B must re-anchor even if the highlight never
            // sticks. Stick the selection first, let it settle briefly, then switch layout —
            // immediate TISSelect was racing the range set and clearing it in the same turn.
            remember(session: next, scope: scope, range: newRange, element: field)
            // Mute: TIS only (an AX range stick is a no-op or a lie there). Non-mute may stick range.
            if isAXTreeMute(pid) {
                switchInputSource(to: targetID, pid: pid)
            } else if let newRange {
                let live = AccessibilityBridge.resolveField(pid: pid, preferred: field)
                if let live {
                    _ = AccessibilityBridge.setSelectedTextRange(on: live, range: newRange)
                    remember(session: next, scope: scope, range: newRange, element: live)
                    await selectLayoutPreservingSelection(
                        targetID: targetID, element: live, pid: pid, range: newRange
                    )
                } else {
                    await selectLayoutPreservingSelection(
                        targetID: targetID, element: field, pid: pid, range: newRange
                    )
                }
            } else {
                // (No findAndSelect of the output text: it can pick another occurrence.)
                switchInputSource(to: targetID, pid: pid)
            }
            return true
        }
    }

    @discardableResult
    private func cycleInEditor(_ state: ItemState, model: AppModel, switchLayout: Bool) async -> Bool {
        trace.host = "memopila-card"
        trace.kind = "editor"
        trace.delivery = "editor"
        let materials = await InputSourceController.cycleMaterials()
        let allLayoutIDs = materials.ids.filter { (materials.charsets[$0]?.count ?? 0) > 0 }
        guard allLayoutIDs.count >= 2 else {
            model.toasts.error(String(localized: "Add another keyboard layout in System Settings → Keyboard → Input Sources."))
            return false
        }
        let pairIDs = Self.recentPair(allLayoutIDs) ?? allLayoutIDs

        // Selection → convert it and keep it selected. No selection → caret-span rules on the
        // line (direct text access, no keystrokes), caret returns where it was.
        let input: (text: String, range: NSRange)
        var layoutIDs: [String]
        var fromID = InputSourceController.currentLayoutID()
        var preferredTargetID: String?
        var caretTail: String?
        var caret = 0
        var wholeTextCaret: Int?
        if let selected = state.layoutConvertSelection() {
            input = selected
            trace.mode = "selection"
            layoutIDs = Self.orbit(for: selected.text, pair: pairIDs, all: allLayoutIDs, charsets: materials.charsets)
        } else if !switchLayout, let whole = state.layoutConvertWholeText() {
            // Toolbar button, nothing selected: the whole card (user: “the button should convert
            // everything”) — a document action like the other toolbar transforms. The hotkey keeps
            // the typing-flow caret span.
            input = (whole.text, whole.range)
            layoutIDs = Self.orbit(for: whole.text, pair: pairIDs, all: allLayoutIDs, charsets: materials.charsets)
            wholeTextCaret = whole.caret
            trace.mode = "whole-text"
        } else if let line = state.layoutConvertLinePrefix(), let currentID = fromID {
            let remembered = sessionCaretTail ?? ""
            var span: LayoutConverter.CaretSpan?
            var spanIDs = pairIDs
            if let session, let expires = sessionExpires, ContinuousClock.now < expires, sessionScope == .editor,
               !session.lastOutput.isEmpty, line.prefix.hasSuffix(session.lastOutput + remembered) {
                span = .init(text: session.lastOutput, boundaryLayoutID: nil, sourceLayoutID: currentID, tail: remembered)
                spanIDs = session.layoutIDs
            } else {
                let validator = Self.wordValidator(layoutIDs: allLayoutIDs)
                span = LayoutConverter.caretSpan(
                    prefix: line.prefix, currentID: currentID, layoutIDs: pairIDs, charsets: materials.charsets,
                    maps: materials.maps, isValidWord: validator
                )
                if span == nil, pairIDs != allLayoutIDs {
                    span = LayoutConverter.caretSpan(
                        prefix: line.prefix, currentID: currentID, layoutIDs: allLayoutIDs,
                        charsets: materials.charsets, maps: materials.maps, isValidWord: validator
                    )
                    spanIDs = allLayoutIDs
                }
            }
            guard let span else {
                model.toasts.show(selectHint(model))
                return false
            }
            let spanLength = (span.text as NSString).length
            let tailLength = (span.tail as NSString).length
            input = (span.text, NSRange(location: line.caret - tailLength - spanLength, length: spanLength))
            layoutIDs = spanIDs
            fromID = span.sourceLayoutID
            preferredTargetID = span.boundaryLayoutID
            caretTail = span.tail
            trace.mode = "caret"
            caret = line.caret
        } else {
            model.toasts.show(selectHint(model))
            return false
        }
        guard !LayoutConverter.letters(in: input.text).isEmpty || caretTail != nil else {
            model.toasts.show(selectHint(model))
            return false
        }
        // Direct, undoable replace in the card: the 120 cap (keystroke delivery) does not apply to
        // the whole-text button; only very large texts are refused.
        let fits = wholeTextCaret != nil
            ? input.range.length <= 100_000
            : LayoutConverter.isConvertibleLength(input.text)
        guard fits else {
            model.toasts.error(String(localized: "Select a shorter fragment (up to 120 characters)."))
            return false
        }

        let inputRange = CFRange(location: input.range.location, length: input.range.length)
        let prior = continuingSession(
            selection: input.text,
            scope: .editor,
            range: inputRange,
            element: nil
        )

        let orbitCharsets = Self.charsets(for: layoutIDs, in: materials.charsets)
        let step = LayoutConverter.cycle(
            selection: input.text,
            layoutIDs: layoutIDs,
            maps: materials.maps,
            charsets: orbitCharsets,
            currentID: fromID,
            session: prior,
            preferredTargetID: preferredTargetID
        )

        switch step {
        case .failed(let failure):
            model.toasts.error(failureMessage(failure))
            return false
        case .output(let text, let targetID, let next, _):
            state.replaceLayoutConvert(range: input.range, with: text)
            let outLength = (text as NSString).length
            let keep = NSRange(location: input.range.location, length: outLength)
            remember(
                session: next,
                scope: .editor,
                range: CFRange(location: keep.location, length: keep.length),
                element: nil
            )
            if let wholeTextCaret {
                // Caret stays put (a select-all would be typed over); the next click finds no
                // selection, takes the whole text again and continues the orbit (same range).
                state.textView?.setSelectedRange(NSRange(location: min(wholeTextCaret, outLength), length: 0))
                return true
            }
            if let caretTail {
                sessionCaretTail = caretTail
                let back = NSRange(location: caret + outLength - input.range.length, length: 0)
                state.textView?.setSelectedRange(back)
                if switchLayout {
                    switchInputSource(to: targetID, pid: nil) { [weak state] in
                        state?.textView?.setSelectedRange(back)
                    }
                }
                return true
            }
            state.textView?.setSelectedRange(keep)
            if switchLayout {
                switchInputSource(to: targetID, pid: nil) { [weak state] in
                    state?.textView?.setSelectedRange(keep)
                }
            }
            scheduleEditorSelectionRestore(state: state, range: keep)
            return true
        }
    }

    // MARK: - Session

    private func continuingSession(
        selection: String,
        scope: SessionScope?,
        range: CFRange?,
        element: AXUIElement?
    ) -> LayoutConverter.CycleSession? {
        guard let session, let expires = sessionExpires, ContinuousClock.now < expires else {
            clearSession()
            return nil
        }
        guard sessionScope == scope else { return nil }
        // Same characters elsewhere in the document must start a new orbit — otherwise we
        // replace the new selection with a remap of the *previous* original.
        if selection == session.lastOutput || selection == session.original {
            if let sessionRange, let range, range.location != sessionRange.location {
                return nil
            }
            return session
        }
        if case .global(let pid) = scope, let sessionRange {
            let live = element.flatMap { AccessibilityBridge.selectedText(on: $0) }
                ?? AccessibilityBridge.selectedText(pid: pid)
            if let live,
               live.range.location == sessionRange.location,
               live.text == session.lastOutput || live.text == session.original {
                return session
            }
        }
        return nil
    }

    private func remember(
        session: LayoutConverter.CycleSession,
        scope: SessionScope?,
        range: CFRange?,
        element: AXUIElement?
    ) {
        self.session = session
        sessionCaretTail = nil
        sessionScope = scope
        sessionRange = range
        sessionElement = element
        sessionExpires = .now + Self.sessionTTL
    }

    private func clearSession() {
        session = nil
        sessionCaretTail = nil
        sessionScope = nil
        sessionRange = nil
        sessionElement = nil
        sessionExpires = nil
    }

    private func selectHint(_ model: AppModel) -> String {
        let keys = model.settings.layoutConvertShortcut.displayString
        return String(localized: "Select the text to convert, then press \(keys).")
    }

    private func failureMessage(_ failure: LayoutConverter.CycleFailure) -> String {
        switch failure {
        case .needMoreLayouts:
            String(localized: "Add another keyboard layout in System Settings → Keyboard → Input Sources.")
        case .uncertainSource:
            String(localized: "Could not read the current keyboard layout. Try switching layout once in the menu bar.")
        case .emptyText:
            String(localized: "Select text with letters to convert.")
        }
    }

    private func present(
        _ message: String,
        error: Bool,
        anchorPID: pid_t? = nil,
        range: CFRange? = nil,
        element: AXUIElement? = nil
    ) {
        // Prefer the session/field element — focused query fails while the language HUD is up.
        // Electron hosts report no usable AX geometry (Discord: hint toast at a random spot) —
        // anchor at the mouse pointer there.
        let anchor: CGRect?
        if let anchorPID, isAXTreeMute(anchorPID) {
            let point = NSEvent.mouseLocation
            anchor = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        } else {
            anchor = AccessibilityBridge.selectedTextBounds(element: element, pid: anchorPID, range: range)
        }
        FloatingToastHost.shared.present(message, isError: error, anchor: anchor, force: true)
        // Floating already carries the message near the text; duplicating into History/Record
        // toasts made every miss show twice when the panel was open.
    }

    // MARK: - Selection I/O

    private struct SelectionRead {
        var text: String
        var range: CFRange?
        var element: AXUIElement?
        /// OS highlight still covers `text` (⌘C / AX). Delivery injects into it — never ⇧←.
        var highlightIntact: Bool
    }

    /// Clipboard copy outcome — mods-blocked vs empty (no geometry fallback either way).
    private enum ClipboardPick {
        case read(SelectionRead)
        case empty
        /// The host marked the copy concealed (password manager) — never convert it.
        case secret
    }

    private enum ReadOutcome {
        case selection(SelectionRead)
        case empty
        case secret
    }

    private func readSelection(
        pid: pid_t?,
        fallback: AXUIElement?,
        fallbackRange: CFRange?,
        monitor: ClipboardMonitor
    ) async -> ReadOutcome {
        let mute = pid.map(isAXTreeMute) ?? false

        // Root cause on Cursor/Electron: AXSelectedText / system-wide focus often return a
        // partial or stale span while the real highlight is longer. Mute → ⌘C only.
        if mute {
            return await readLiveClipboardSelection(pid: pid, monitor: monitor, mute: true)
        }

        if let pid, isAXSelectionFake(pid) {
            // ⌘C copies only a real selection; nothing copied → caret mode (AX text + ⌫).
            return await readLiveClipboardSelection(pid: pid, monitor: monitor, mute: false)
        }

        let focused = pid.flatMap { AccessibilityBridge.focusedElement(of: $0) }
        if let focused, let ax = AccessibilityBridge.selectedText(on: focused), !ax.text.isEmpty {
            return .selection(SelectionRead(text: ax.text, range: ax.range, element: focused, highlightIntact: true))
        }
        // AX reports a plain caret → there is no selection. Never re-select a previous span (old
        // reanchor by searching the output: TextEdit re-converted the last 9 chars after the user
        // clicked elsewhere) and no ⌘C (a native caret has nothing to copy).
        if let focused, let caret = AccessibilityBridge.selectedTextRange(on: focused), caret.length == 0 {
            return .empty
        }

        // Probe once — walking 480 nodes before mute cost ~100ms every cold start.
        if let pid {
            let probe = AccessibilityBridge.focusedElementProbe(pid: pid)
            if !probe.appOK {
                noteAXTreeMute(pid)
                trace.notes.append("learned:no-ax")
                return await readLiveClipboardSelection(pid: pid, monitor: monitor, mute: true)
            }
            if let hit = AccessibilityBridge.findSelectedText(pid: pid),
               !LayoutConverter.letters(in: hit.text).isEmpty {
                return .selection(SelectionRead(
                    text: hit.text, range: hit.range, element: hit.element, highlightIntact: true
                ))
            }
            // The focused element knows no caret and the (time-boxed) walk found no selection: this
            // host's AX text model is incomplete (Mail compose: 1.5 s walk on every press, then an
            // AX write that “succeeded” without changing the text). Treat it like Electron from now on.
            noteAXTreeMute(pid)
            trace.notes.append("learned:no-ax-selection")
            return await readLiveClipboardSelection(pid: pid, monitor: monitor, mute: true)
        }

        if let pid, let ax = AccessibilityBridge.selectedText(pid: pid), !ax.text.isEmpty {
            return .selection(SelectionRead(
                text: ax.text,
                range: ax.range,
                element: AccessibilityBridge.focusedElement(of: pid),
                highlightIntact: true
            ))
        }

        let clipboard = await readLiveClipboardSelection(pid: pid, monitor: monitor, mute: false)
        if case .selection = clipboard { return clipboard }
        if case .secret = clipboard { return clipboard }

        return .empty
    }

    /// ⌘C under History suppress. Clears remap session when live ≠ orbit text.
    private func readLiveClipboardSelection(
        pid: pid_t?,
        monitor: ClipboardMonitor,
        mute: Bool
    ) async -> ReadOutcome {
        let sessionText = session?.lastOutput ?? session?.original
        let sessionOK = sessionText.map { !LayoutConverter.letters(in: $0).isEmpty } ?? false

        let pick = await copySelectionViaClipboard(pid: pid, monitor: monitor)
        switch pick {
        case .secret:
            return .secret
        case .read(let live) where !LayoutConverter.letters(in: live.text).isEmpty:
            let isOrbit = sessionOK && (live.text == sessionText || live.text == session?.original)
            if sessionOK, !isOrbit {
                clearSession()
            } else {
            }
            return .selection(live)


        case .read, .empty:
            return .empty
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// `true`/`false` when a non-standard pasteboard type carries VS Code's
    /// `"isFromEmptySelection"` flag (Chromium packs custom DataTransfer types into one blob,
    /// UTF-16), `nil` when no type mentions it.
    private static func emptySelectionCopyFlag(_ pasteboard: NSPasteboard) -> Bool? {
        for type in pasteboard.types ?? [] where !type.rawValue.hasPrefix("public.") {
            guard let data = pasteboard.data(forType: type), data.count <= 256 * 1024,
                  let flag = LayoutConvertDelivery.emptySelectionCopyFlag(in: data) else { continue }
            return flag
        }
        return nil
    }

    /// Electron often bumps `changeCount` before `.string` is readable (logs: changed=true, no
    /// got). Poll plain text and common UTF types until the deadline.
    private static func readPasteboardPlainString(
        from pasteboard: NSPasteboard = .general,
        timeout: Duration = .milliseconds(250)
    ) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let s = pasteboard.string(forType: .string), !s.isEmpty { return s }
            // Cursor chat with nothing selected writes only Chromium-internal types (only
            // source-rfh-token + source-url) — text never arrives; waiting cost 280ms.
            if let types = pasteboard.types, !types.isEmpty,
               !types.contains(where: { Self.isTextPasteboardType($0) }) {
                return nil
            }
            for type in pasteboard.types ?? [] {
                let raw = type.rawValue
                guard raw.contains("text") || raw.contains("utf8") || raw.contains("UTF-8") else { continue }
                if let s = pasteboard.string(forType: type), !s.isEmpty { return s }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isTextPasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let raw = type.rawValue
        return type == .string || raw.contains("text") || raw.contains("utf8") || raw.contains("UTF-8")
            || raw == "NSStringPboardType"
    }

    /// AX-mute apps (Cursor/Electron): no AX range.
    ///
    /// Reselect *before* TIS, then switch layout and stop — never move the caret after TIS
    /// (that dismissed the language HUD). Next ⌥⌘B rebuilds the span in `readSelection`.
    /// When already on `targetID`, TIS is a no-op — show the layout name via toast instead.
    /// Switch on the hotkey press (user: “switch when I press B”). The system input-source
    /// indicator shows for it; a second away-and-back switch after the key-up only showed it
    /// twice (user, 2026-11-26) — the key-up does not hide it.
    private func switchInputSource(
        to targetID: String,
        pid: pid_t?,
        then restick: (@MainActor () -> Void)? = nil
    ) {
        selectLayoutNow(targetID: targetID, pid: pid)
        restick?()
    }

    private func selectLayoutNow(targetID: String, pid: pid_t?) {
        // Feedback is the system input-source indicator only (user: no custom badge). When the
        // layout already is the target nothing switches and macOS shows nothing — fine.
        if !InputSourceController.select(id: targetID) { trace.notes.append("tis-failed") }
    }

    /// Stick selection when AX readback works, then TIS. Mute never reaches here with a range.
    /// No post-TIS ⇧← / long AX pulse — if the HUD clears the highlight, the next press needs
    /// a live selection (P1 TIS beats P2 orbit convenience).
    private func selectLayoutPreservingSelection(
        targetID: String,
        element: AXUIElement?,
        pid: pid_t?,
        range: CFRange?
    ) async {
        guard let range, !isAXTreeMute(pid) else {
            switchInputSource(to: targetID, pid: pid)
            return
        }
        var live = AccessibilityBridge.resolveField(pid: pid, preferred: element)
        let stickDeadline = ContinuousClock.now + .milliseconds(180)
        while ContinuousClock.now < stickDeadline {
            live = AccessibilityBridge.resolveField(pid: pid, preferred: live ?? element)
            if let live {
                let detail = AccessibilityBridge.setSelectedTextRangeDetailed(on: live, range: range)
                if detail.ok,
                   detail.readbackLoc == range.location,
                   detail.readbackLen == range.length {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let live, case .global = sessionScope { sessionElement = live }
        let stuck = live
        switchInputSource(to: targetID, pid: pid) { [weak self] in
            self?.restick(element: stuck ?? element, pid: pid, range: range)
        }
    }

    private func restick(element: AXUIElement?, pid: pid_t?, range: CFRange) {
        if let live = AccessibilityBridge.resolveField(pid: pid, preferred: element) {
            let detail = AccessibilityBridge.setSelectedTextRangeDetailed(on: live, range: range)
            if detail.ok,
               detail.readbackLoc == range.location,
               detail.readbackLen == range.length,
               case .global = sessionScope {
                sessionElement = live
            }
        }
    }

    /// Live selection via ⌘C under History suppress. Proof = `changeCount` advance; PB restored
    /// before return. Never ⌘X (mute landmine).
    private func copySelectionViaClipboard(
        pid: pid_t?,
        monitor: ClipboardMonitor
    ) async -> ClipboardPick {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotItems(pasteboard)

        let keptRecordID = monitor.clipboardRecordID
        let keptStackID = monitor.clipboardStackID

        monitor.beginSuppressExternalCapture()
        defer { monitor.endSuppressExternalCapture() }

        // Held hotkey modifiers do not reach the host (receiver proof) — copy at once, no retry.
        let result = await copyOnce(pasteboard, monitor: monitor)
        lastSelectionCopyTypes = result.text != nil ? result.types : []
        if result.fromEmptySelection {
            // No highlight: injecting here would *insert* a remapped copy of the line at the caret.
            _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
            return .empty
        }

        // KeePassium marks every copy concealed and copies a field value (29 chars) even with
        // nothing selected — converting that would rewrite a secret. Never touch concealed copies.
        if result.text != nil, result.types.contains("org.nspasteboard.ConcealedType") {
            _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
            return .secret
        }
        guard let text = result.text, !text.isEmpty else {
            _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
            return .empty
        }
        _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
        let focused = pid.flatMap { AccessibilityBridge.focusedElement(of: $0) }
            ?? AccessibilityBridge.systemFocusedElement()
        let axSelected = focused.flatMap { AccessibilityBridge.selectedText(on: $0) }
        let liveRange = axSelected?.range
            ?? focused.flatMap { AccessibilityBridge.selectedTextRange(on: $0) }
        let rangeMatchingCopy: CFRange? = {
            if let pid, isAXSelectionFake(pid) { return nil }
            if let axSelected, axSelected.text == text, axSelected.range.length > 0 {
                return axSelected.range
            }
            guard let liveRange, liveRange.length == (text as NSString).length else { return nil }
            return liveRange
        }()
        // ⌘C keeps the host highlight. Mute AX often cannot read the range back — still treat
        // highlight as intact so we inject, never ⇧←-restore.
        return .read(SelectionRead(
            text: text, range: rangeMatchingCopy, element: focused,
            highlightIntact: true
        ))
    }

    /// One synthetic ⌘C. Caller owns snapshot / suppress / restore.
    private struct CopyProbe {
        var changed: Bool
        var text: String?
        var fromEmptySelection: Bool
        /// Pasteboard types of the copy (terminal / concealed detection) — never content.
        var types: [String]
    }

    private func copyOnce(
        _ pasteboard: NSPasteboard,
        monitor: ClipboardMonitor,
        timeout: Duration = .milliseconds(120)
    ) async -> CopyProbe {
        let startCount = pasteboard.changeCount
        monitor.armIgnoreNextContentChange()
        AccessibilityBridge.copy()
        // Copies land in 11–35 ms in every host logged (Cursor, chat, Slack, Telegram); 120 ms
        // keeps 3× headroom and cuts the no-selection wait (browser field: 200 ms for nothing).
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, pasteboard.changeCount == startCount {
            try? await Task.sleep(for: .milliseconds(8))
        }
        let after = pasteboard.changeCount
        guard after != startCount else {
            monitor.cancelIgnoreNextContentChange()
            return CopyProbe(changed: false, text: nil, fromEmptySelection: false, types: [])
        }
        let text = await Self.readPasteboardPlainString(from: pasteboard)
        // VS Code copies the whole line when nothing is selected (emptySelectionClipboard) and
        // marks it in its clipboard metadata.
        let emptyFlag = Self.emptySelectionCopyFlag(pasteboard)
        let types: [String] = (pasteboard.types ?? []).map(\.rawValue)
        if let text, !text.isEmpty {
            monitor.acknowledgeIgnoredContentChange(changeCount: after)
        } else {
            monitor.cancelIgnoreNextContentChange()
        }
        return CopyProbe(
            changed: true,
            text: text.flatMap { $0.isEmpty ? nil : $0 },
            fromEmptySelection: emptyFlag == true,
            types: types
        )
    }

    /// Proof copy that tolerates editors whose copy handler reads a selection state lagging the
    /// DOM (Cursor chat: proof returned the 6-char prefix right after ⇧←×5, or was
    /// empty, yet the next press found the reselected text). Retry until `expect` or out of
    /// attempts — Monaco matches on the first try.
    private func provenCopy(
        _ pasteboard: NSPasteboard,
        monitor: ClipboardMonitor,
        expect: String,
        attempts: Int = 4
    ) async -> (probe: CopyProbe, tries: Int) {
        var probe = await copyOnce(pasteboard, monitor: monitor)
        var tries = 1
        while probe.text != expect, tries < attempts {
            try? await Task.sleep(for: .milliseconds(30))
            probe = await copyOnce(pasteboard, monitor: monitor)
            tries += 1
        }
        return (probe, tries)
    }

    private struct CaretPick {
        var read: SelectionRead
        var boundaryLayoutID: String?
        /// Layout that typed the span — `from` for the cycle (may differ from the current one).
        var sourceLayoutID: String
        /// Text between the span and the caret (left untouched).
        var tail: String
        /// Layouts the span was resolved in — the recent pair, or all when it was typed in neither.
        var orbitIDs: [String]
        /// Native host: the span was selected via AX on this element (deliver + caret via AX).
        var axElement: AXUIElement? = nil
    }

    /// No selection: ⌘⇧← → ⌘C (exact text from line start to caret) → caret back → ⇧←×N →
    /// ⌘C proof. Returns nil (caret restored) unless the proof copy equals the computed span.
    private func readCaretSpan(
        pid: pid_t,
        bundleID: String?,
        monitor: ClipboardMonitor,
        layoutIDs: [String],
        allLayoutIDs: [String],
        charsets: [String: Set<Character>],
        maps: [String: [String: [Character: Character]]]
    ) async -> CaretPick? {
        if let bundleID, Self.isTerminalBundle(bundleID) {
            return nil
        }
        guard let currentID = InputSourceController.currentLayoutID() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotItems(pasteboard)
        let keptRecordID = monitor.clipboardRecordID
        let keptStackID = monitor.clipboardStackID
        monitor.beginSuppressExternalCapture()
        defer { monitor.endSuppressExternalCapture() }

        AccessibilityBridge.selectToLineStart()
        // Cursor chat copies a selection state that lags ⌘⇧← (an empty copy, yet the prefix
        // stayed selected and the next press converted the whole word «П…» → «G…»). Retry while
        // empty; a caret already at line start stays empty on every try (~120ms, then stop).
        var prefixProbe = await copyOnce(pasteboard, monitor: monitor)
        var prefixTries = 1
        // Retry while the copy is empty: a lagging editor (Cursor chat) writes stale/empty data;
        // Discord's editor lags too but writes *nothing* for an empty selection (“no
        // prefix” right after a convert) — so in Electron hosts also retry an unchanged copy,
        // twice and shortly (a terminal then stops after ~0.3 s).
        // Only Electron hosts get the unchanged-copy retries: Mail (AX-mute by its incomplete AX)
        // beeps on every ⌘C without a selection — 4 beeps for one press.
        let electronHost = NSRunningApplication(processIdentifier: pid).map(Self.bundlesElectron) == true
            || (bundleID.map(Self.isKnownAXMuteBundle) ?? false)
        while prefixProbe.text == nil || prefixProbe.fromEmptySelection, prefixTries < 4,
              prefixProbe.changed || (electronHost && prefixTries < 3) {
            try? await Task.sleep(for: .milliseconds(30))
            prefixProbe = await copyOnce(
                pasteboard, monitor: monitor, timeout: prefixProbe.changed ? .milliseconds(120) : .milliseconds(60)
            )
            prefixTries += 1
        }
        guard let prefix = prefixProbe.text, !prefixProbe.fromEmptySelection else {
            // ⌘⇧← selected nothing (caret at line start / empty field) — no collapse key needed.
            _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
            trace.notes.append("no-prefix(tries=\(prefixTries))")
            return nil
        }
        // Back to the caret (only when nothing will be converted, or the span needs a reselect):
        // → lands on the right end. From column 1 of an indented Monaco line Home-select goes
        // *right* (whitespace only) — then ← is the caret side.
        func collapseToCaret() {
            if prefix.allSatisfy(\.isWhitespace) {
                AccessibilityBridge.moveLeft(characters: 1)
            } else {
                AccessibilityBridge.collapseSelectionToEnd()
            }
        }

        // The language HUD may have cleared the highlight of the last convert: if the line still
        // ends with its output, continue that orbit instead of picking a new span.
        let choice = chooseCaretSpan(
            prefix: prefix, pid: pid, currentID: currentID,
            layoutIDs: layoutIDs, allLayoutIDs: allLayoutIDs, charsets: charsets, maps: maps
        )
        let continued = choice.continued
        let spanLayoutIDs = choice.layoutIDs
        guard let span = choice.span else {
            collapseToCaret()
            _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
            trace.notes.append("nothing-to-convert")
            return nil
        }
        // ⌘⇧← left the prefix selected (anchor at the caret, active end at line start). Visible
        // flicker came from collapsing it and re-selecting char by char (browser field, whole
        // line: select → deselect → ⇧←×10 → type). Reuse it when possible:
        //   span == prefix → it already is the selection (the prefix copy is the proof);
        //   span is a short suffix → shrink from the left with ⇧→;
        //   otherwise (tail / long shrink) → collapse and re-select as before.
        let shrink = prefix.count - span.text.count
        let reuse: String
        let proof: CopyProbe
        if span.tail.isEmpty, span.text == prefix {
            reuse = "prefix-selection"
            proof = prefixProbe
        } else if span.tail.isEmpty, prefix.hasSuffix(span.text), shrink > 0, shrink <= 16 {
            reuse = "shrink"
            AccessibilityBridge.selectRight(characters: shrink)
            proof = await provenCopy(pasteboard, monitor: monitor, expect: span.text).probe
        } else {
            reuse = "reselect"
            collapseToCaret()
            if !span.tail.isEmpty { AccessibilityBridge.moveLeft(characters: span.tail.count) }
            AccessibilityBridge.selectLeft(characters: span.text.count)
            proof = await provenCopy(pasteboard, monitor: monitor, expect: span.text).probe
        }
        _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
        let matches = proof.text == span.text
        trace.notes.append("caret:\(reuse)\(continued ? "+orbit" : "")\(matches ? "" : " caret-proof-mismatch")")
        guard matches else {
            AccessibilityBridge.collapseSelectionToEnd()
            if reuse == "reselect", !span.tail.isEmpty { AccessibilityBridge.moveRight(characters: span.tail.count) }
            return nil
        }
        return CaretPick(
            read: SelectionRead(text: span.text, range: nil, element: nil, highlightIntact: true),
            boundaryLayoutID: span.boundaryLayoutID,
            sourceLayoutID: span.sourceLayoutID,
            tail: span.tail,
            orbitIDs: spanLayoutIDs
        )
    }

    /// Span choice shared by the keystroke and AX caret readers: continue the orbit when the line
    /// still ends with the last output (+ tail), else `caretSpan` in the recent pair, then in all
    /// layouts (text typed in a rare third layout).
    private func chooseCaretSpan(
        prefix: String,
        pid: pid_t,
        currentID: String,
        layoutIDs: [String],
        allLayoutIDs: [String],
        charsets: [String: Set<Character>],
        maps: [String: [String: [Character: Character]]]
    ) -> (span: LayoutConverter.CaretSpan?, layoutIDs: [String], continued: Bool) {
        let rememberedTail = sessionCaretTail ?? ""
        let validator = Self.wordValidator(layoutIDs: allLayoutIDs)
        if let session, let expires = sessionExpires, ContinuousClock.now < expires,
           sessionScope == .global(pid), !session.lastOutput.isEmpty,
           prefix.hasSuffix(session.lastOutput + rememberedTail) {
            let span = LayoutConverter.CaretSpan(
                text: session.lastOutput, boundaryLayoutID: nil, sourceLayoutID: currentID, tail: rememberedTail
            )
            return (span, session.layoutIDs, true)
        }
        if let span = LayoutConverter.caretSpan(
            prefix: prefix, currentID: currentID, layoutIDs: layoutIDs, charsets: charsets,
            maps: maps, isValidWord: validator
        ) {
            return (span, layoutIDs, false)
        }
        if allLayoutIDs != layoutIDs, let span = LayoutConverter.caretSpan(
            prefix: prefix, currentID: currentID, layoutIDs: allLayoutIDs, charsets: charsets,
            maps: maps, isValidWord: validator
        ) {
            return (span, allLayoutIDs, false)
        }
        return (nil, layoutIDs, false)
    }

    /// Native hosts: no keystrokes at all. AX gives the caret and the text before it; select the
    /// span with `AXSelectedTextRange` and verify it reads back (Notes: the keystroke
    /// path's ⌘C copied nothing there).
    private func readCaretSpanAX(
        pid: pid_t,
        layoutIDs: [String],
        allLayoutIDs: [String],
        charsets: [String: Set<Character>],
        maps: [String: [String: [Character: Character]]]
    ) -> CaretPick? {
        guard let element = AccessibilityBridge.focusedElement(of: pid),
              let caretRange = AccessibilityBridge.selectedTextRange(on: element), caretRange.length == 0,
              let currentID = InputSourceController.currentLayoutID() else { return nil }
        let caret = caretRange.location
        let lookback = min(caret, 600)
        guard lookback > 0,
              let before = AccessibilityBridge.text(on: element, range: CFRange(location: caret - lookback, length: lookback))
        else { return nil }
        let prefix = before.components(separatedBy: .newlines).last ?? ""
        let choice = chooseCaretSpan(
            prefix: prefix, pid: pid, currentID: currentID,
            layoutIDs: layoutIDs, allLayoutIDs: allLayoutIDs, charsets: charsets, maps: maps
        )
        guard let span = choice.span else {
            return nil
        }
        let spanLength = (span.text as NSString).length
        let tailLength = (span.tail as NSString).length
        let range = CFRange(location: caret - tailLength - spanLength, length: spanLength)
        _ = AccessibilityBridge.setSelectedTextRange(on: element, range: range)
        let readBack = AccessibilityBridge.selectedText(on: element)?.text
        guard readBack == span.text else {
            trace.notes.append("ax-caret-readback-mismatch")
            _ = AccessibilityBridge.setSelectedTextRange(on: element, range: CFRange(location: caret, length: 0))
            return nil
        }
        return CaretPick(
            read: SelectionRead(text: span.text, range: range, element: element, highlightIntact: true),
            boundaryLayoutID: span.boundaryLayoutID,
            sourceLayoutID: span.sourceLayoutID,
            tail: span.tail,
            orbitIDs: choice.layoutIDs,
            axElement: element
        )
    }

    /// Keystroke delivery into the live selection, then re-select the result (⇧←×N — receiver:
    /// exact, 10/10) so the next press cycles it, and prove it with ⌘C. The proof copy also
    /// guarantees a paste was consumed before the user's pasteboard is restored.
    /// `keepSelection: false` (caret mode): no re-select and no collapse — typing over the span
    /// leaves the caret right where the user typed. Any caret move reaching Cursor's chat after
    /// the input-source switch hid the system indicator (a `→` posted 2–5 ms
    /// before TIS, indicator “not always”; selection mode, no keys after deliver: always shown).
    private func deliverViaKeystrokes(
        text: String,
        pid: pid_t?,
        monitor: ClipboardMonitor,
        keepSelection: Bool = true
    ) async -> Bool {
        let usePaste = LayoutConvertDelivery.needsPaste(text)
        if !keepSelection, !usePaste {
            trace.delivery = "typed"
            await AccessibilityBridge.injectUnicode(text)
            return true
        }
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotItems(pasteboard)
        let keptRecordID = monitor.clipboardRecordID
        let keptStackID = monitor.clipboardStackID
        monitor.beginSuppressExternalCapture()
        defer { monitor.endSuppressExternalCapture() }
        trace.delivery = usePaste ? "pasted" : "typed"

        if usePaste {
            if case .failed = await monitor.writeTransientPlainText(text) {
                _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
                return false
            }
            AccessibilityBridge.pasteForLayoutConvert()
        } else {
            await AccessibilityBridge.injectUnicode(text)
        }
        let proof: CopyProbe
        if keepSelection {
            AccessibilityBridge.selectLeft(characters: text.count)
            proof = await provenCopy(pasteboard, monitor: monitor, expect: text).probe
            if proof.text != text { trace.notes.append("proof-mismatch") }
        } else {
            // Caret mode paste: an empty-selection ⌘C only proves the paste was consumed (it is
            // queued behind ⌘V) before the user's pasteboard is restored — no caret move.
            proof = await copyOnce(pasteboard, monitor: monitor)
        }
        if usePaste, !proof.changed {
            // Host is slow: never restore before it read our paste buffer.
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
        return true
    }

    /// macOS spelling (offline; ru/en/es present — scratch probe 2026-11-26, ~1 ms/word) keyed by
    /// each layout's primary language. Layouts without a dictionary return nil (no verdict).
    /// NSSpellChecker per layout, keyed by the layout's primary language; `nil` verdict for a
    /// layout without an installed dictionary.
    private static func wordValidator(layoutIDs: [String]) -> LayoutConverter.WordValidator {
        let available = NSSpellChecker.shared.availableLanguages
        var languages: [String: String] = [:]
        for id in layoutIDs {
            guard let language = InputSourceController.primaryLanguage(id: id) else { continue }
            if let match = available.first(where: { $0 == language })
                ?? available.first(where: { $0.hasPrefix(language) }) {
                languages[id] = match
            }
        }
        return { word, layoutID in
            guard let language = languages[layoutID] else { return nil }
            return MainActor.assumeIsolated {
                NSSpellChecker.shared.checkSpelling(
                    of: word, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                ).location == NSNotFound
            }
        }
    }

    /// The recent pair, unless `text` has letters neither of them types (text copied from someone
    /// typing in another layout, e.g. `ñ`) — then every enabled layout.
    private static func orbit(
        for text: String,
        pair: [String],
        all: [String],
        charsets: [String: Set<Character>]
    ) -> [String] {
        guard pair != all else { return all }
        let covered = pair.reduce(into: Set<Character>()) { $0.formUnion(charsets[$1] ?? []) }
        return LayoutConverter.letters(in: text).allSatisfy(covered.contains) ? pair : all
    }

    /// Current + previously used layout, in Input Sources order; nil when either is unknown.
    private static func recentPair(_ layoutIDs: [String]) -> [String]? {
        guard let current = InputSourceController.currentLayoutID(), layoutIDs.contains(current),
              let previous = InputSourceController.previousLayoutID(current: current),
              layoutIDs.contains(previous) else { return nil }
        return layoutIDs.filter { $0 == current || $0 == previous }
    }

    /// Standalone terminals by bundle; inside an Electron host (Cursor's terminal) by the copy:
    /// every DOM copy in Monaco / chat / web fields carried Blink's provenance types
    /// (`org.chromium.internal.source-rfh-token`, logs), while VS Code's terminal copies through
    /// Electron's clipboard API. Hypothesis until a terminal copy is logged (`pbTypes`).
    private func isTerminalTarget(bundleID: String?, pid: pid_t) -> Bool {
        if let bundleID, Self.isTerminalBundle(bundleID) { return true }
        // Only Electron hosts embed a terminal (Cursor / VS Code). Mail (WebKit, AX-mute by the
        // probe) copies without Chromium's provenance type too and was taken for a terminal:
        // ⌫×3 on a real selection ate it plus the space smart delete took.
        guard isAXTreeMute(pid), !lastSelectionCopyTypes.isEmpty,
              let app = NSRunningApplication(processIdentifier: pid),
              Self.bundlesElectron(app) || (bundleID.map(Self.isKnownAXMuteBundle) ?? false)
        else { return false }
        return !lastSelectionCopyTypes.contains("org.chromium.internal.source-rfh-token")
            && !lastSelectionCopyTypes.contains("org.chromium.web-custom-data")
    }

    /// ⌫ × selected characters, settle, type the result. Deletes are spaced (reLayout: Electron
    /// can apply a burst of deletes after text posted right behind it). No wait for the hotkey's
    /// modifiers: a merged ⌥ would turn ⌫ into delete-word (espanso #470), but our ⌫ carries
    /// explicit empty flags and the held ⌥ is not merged in (receiver proof; iTerm works).
    private func deliverIntoTerminal(text: String, previous: String, pid: pid_t) async -> Bool {
        guard !previous.contains(where: \.isNewline) else {
            return false
        }
        trace.delivery = "terminal"
        for _ in 0..<previous.count {
            AccessibilityBridge.deleteBackward()
            try? await Task.sleep(for: .milliseconds(2))
        }
        try? await Task.sleep(for: .milliseconds(30))
        await AccessibilityBridge.injectUnicode(text)
        return true
    }

    /// Fake-AX native hosts (Telegram, WhatsApp, KeePassium), user selection: one ⌫, read what it
    /// did from `AXValue` (`LayoutConvertDelivery`), finish or roll back, then type the output
    /// (paste for line breaks — Enter sends in chat apps), re-select it and prove it with ⌘C.
    private func deliverOverSelectionByDelete(
        text: String,
        previous: String,
        pid: pid_t,
        monitor: ClipboardMonitor
    ) async -> Bool {
        // No → first: Telegram moved the caret one past the selection end when text followed
        // («ghbdtn» at line start shifted, «vbh» at the end did not). Its key
        // handling ignores the selection (typing inserted next to it); standard hosts delete the
        // whole selection on ⌫. One ⌫, then measure the field (AXValue is real there).
        // Every ⌫ here is checked against the field's AXValue and rolled back when the effect is
        // not understood: a surprise must cost a failed convert, never lost text (KeePassium:
        // one ⌫ removed 8 for a 7-char selection — smart delete took the space — and
        // the old stop left the text eaten).
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           keySemanticsByBundle[bundle] == LayoutConvertDelivery.BackspaceSemantics.standard.rawValue {
            // Learned: typing replaces the selection here — no ⌫ (avoids Cocoa smart delete).
            return await deliverViaKeystrokes(text: text, pid: pid, monitor: monitor, keepSelection: true)
        }
        guard let element = AccessibilityBridge.focusedElement(of: pid),
              let valueBefore = AccessibilityBridge.value(on: element) else {
            // No readable field: never press ⌫ blind — type over the selection instead.
            return await deliverViaKeystrokes(text: text, pid: pid, monitor: monitor, keepSelection: true)
        }
        let before = (valueBefore as NSString).length
        let selectionLength = (previous as NSString).length
        AccessibilityBridge.deleteBackward()
        var removed: Int?
        let deadline = ContinuousClock.now + .milliseconds(200)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if let now = AccessibilityBridge.valueLength(on: element), now != before {
                removed = before - now
                break
            }
        }
        let semantics = LayoutConvertDelivery.backspaceSemantics(removed: removed, selectionLength: selectionLength)
        if semantics == .caretAtEnd {
            // Keys ignore the selection (Telegram): delete the rest before the insertion point.
            for _ in 1..<previous.count {
                AccessibilityBridge.deleteBackward()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        try? await Task.sleep(for: .milliseconds(30))

        // What exactly left the field (contiguous block), from the AXValue diff.
        let valueAfter = AccessibilityBridge.value(on: element) ?? valueBefore
        let reading = LayoutConvertDelivery.readDeletion(
            before: valueBefore, after: valueAfter, selectionLength: selectionLength, semantics: semantics
        )
        trace.delivery = "backspace:\(semantics.rawValue)"
        guard reading.understood else {
            trace.notes.append("rolled-back")
            // Roll back: type back what was removed (the AX block when known, else the selection —
            // when nothing was removed there is nothing to restore).
            if (valueAfter as NSString).length < before {
                await AccessibilityBridge.injectUnicode(reading.removed ?? previous)
            }
            return false
        }
        rememberKeySemantics(semantics == .caretAtEnd ? .caretAtEnd : .standard, pid: pid)
        let block = reading.removed
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotItems(pasteboard)
        let keptRecordID = monitor.clipboardRecordID
        let keptStackID = monitor.clipboardStackID
        monitor.beginSuppressExternalCapture()
        defer { monitor.endSuppressExternalCapture() }
        let typed = reading.leadingExtra + text + reading.trailingExtra
        let usePaste = LayoutConvertDelivery.needsPaste(typed)
        if usePaste {
            if case .failed = await monitor.writeTransientPlainText(typed) {
                _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
                await AccessibilityBridge.injectUnicode(block ?? previous)
                return false
            }
            AccessibilityBridge.pasteForLayoutConvert()
        } else {
            await AccessibilityBridge.injectUnicode(typed)
        }
        if !reading.trailingExtra.isEmpty { AccessibilityBridge.moveLeft(characters: reading.trailingExtra.count) }
        AccessibilityBridge.selectLeft(characters: text.count)
        let proof = await provenCopy(pasteboard, monitor: monitor, expect: text).probe
        if proof.text != text { trace.notes.append("proof-mismatch") }
        if usePaste, !proof.changed { try? await Task.sleep(for: .milliseconds(300)) }
        _ = await monitor.restorePasteboardItems(saved, recordID: keptRecordID, stackID: keptStackID)
        return true
    }

    private static func isTerminalBundle(_ id: String) -> Bool {
        [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
            "org.alacritty", "io.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper", "com.github.wez.wezterm",
        ].contains(id)
    }

    /// Native caret span. (1) Verified AX replace (TextEdit, Notes). (2) The host refuses AX
    /// writes (WhatsApp, Catalyst): its AX selection range also read back fine while the real
    /// selection never moved, so typing over it *added* the text. Put the caret
    /// back via AX, step over the tail, ⌫ × span (2 ms apart), type, step back; verify via AX read.
    private func replaceCaretSpanNative(
        text: String,
        previous: String,
        pid: pid_t,
        element: AXUIElement,
        range: CFRange,
        tail: String
    ) async -> ReplaceResult {
        if let replaced = AccessibilityBridge.setSelectedText(
            pid: pid, text: text, previous: previous, select: range, preferred: element
        ) {
            trace.delivery = "ax"
            return ReplaceResult(ok: true, element: replaced)
        }
        if !isAXSelectionFake(pid) { trace.notes.append("learned:fake-ax") }
        markAXSelectionFake(pid)
        trace.delivery = "backspace"
        let tailLength = (tail as NSString).length
        let caret = range.location + range.length + tailLength
        _ = AccessibilityBridge.setSelectedTextRange(on: element, range: CFRange(location: caret, length: 0))
        if !tail.isEmpty { AccessibilityBridge.moveLeft(characters: tail.count) }
        for _ in 0..<previous.count {
            AccessibilityBridge.deleteBackward()
            try? await Task.sleep(for: .milliseconds(2))
        }
        try? await Task.sleep(for: .milliseconds(30))
        await AccessibilityBridge.injectUnicode(text)
        if !tail.isEmpty { AccessibilityBridge.moveRight(characters: tail.count) }
        try? await Task.sleep(for: .milliseconds(40))
        let outLength = (text as NSString).length
        let landed = AccessibilityBridge.text(on: element, range: CFRange(location: range.location, length: outLength))
        if landed != text { trace.notes.append("readback-differs") }
        return ReplaceResult(ok: true, element: element)
    }

    private struct ReplaceResult {
        var ok: Bool
        var element: AXUIElement?
        /// Nothing was typed; run the cycle again (the host turned out to fake its AX selection).
        var retry = false
    }

    /// Deliver remapped text into the live selection. Mute → keystrokes only (AX set lies in
    /// Electron). Non-mute → verified AX set, else keystrokes. Keystrokes = Unicode inject, or
    /// Transient ⌘V under History suppress when Monaco would auto-surround the output.
    private func replaceSelection(
        text: String,
        previous: String,
        pid: pid_t?,
        range: CFRange?,
        preferred: AXUIElement?,
        keystrokesOnly: Bool = false,
        keepSelection: Bool = true
    ) async -> ReplaceResult {
        if text == previous {
            let resolved = preferred
                ?? (pid.flatMap { AccessibilityBridge.focusedElement(of: $0) })
            if let resolved, let range {
                let keep = CFRange(location: range.location, length: (text as NSString).length)
                _ = AccessibilityBridge.setSelectedTextRange(on: resolved, range: keep)
            } else if let pid, let range {
                let keep = CFRange(location: range.location, length: (text as NSString).length)
                _ = AccessibilityBridge.setSelectedTextRange(pid: pid, range: keep)
            }
            return ReplaceResult(ok: true, element: resolved)
        }

        // AX setSelectedText often returns success on Cursor without changing the document —
        // then we skipped inject and the user saw "nothing happened". Mute never takes that path.
        // Caret mode selected the span with keys — deliver with keys so the caret state is known.
        // `select: nil` — the user's selection is live (just read). Re-selecting the known range
        // first (old guard against the HUD collapsing it — TIS now runs after the replace) broke
        // the real selection in hosts with a fake AX selection model: Telegram typed the
        // result next to the old text (proof only saw the last 6 chars = output).
        // AX write only when the selection itself came from AX (`range` known): if ⌘C had to read
        // it, AX does not know the selection and its “success” means nothing (Mail).
        if !keystrokesOnly,
           !isAXTreeMute(pid),
           let pid,
           let range,
           let element = AccessibilityBridge.setSelectedText(
               pid: pid, text: text, previous: previous, select: nil, preferred: preferred
           ) {
            // Verify: the result must now sit where the selection was.
            let landed = AccessibilityBridge.text(
                on: element, range: CFRange(location: range.location, length: (text as NSString).length)
            )
            if landed == nil || landed == text {
                trace.delivery = "ax"
                return ReplaceResult(ok: true, element: element)
            }
            trace.notes.append("ax-write-lied")
        }
        // Native host refused the AX write for the first time: its AX selection may be fake (it
        // was read from AX). Type nothing; re-run the cycle reading the real selection via ⌘C.
        if !keystrokesOnly, let pid, !isAXTreeMute(pid), !isAXSelectionFake(pid) {
            markAXSelectionFake(pid)
            trace.notes.append("learned:fake-ax→retry")
            return ReplaceResult(ok: false, element: preferred, retry: true)
        }

        guard let monitor = model?.monitor else { return ReplaceResult(ok: false, element: preferred) }
        if !keystrokesOnly, keepSelection, let pid, isAXSelectionFake(pid) {
            // Telegram: typing over a real selection (read via ⌘C) inserted next to it —
            // proof saw only the 3 typed chars. Delete the selection with keys instead.
            guard await deliverOverSelectionByDelete(text: text, previous: previous, pid: pid, monitor: monitor) else {
                return ReplaceResult(ok: false, element: preferred)
            }
            return ReplaceResult(ok: true, element: preferred)
        }
        guard await deliverViaKeystrokes(text: text, pid: pid, monitor: monitor, keepSelection: keepSelection) else {
            return ReplaceResult(ok: false, element: preferred)
        }
        let element = (pid.flatMap { AccessibilityBridge.focusedElement(of: $0) }) ?? preferred
        return ReplaceResult(ok: true, element: element)
    }

    private func selectionRangeAfterReplace(
        element: AXUIElement?,
        pid: pid_t?,
        previousRange: CFRange?,
        replacementLength: Int
    ) -> CFRange? {
        guard replacementLength > 0 else { return previousRange }
        if let previousRange {
            return CFRange(location: previousRange.location, length: replacementLength)
        }
        let caret = element.flatMap { AccessibilityBridge.selectedTextRange(on: $0) }
            ?? pid.flatMap { AccessibilityBridge.selectedTextRange(pid: $0) }
        guard let caret else { return nil }
        if caret.length == replacementLength { return caret }
        let start = max(0, caret.location + caret.length - replacementLength)
        return CFRange(location: start, length: replacementLength)
    }

    private func scheduleEditorSelectionRestore(state: ItemState, range: NSRange) {
        guard range.length > 0 else { return }
        selectionRestoreTask?.cancel()
        selectionRestoreTask = Task { @MainActor in
            for delay in [40, 120, 300] as [UInt64] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                guard let textView = state.textView else { return }
                let live = textView.selectedRange()
                if live == range { continue }
                // User moved the caret out of the converted span — stop.
                if live.length == 0 {
                    let loc = live.location
                    if loc < range.location || loc > range.location + range.length { return }
                } else if live != range {
                    return
                }
                textView.setSelectedRange(range)
            }
        }
    }

    private static func charsets(
        for layoutIDs: [String],
        in all: [String: Set<Character>]
    ) -> [String: Set<Character>] {
        var filtered: [String: Set<Character>] = [:]
        for id in layoutIDs {
            if let set = all[id] { filtered[id] = set }
        }
        return filtered
    }

    nonisolated(unsafe) private static var electronByBundlePath: [String: Bool] = [:]

    /// Electron is detected from the app itself (`Contents/Frameworks/Electron Framework.framework`)
    /// — the bundle-ID list below only knew Cursor/VS Code; 14 Electron apps are installed here.
    private static func bundlesElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = electronByBundlePath[url.path] { return known }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let isElectron = FileManager.default.fileExists(atPath: framework.path)
        electronByBundlePath[url.path] = isElectron
        return isElectron
    }

    /// Cursor / VS Code / Electron: AXFocusedUIElement is NoValue — never walk the tree.
    private static func isKnownAXMuteBundle(_ id: String) -> Bool {
        id.hasPrefix("com.todesktop.")
            || id.hasPrefix("com.microsoft.VSCode")
            || id.hasPrefix("com.github.Electron")
            || id.hasPrefix("com.visualstudio.code")
    }

    private static func targetApplication(lastOther: NSRunningApplication?) -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier, !front.isTerminated {
            return front
        }
        if let lastOther, !lastOther.isTerminated,
           lastOther.bundleIdentifier != Bundle.main.bundleIdentifier {
            return lastOther
        }
        return nil
    }

    private static func snapshotItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
