import AppKit
import MemopilaCore
import Observation

/// The ⌘K panel: a searchable list of the selected card's actions (PLAN §8.4).
@MainActor
@Observable
final class ActionsPanelState {
    let items: [ActionItem]
    var query = "" {
        didSet { highlighted = 0 }
    }
    var highlighted = 0

    init(items: [ActionItem]) {
        self.items = items
    }

    var filtered: [ActionItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in words.allSatisfy { item.title.localizedStandardContains($0) } }
    }

    var highlightedAction: ActionItem? {
        let list = filtered
        return list.indices.contains(highlighted) ? list[highlighted] : nil
    }

    func move(by offset: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        highlighted = (highlighted + offset + count) % count
    }
}

/// The plain-text editor overlay (PLAN §3.6). The text lives in the `NSTextView`, which keeps its
/// own undo stack; text actions replace the selection (or the whole text) as one undoable change.
@MainActor
@Observable
final class EditorState {
    let id: UUID
    /// RTF / HTML / web archive records lose their formatting on save.
    let hasFormatting: Bool
    private(set) var isLoaded = false
    private(set) var initialText = ""
    var isSaving = false
    var error: String?
    @ObservationIgnored weak var textView: NSTextView?

    init(id: UUID, hasFormatting: Bool) {
        self.id = id
        self.hasFormatting = hasFormatting
    }

    func load(_ text: String) {
        initialText = text
        isLoaded = true
        if let textView, textView.string.isEmpty { textView.string = text }
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func currentText() -> String? {
        guard isLoaded else { return nil }
        return textView?.string ?? initialText
    }

    /// Runs a text action on the selection, or on everything when nothing is selected (§3.9).
    func apply(_ action: TextAction) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: text.length)
        guard let output = action.apply(to: text.substring(with: range)) else {
            error = action.unavailableReason
            return
        }
        error = nil
        guard textView.shouldChangeText(in: range, replacementString: output) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: output)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: (output as NSString).length))
    }
}
