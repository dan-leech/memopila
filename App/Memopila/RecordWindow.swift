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

/// Keys of the record window (§8.5). While a text view or the title has the focus, keys edit it and
/// Esc stops editing; otherwise ↑ ↓ ← → move to other records, Space or Esc closes and ↩ selects.
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
            // Also the find bar of the text recognized in an image.
            if let view = responder as? NSView,
               let findBar = sequence(first: view, next: \.superview).compactMap({ ($0 as? NSScrollView)?.findBarView }).first,
               view.isDescendant(of: findBar) {
                return false
            }
            // The title or the new-collection field: Esc only leaves it (the title saves itself).
            if let field = responder as? NSTextView, field.isFieldEditor {
                window.makeFirstResponder(nil)
                return true
            }
            if state.isDirty || !(responder is NSTextView) {
                model.dismissRecord()
            } else {
                // Editing without changes: the first Esc only leaves the text.
                window.makeFirstResponder(nil)
            }
            return true
        }
        if flags == [.option, .command], key.letter == "f", state.hasText {
            state.showFind(replace: true)
            return true
        }
        if flags == [.option, .command], key.letter == "i" {
            // The view decides: a narrow window shows it only on request.
            state.inspectorToggleRequests += 1
            return true
        }
        // ⌘+ / ⌘− / ⌘0: the image's zoom, or the text's size.
        if flags == .command || flags == [.command, .shift], ["=", "+", "-", "0"].contains(key.letter) {
            let isImage = [.image, .pdf].contains(state.card.displayType)
            switch (key.letter, isImage) {
            case ("0", true): state.imageZoom.fit()
            case ("0", false): state.fontSize = ItemState.defaultFontSize
            case ("-", true): state.imageZoom.zoom(by: 1 / 1.25)
            case ("-", false): state.changeFontSize(by: -1)
            case (_, true): state.imageZoom.zoom(by: 1.25)
            case (_, false): state.changeFontSize(by: 1)
            }
            return true
        }
        if flags == .option, key.isReturn, !(responder is NSTextView) {
            model.copyItem(paste: true)
            return true
        }
        if flags == .command {
            if key.isReturn {
                model.copyItem()
                return true
            }
            let isImage = [.image, .pdf].contains(state.card.displayType)
            switch key.letter {
            case "s": model.saveItem()
            case "f" where state.hasText: state.showFind()
            case "f" where isImage: state.findInRecognizedText()
            // Formatted text, while it is being edited.
            case "b" where state.isRich && responder === state.textView: state.toggleTrait(.boldFontMask)
            case "i" where state.isRich && responder === state.textView: state.toggleTrait(.italicFontMask)
            case "u" where state.isRich && responder === state.textView: state.toggleUnderline()
            case "o" where state.card.displayType == .url:
                guard let url = URL(string: state.linkText), url.scheme != nil else { return true }
                External.open(url)
            case "y": model.dismissRecord()
            case "e" where state.isEditable: state.focus()
            default: return false
            }
            return true
        }
        guard !(responder is NSTextView), flags.isEmpty else { return false }
        // With unsaved text, Space and the arrows first ask whether to save.
        switch key.code {
        case kVK_Space: model.dismissRecord()
        case _ where key.isReturn: model.copyItem()
        case kVK_UpArrow: model.openAdjacentRecord(-1, vertically: true)
        case kVK_DownArrow: model.openAdjacentRecord(1, vertically: true)
        case kVK_LeftArrow: model.openAdjacentRecord(-1)
        case kVK_RightArrow: model.openAdjacentRecord(1)
        default: return false
        }
        return true
    }
}
