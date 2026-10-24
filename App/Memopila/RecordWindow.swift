import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The record window (PLAN §8.5): a normal window that replaces the panel, as Settings does, and can
/// be moved and resized; it remembers its frame. Like the panel, it sees keys before its views.
final class RecordWindow: NSWindow {
    /// `true` = handled.
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc is handled in `keyHandler`; this is the menu or another responder asking.
    }
}

/// What the window shows: the open record, replaced in place when ↑ ↓ ← → move to another one.
struct RecordWindowContent: View {
    let model: AppModel

    var body: some View {
        Group {
            if let state = model.itemState {
                RecordView(model: model, state: state).id(state.id)
            } else {
                Color.clear
            }
        }
        // *Copy Selected Text* and saving errors report here while the panel is hidden.
        .overlay(alignment: .bottom) { ToastView(center: model.toasts) }
        .animation(.easeOut(duration: 0.15), value: model.toasts.current?.id)
    }
}

/// Keys of the record window (§8.5). While a text view or the title has the focus, keys edit it;
/// otherwise ↑ ↓ ← → move to other records, Space closes and ↩ puts the record on the clipboard.
@MainActor
enum RecordKeys {
    static func handle(_ event: NSEvent, in window: NSWindow, model: AppModel) -> Bool {
        guard let state = model.itemState else { return false }
        // An input method is composing (Japanese, Chinese, Korean…): its keys belong to it.
        if let textView = window.firstResponder as? NSTextView, textView.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = KeyPress(event)
        let responder = window.firstResponder
        if key.code == kVK_Escape {
            // Esc inside the find bar closes the find bar, not the window.
            if let responder = responder as? NSView, let textView = state.textView, responder !== textView,
               let scrollView = textView.enclosingScrollView, responder.isDescendant(of: scrollView) {
                return false
            }
            model.dismissRecord()
            return true
        }
        if flags == .command {
            if key.isReturn {
                model.copyItem()
                return true
            }
            switch key.letter {
            case "s": model.saveItem()
            case "f" where state.hasText: state.showFind()
            case "y": model.dismissRecord()
            case "e" where state.isEditable: state.focus()
            default: return false
            }
            return true
        }
        guard !(responder is NSTextView), flags.isEmpty else { return false }
        let history = model.history
        switch key.code {
        case kVK_Space: model.dismissRecord()
        case _ where key.isReturn: model.copyItem()
        case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
            // Unsaved changes stay on screen until they are saved or discarded.
            guard !state.isDirty else { return true }
            switch key.code {
            case kVK_UpArrow: history.moveSelectionVertically(-1)
            case kVK_DownArrow: history.moveSelectionVertically(1)
            case kVK_LeftArrow: history.moveSelection(by: -1)
            default: history.moveSelection(by: 1)
            }
            if let id = history.selectedID { model.openRecord(id) }
        default: return false
        }
        return true
    }
}
