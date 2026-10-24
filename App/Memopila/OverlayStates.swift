import AppKit
import MemopilaCore
import MemopilaServices
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
    let originalTitle: String
    var title: String {
        didSet { updateDirty() }
    }
    private(set) var isLoaded = false
    private(set) var initialText = ""
    private(set) var isDirty = false
    private(set) var lineCount = 1
    private(set) var characterCount = 0
    var isSaving = false
    var error: String?
    /// Esc with unsaved changes asks first.
    var isConfirmingDiscard = false
    var wrapsLines = true {
        didSet { applyWrapping() }
    }
    @ObservationIgnored weak var textView: NSTextView?

    init(id: UUID, hasFormatting: Bool, title: String?) {
        self.id = id
        self.hasFormatting = hasFormatting
        originalTitle = title ?? ""
        self.title = title ?? ""
    }

    var titleChanged: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != originalTitle
    }

    func load(_ text: String) {
        initialText = text
        isLoaded = true
        if let textView, textView.string.isEmpty { textView.string = text }
        textDidChange()
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        if isLoaded, textView.string.isEmpty { textView.string = initialText }
        applyWrapping()
        textDidChange()
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func currentText() -> String? {
        guard isLoaded else { return nil }
        return textView?.string ?? initialText
    }

    /// From the text view's delegate after every edit.
    func textDidChange() {
        let text = textView?.string ?? initialText
        let length = (text as NSString).length
        characterCount = length < 200_000 ? text.count : length
        lineCount = TextStats.lineCount(text)
        updateDirty()
    }

    private func updateDirty() {
        let textChanged = isLoaded && (textView?.string ?? initialText) != initialText
        isDirty = textChanged || titleChanged
        if !isDirty { isConfirmingDiscard = false }
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

    func undo() {
        guard let manager = textView?.undoManager, manager.canUndo else { return }
        manager.undo()
    }

    func redo() {
        guard let manager = textView?.undoManager, manager.canRedo else { return }
        manager.redo()
    }

    /// The text view's find bar (⌘F).
    func showFind() {
        guard let textView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
    }

    private func applyWrapping() {
        guard let textView, let container = textView.textContainer, let scrollView = textView.enclosingScrollView else { return }
        if wrapsLines {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
    }
}
