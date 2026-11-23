import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MemopilaCore

/// In-place anchored layout cycle (⌥⌘B): editor or global selection.
@MainActor
final class LayoutConvertController {
    private weak var model: AppModel?
    private var session: LayoutConverter.CycleSession?
    private var sessionPID: pid_t?
    private var sessionRange: CFRange?
    private var sessionExpires: ContinuousClock.Instant?
    private var inFlight = false

    private static let sessionTTL: Duration = .seconds(10)

    init(model: AppModel) {
        self.model = model
    }

    func cycle() {
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            await runCycle()
        }
    }

    // MARK: - Cycle

    private func runCycle() async {
        guard let model else { return }

        if model.windows.recordIsKey, let state = model.itemState, state.isEditable, state.isLoaded {
            cycleInEditor(state, model: model)
            return
        }

        if IsSecureEventInputEnabled() {
            present(String(localized: "Can’t convert layout in a secure field."), error: true, model: model)
            return
        }

        guard AccessibilityBridge.isTrusted else {
            AccessibilityBridge.requestTrust()
            present(
                String(localized: "To convert layout in other apps, allow Memopila in System Settings → Privacy & Security → Accessibility."),
                error: true,
                model: model
            )
            return
        }

        let materials = InputSourceController.cycleMaterials()
        guard materials.ids.count >= 2 else {
            present(
                String(localized: "Add another keyboard layout in System Settings → Keyboard → Input Sources."),
                error: true,
                model: model
            )
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier
        guard let read = await readSelection(pid: pid, monitor: model.monitor),
              !LayoutConverter.letters(in: read.text).isEmpty else {
            present(selectHint(model), error: false, model: model)
            return
        }

        let prior = continuingSession(selection: read.text, pid: pid)
        let step = LayoutConverter.cycle(
            selection: read.text,
            layoutIDs: materials.ids,
            maps: materials.maps,
            charsets: materials.charsets,
            currentID: InputSourceController.currentLayoutID(),
            session: prior
        )

        switch step {
        case .failed(let failure):
            present(failureMessage(failure), error: true, model: model)
        case .output(let text, let targetID, let next, let isNewCycle):
            let ok = await replaceSelection(text: text, pid: pid, range: read.range, monitor: model.monitor)
            guard ok else {
                present(String(localized: "Could not replace the selection."), error: true, model: model)
                return
            }
            _ = InputSourceController.select(id: targetID)
            let length = (text as NSString).length
            let newRange: CFRange? = read.range.map { CFRange(location: $0.location, length: length) }
            remember(session: next, pid: pid, range: newRange)
            present(toastMessage(targetID: targetID, names: materials.names, isNewCycle: isNewCycle, hadPrior: prior != nil), error: false, model: model)
        }
    }

    private func cycleInEditor(_ state: ItemState, model: AppModel) {
        let materials = InputSourceController.cycleMaterials()
        guard materials.ids.count >= 2 else {
            model.toasts.error(String(localized: "Add another keyboard layout in System Settings → Keyboard → Input Sources."))
            return
        }
        guard let input = state.layoutConvertSelection(),
              !LayoutConverter.letters(in: input.text).isEmpty else {
            model.toasts.show(selectHint(model))
            return
        }

        let prior: LayoutConverter.CycleSession?
        if let session, ContinuousClock.now < (sessionExpires ?? .now),
           input.text == session.lastOutput || input.text == session.original {
            prior = session
        } else {
            prior = nil
        }

        let step = LayoutConverter.cycle(
            selection: input.text,
            layoutIDs: materials.ids,
            maps: materials.maps,
            charsets: materials.charsets,
            currentID: InputSourceController.currentLayoutID(),
            session: prior
        )

        switch step {
        case .failed(let failure):
            model.toasts.error(failureMessage(failure))
        case .output(let text, let targetID, let next, let isNewCycle):
            state.replaceLayoutConvert(range: input.range, with: text)
            _ = InputSourceController.select(id: targetID)
            session = next
            sessionPID = nil
            sessionRange = nil
            sessionExpires = .now + Self.sessionTTL
            model.toasts.show(toastMessage(targetID: targetID, names: materials.names, isNewCycle: isNewCycle, hadPrior: prior != nil))
        }
    }

    // MARK: - Session

    private func continuingSession(selection: String, pid: pid_t?) -> LayoutConverter.CycleSession? {
        guard let session, let expires = sessionExpires, ContinuousClock.now < expires else {
            clearSession()
            return nil
        }
        if selection == session.lastOutput || selection == session.original {
            return session
        }
        if let pid, pid == sessionPID, let sessionRange,
           let live = AccessibilityBridge.selectedText(pid: pid),
           live.range.location == sessionRange.location,
           live.text == session.lastOutput || live.text == session.original {
            return session
        }
        return nil
    }

    private func remember(session: LayoutConverter.CycleSession, pid: pid_t?, range: CFRange?) {
        self.session = session
        sessionPID = pid
        sessionRange = range
        sessionExpires = .now + Self.sessionTTL
    }

    private func clearSession() {
        session = nil
        sessionPID = nil
        sessionRange = nil
        sessionExpires = nil
    }

    private func selectHint(_ model: AppModel) -> String {
        let keys = model.settings.layoutConvertShortcut.displayString
        return String(localized: "Select text, then press \(keys).")
    }

    private func toastMessage(targetID: String, names: [String: String], isNewCycle: Bool, hadPrior: Bool) -> String {
        let name = names[targetID] ?? targetID
        let arrow = String(localized: "→ \(name)")
        if isNewCycle, hadPrior {
            return String(localized: "New cycle · \(arrow)")
        }
        return arrow
    }

    private func failureMessage(_ failure: LayoutConverter.CycleFailure) -> String {
        switch failure {
        case .needMoreLayouts:
            String(localized: "Add another keyboard layout in System Settings → Keyboard → Input Sources.")
        case .uncertainSource:
            String(localized: "Select more text so the typed layout can be detected.")
        case .emptyText:
            String(localized: "Select text with letters to convert.")
        }
    }

    private func present(_ message: String, error: Bool, model: AppModel) {
        if error {
            model.toasts.error(message)
        } else {
            model.toasts.show(message)
        }
        FloatingToastHost.shared.present(message, isError: error)
    }

    // MARK: - Selection I/O

    private struct SelectionRead {
        var text: String
        var range: CFRange?
    }

    private func readSelection(pid: pid_t?, monitor: ClipboardMonitor) async -> SelectionRead? {
        if let pid, let ax = AccessibilityBridge.selectedText(pid: pid), !ax.text.isEmpty {
            return SelectionRead(text: ax.text, range: ax.range)
        }
        return await copySelectionViaClipboard(monitor: monitor)
    }

    private func copySelectionViaClipboard(monitor: ClipboardMonitor) async -> SelectionRead? {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotItems(pasteboard)
        let before = pasteboard.changeCount

        monitor.armIgnoreNextContentChange()
        AccessibilityBridge.copy()

        let deadline = ContinuousClock.now + .milliseconds(400)
        while ContinuousClock.now < deadline, pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let text = pasteboard.string(forType: .string)
        _ = await monitor.restorePasteboardItems(saved)

        if pasteboard.changeCount == before || text?.isEmpty != false {
            monitor.cancelIgnoreNextContentChange()
            return nil
        }
        return text.map { SelectionRead(text: $0, range: nil) }
    }

    private func replaceSelection(
        text: String,
        pid: pid_t?,
        range: CFRange?,
        monitor: ClipboardMonitor
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshotItems(pasteboard)
        let items = [CanonicalItem([.bytes(.utf8PlainText, Data(text.utf8))])]
        let outcome = await monitor.writeAsync(items, sourceBundleID: Bundle.main.bundleIdentifier, recordID: nil)
        guard outcome == .written else { return false }

        if let pid, let range {
            _ = AccessibilityBridge.setSelectedTextRange(pid: pid, range: range)
        }
        AccessibilityBridge.paste()
        try? await Task.sleep(for: .milliseconds(120))

        if let pid, let range {
            let length = (text as NSString).length
            _ = AccessibilityBridge.setSelectedTextRange(
                pid: pid,
                range: CFRange(location: range.location, length: length)
            )
        }

        _ = await monitor.restorePasteboardItems(saved)
        return true
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
