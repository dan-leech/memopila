import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Non-activating panel: the previous app stays frontmost while the panel takes keyboard input (PLAN §8.1).
final class HistoryPanel: NSPanel {
    /// Sees every key press before the responder chain; `true` = handled (§8.3).
    var keyHandler: ((NSEvent) -> Bool)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelController.defaultSize.width, height: PanelController.defaultSize.height),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Memopila is usually not the active app while the panel is open: without this AppKit
        // shows no tooltips in it.
        allowsToolTipsWhenApplicationIsInactive = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        minSize = PanelController.minimumSize
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        if event.type == .flagsChanged { onModifiersChanged?(event.modifierFlags) }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 720, height: 490)
    static let minimumSize = NSSize(width: 520, height: 360)

    private unowned let model: AppModel
    private var panel: HistoryPanel?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isKey: Bool { panel?.isKeyWindow ?? false }

    /// Hotkey: closes a focused panel; brings a pinned panel that lost focus back to the front.
    func toggle() {
        if isVisible, isKey {
            close()
        } else if isVisible, let panel {
            panel.makeKeyAndOrderFront(nil)
            model.focusSearch()
        } else {
            show()
        }
    }

    /// `keepingState`: back from a record or Settings, with the same search and selection.
    func show(keepingState: Bool = false) {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.panelWillShow(keepingState: keepingState)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Memopila is the active app after a launch by hand or after Settings: closing the panel then
    /// hands the keyboard back to the app behind it instead of leaving it with no window.
    func close(returningFocus: Bool = true) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.panelDidClose()
        if returningFocus, NSApp.isActive, !model.windows.isAnyVisible {
            _ = model.previousApp?.activate()
        }
    }

    /// Esc: close an overlay, clear a non-empty search, otherwise close (§3.4).
    func cancel() {
        if model.overlay != nil {
            model.present(nil)
        } else if !model.history.search.isEmpty {
            model.history.search = ""
        } else {
            close()
        }
    }

    // MARK: NSWindowDelegate

    /// A pinned panel can be focused again from any app: that app is the new paste target (§3.4).
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPreviousApp()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Pin keeps the window on screen when focus moves to another app (§8.1).
        if !model.isPinned { close() }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func makePanel() -> HistoryPanel {
        let panel = HistoryPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.keyHandler = { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        }
        panel.onModifiersChanged = { [weak self] flags in
            let commandOnly = flags.intersection([.command, .option, .control, .shift]) == .command
            let option = flags.contains(.option)
            MainActor.assumeIsolated {
                if self?.model.isCommandHeld != commandOnly { self?.model.isCommandHeld = commandOnly }
                if self?.model.isOptionHeld != option { self?.model.isOptionHeld = option }
            }
        }
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))
        return panel
    }

    // MARK: Frame per display (§8.1)

    /// Saved frame for the screen with the mouse pointer, else centered at the default size.
    private func position(_ panel: HistoryPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if let saved = model.settings.panelFrames[Self.displayKey(screen)].map(NSRectFromString),
           visible.contains(saved), saved.width >= Self.minimumSize.width, saved.height >= Self.minimumSize.height {
            panel.setFrame(saved, display: false)
            return
        }
        var frame = NSRect(origin: .zero, size: Self.defaultSize)
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        panel.setFrame(frame, display: false)
    }

    private func saveFrame() {
        guard let panel, panel.isVisible, let screen = panel.screen else { return }
        model.settings.panelFrames[Self.displayKey(screen)] = NSStringFromRect(panel.frame)
    }

    /// Stable across launches for the same display arrangement.
    static func displayKey(_ screen: NSScreen) -> String {
        let size = screen.frame.size
        return "\(screen.localizedName) \(Int(size.width))x\(Int(size.height))"
    }

    // MARK: Keyboard (§8.3)

    private func handleKey(_ event: NSEvent) -> Bool {
        // An input method is composing (Japanese, Chinese, Korean…): ↩, arrows and Esc belong to it.
        if let textView = panel?.firstResponder as? NSTextView, textView.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = KeyPress(event)

        if flags.contains(.command), let handled = forwardEditCommand(key, flags: flags) { return handled }

        switch model.overlay {
        case nil:
            return handleGridKey(key, flags: flags)
        case .actions:
            guard let state = model.actionsState else { return false }
            switch key.code {
            case kVK_Escape: model.present(nil)
            case kVK_UpArrow: state.move(by: -1)
            case kVK_DownArrow: state.move(by: 1)
            case _ where key.isReturn: model.runHighlightedAction()
            default: return false
            }
            return true
        case .confirmDelete(let ids):
            if key.code == kVK_Escape { model.present(nil); return true }
            if key.isReturn { model.delete(ids, confirmed: true); return true }
            return false
        case .confirmDeleteCollection(let id):
            if key.code == kVK_Escape { model.present(nil); return true }
            if key.isReturn { model.deleteCollection(id); return true }
            return false
        case .confirmClear:
            if key.code == kVK_Escape { model.present(nil); return true }
            if key.isReturn {
                model.present(nil)
                model.clear(.nonFavorites)
                return true
            }
            return false
        case .rename, .newCollection, .renameCollection:
            if key.code == kVK_Escape { model.present(nil); return true }
            return false
        case .shortcuts:
            if key.code == kVK_Escape || (flags == .command && key.letter == "/") {
                model.present(nil)
                return true
            }
            return false
        }
    }

    private func handleGridKey(_ key: KeyPress, flags: NSEvent.ModifierFlags) -> Bool {
        let history = model.history
        let searchIsEmpty = history.search.isEmpty
        if flags == .shift {
            // ⇧-arrows grow the selection (bulk delete, favorites, collections).
            switch key.code {
            case kVK_UpArrow: history.extendSelection(by: -history.columns); return true
            case kVK_DownArrow: history.extendSelection(by: history.columns); return true
            case kVK_LeftArrow where searchIsEmpty: history.extendSelection(by: -1); return true
            case kVK_RightArrow where searchIsEmpty: history.extendSelection(by: 1); return true
            default: return false
            }
        }
        if flags.isEmpty {
            switch key.code {
            case kVK_UpArrow: history.moveSelectionVertically(-1); return true
            case kVK_DownArrow: history.moveSelectionVertically(1); return true
            case kVK_LeftArrow where searchIsEmpty: history.moveSelection(by: -1); return true
            case kVK_RightArrow where searchIsEmpty: history.moveSelection(by: 1); return true
            case kVK_Escape:
                // Several cards selected: the first Esc goes back to one.
                if history.selection.count > 1 { history.clearMarks() } else { cancel() }
                return true
            case kVK_Space where searchIsEmpty: openSelected(); return true
            case _ where key.isReturn:
                model.restoreSelected()
                return true
            default: return false
            }
        }
        // ⌥↩: select and paste this once, whatever *Also paste* says.
        if flags == .option, key.isReturn {
            model.restoreSelected(paste: true)
            return true
        }
        // ⌥⌘S as in Pasta; ⌃⌘S from the plan keeps working.
        if flags == [.option, .command] || flags == [.control, .command], key.code == kVK_ANSI_S {
            model.settings.showSidebar.toggle()
            return true
        }
        guard flags == .command else { return false }
        if let digit = key.digit, digit >= 1 {
            model.restoreVisible(digit - 1)
            return true
        }
        if key.code == kVK_Delete || key.code == kVK_ForwardDelete {
            model.deleteSelection()
            return true
        }
        switch key.letter {
        case "k": if let id = history.selectedID { model.present(.actions(id)) }
        case "y": openSelected()
        case "e": openSelected(focusText: true)
        case "r": if let id = history.selectedID { model.present(.rename(id)) }
        case "d": model.toggleFavorites(history.selection)
        case "/": model.present(model.overlay == .shortcuts ? nil : .shortcuts)
        case "f": model.focusSearch()
        case ",": model.openSettings()
        case "w": close()
        case "c": model.restoreSelected(paste: false)
        case "p": model.isPinned.toggle()
        case "=", "+": model.changeGridDensity(by: -1)
        case "-": model.changeGridDensity(by: 1)
        case ".": model.monitor.togglePause()
        default: return false
        }
        return true
    }

    /// Space, ⌘Y, ⌘E (with the cursor in the text) and the pencil: the record window (§8.5).
    private func openSelected(focusText: Bool = false) {
        if let id = model.history.selectedID { model.openRecord(id, focusText: focusText) }
    }

    /// Cut / copy / paste / select all / undo in text fields. A non-activating panel does not get
    /// them from the main menu, so they go to the first responder directly. ⌘C without a text
    /// selection copies the selected card instead.
    private func forwardEditCommand(_ key: KeyPress, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let textView = panel?.firstResponder as? NSTextView else { return nil }
        switch (key.letter, flags) {
        case ("z", .command):
            if let manager = textView.undoManager, manager.canUndo { manager.undo() }
            return true
        case ("z", [.command, .shift]):
            if let manager = textView.undoManager, manager.canRedo { manager.redo() }
            return true
        default:
            break
        }
        let selector: Selector
        switch (key.letter, flags) {
        case ("x", .command):
            selector = #selector(NSText.cut(_:))
        case ("c", .command):
            // Without a text selection ⌘C copies the selected card.
            guard textView.selectedRange().length > 0 else { return nil }
            selector = #selector(NSText.copy(_:))
        case ("v", .command): selector = #selector(NSText.paste(_:))
        case ("a", .command): selector = #selector(NSText.selectAll(_:))
        default: return nil
        }
        return NSApp.sendAction(selector, to: textView, from: nil)
    }
}

/// Layout-independent key identity: ASCII characters when the layout gives them, else the
/// physical ANSI key (so ⌘K works with a Russian layout too).
struct KeyPress {
    let code: Int
    let letter: Character?

    init(_ event: NSEvent) {
        code = Int(event.keyCode)
        if let character = event.charactersIgnoringModifiers?.lowercased().first, character.isASCII, !character.isWhitespace {
            letter = character
        } else {
            letter = Self.ansiLetters[code]
        }
    }

    var isReturn: Bool { code == kVK_Return || code == kVK_ANSI_KeypadEnter }

    /// From the physical key, so ⌘1…⌘9 also work on layouts where the digit row types symbols (AZERTY).
    var digit: Int? {
        Self.digitKeys[code]
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_0: 0, kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4,
        kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad0: 0, kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4,
        kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9,
    ]

    private static let ansiLetters: [Int: Character] = [
        kVK_ANSI_A: "a", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_K: "k",
        kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z", kVK_ANSI_P: "p", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_Slash: "/", kVK_ANSI_I: "i", kVK_ANSI_0: "0",
    ]
}
