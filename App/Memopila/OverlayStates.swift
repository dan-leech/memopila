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

/// The item view (PLAN §8.5, §3.6): one overlay to look at an item and to edit its text and title.
/// The text lives in the `NSTextView`, which keeps its own undo stack; text actions replace the
/// selection (or the whole text) as one undoable change. Code is highlighted while you type.
@MainActor
@Observable
final class ItemState {
    let id: UUID
    let card: HistoryCard
    /// Text, rich text and links; other text-like items (mixed) are shown read-only.
    let isEditable: Bool
    /// RTF / HTML / web archive records lose their formatting on save.
    let hasFormatting: Bool
    let originalTitle: String
    var title: String {
        didSet { updateDirty() }
    }
    private(set) var isLoaded = false
    private(set) var initialText = ""
    private(set) var isTextDirty = false
    private(set) var lineCount = 1
    private(set) var characterCount = 0
    var isSaving = false
    var error: String?
    /// Esc with unsaved changes asks first.
    var isConfirmingDiscard = false
    var wrapsLines = true {
        didSet { applyWrapping() }
    }
    var language: LanguageChoice {
        didSet { scheduleHighlight(after: .zero) }
    }
    private(set) var detectedLanguage: CodeLanguage?
    /// The text view takes the focus once loaded (⌘E, Edit) instead of leaving the arrows to the grid.
    @ObservationIgnored var focusOnLoad: Bool
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    /// Highlighting stops above this many UTF-16 units: colouring that much text costs more than it helps.
    private static let highlightLimit = 200_000

    init(card: HistoryCard, focusOnLoad: Bool) {
        id = card.id
        self.card = card
        isEditable = AppModel.isEditable(card)
        hasFormatting = card.displayType == .richText
        originalTitle = card.customTitle ?? ""
        title = card.customTitle ?? ""
        language = LanguageChoice(stored: card.codeLanguage)
        self.focusOnLoad = focusOnLoad
    }

    /// Shown as text: the text view instead of an image, file or colour view.
    var hasText: Bool { [.text, .richText, .url, .mixed].contains(card.displayType) }
    var titleChanged: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines) != originalTitle }
    var isDirty: Bool { isTextDirty || titleChanged }

    func load(_ text: String) {
        initialText = text
        isLoaded = true
        if let textView, textView.string.isEmpty { textView.string = text }
        textDidChange()
        if focusOnLoad { focus() }
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        textView.isEditable = isEditable
        if isLoaded, textView.string.isEmpty { textView.string = initialText }
        applyWrapping()
        textDidChange()
        if isLoaded, focusOnLoad { focus() }
    }

    func focus() {
        guard let textView else { return }
        focusOnLoad = false
        Task { @MainActor in textView.window?.makeFirstResponder(textView) }
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
        scheduleHighlight(after: .milliseconds(isLoaded && isTextDirty ? 300 : 0))
    }

    private func updateDirty() {
        let textChanged = isLoaded && (textView?.string ?? initialText) != initialText
        if textChanged != isTextDirty { isTextDirty = textChanged }
        if !isDirty { isConfirmingDiscard = false }
    }

    /// Back to the stored text and title.
    func revert() {
        title = originalTitle
        guard let textView else { return }
        textView.string = initialText
        textView.undoManager?.removeAllActions()
        textDidChange()
    }

    /// Runs a text action on the selection, or on everything when nothing is selected (§3.9).
    func apply(_ action: TextAction) {
        guard let textView, isEditable else { return }
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

    // MARK: Highlighting (§8.5)

    private func scheduleHighlight(after delay: Duration) {
        highlightTask?.cancel()
        guard hasText, card.displayType != .url else { return }
        highlightTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.highlight()
        }
    }

    /// Tokenizes off the main actor and colours the text in place; edits made meanwhile win.
    private func highlight() async {
        guard let textView, let storage = textView.textStorage else { return }
        let text = textView.string
        let length = (text as NSString).length
        guard length <= Self.highlightLimit else { return }
        let sourceBundleID = card.sourceAppBundleID
        let detected = await Task.detached(priority: .userInitiated) {
            CodeHighlighter.detect(text, sourceBundleID: sourceBundleID)
        }.value
        detectedLanguage = detected
        let chosen: CodeLanguage? = switch language {
        case .auto: detected
        case .plain: nil
        case .language(let language): language
        }
        let ranges = await CodeStyler.ranges(text, language: chosen)
        guard !Task.isCancelled, textView.string == text else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: length))
        for range in ranges where range.location + range.length <= length {
            storage.addAttribute(.foregroundColor, value: CodeStyler.color(for: range.kind), range: NSRange(location: range.location, length: range.length))
        }
        storage.endEditing()
        // Typing after a keyword must not continue in its colour until the next pass.
        textView.typingAttributes[.foregroundColor] = NSColor.labelColor
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

/// Read-only text whose selection matters: *Copy Selected Text* in the item view.
@MainActor
@Observable
final class TextSelection {
    @ObservationIgnored private weak var textView: NSTextView?
    private(set) var hasSelection = false

    func attach(_ textView: NSTextView, text: String) {
        self.textView = textView
        textView.string = text
        update()
    }

    func update() {
        let selected = (textView?.selectedRange().length ?? 0) > 0
        if selected != hasSelection { hasSelection = selected }
    }

    /// The selected text, or all of it when nothing is selected.
    var selectedOrAll: String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        return range.length > 0 ? (textView.string as NSString).substring(with: range) : textView.string
    }
}
