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
    /// Text, rich text and links; other text-like items (mixed) and records with several items
    /// are shown read-only.
    private(set) var isEditable: Bool
    /// RTF / HTML / web archive records lose their formatting on save.
    let hasFormatting: Bool
    /// The title as stored; it is saved on its own when the field is left (§3.6).
    private(set) var originalTitle: String
    var title: String
    private(set) var isLoaded = false
    /// The Changes sheet; the window closes it before asking to save (⌘Q, logout).
    var showsChanges = false
    private(set) var initialText = "" {
        didSet { initialLength = (initialText as NSString).length }
    }
    /// UTF-16 length of `initialText`: *Edited* compares lengths before any text.
    @ObservationIgnored private var initialLength = 0
    /// The record's own undo history: the window and its undo manager are reused for every record
    /// (review finding: ⌘Z in one record undid a change of the previous one).
    let undoManager = UndoManager()
    /// Loading the text; cancelled when another record replaces this one.
    @ObservationIgnored var loadTask: Task<Void, Never>?
    /// Counts edits, so work done off the main thread is applied only to the text it was made for.
    @ObservationIgnored private var editVersion = 0
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    private(set) var isTextDirty = false
    private(set) var lineCount = 1
    private(set) var characterCount = 0
    /// The record size limit for saving (*Largest item*, §3.6) and the text's UTF-8 size once it
    /// gets close to it; `nil` while the text cannot be within 80 % of the limit.
    let maxBytes: Int
    private(set) var byteCount: Int?
    var isSaving = false
    var error: String?
    /// The selection, for the status bar: characters and lines (0 = nothing selected).
    private(set) var selectedCharacters = 0
    private(set) var selectedLines = 0
    /// Text actions that apply to the selection, or to all text when nothing is selected; the
    /// others are disabled in the menus with their reason (§3.9). Updated shortly after edits.
    private(set) var availableActions = Set(TextAction.allCases)
    /// The language the text is highlighted as; `nil` = plain text.
    private(set) var highlightedLanguage: CodeLanguage?
    /// `nil` = automatic: line numbers for code, not for prose.
    var lineNumbersPreference: Bool? = ItemState.storedLineNumbers {
        didSet {
            if let lineNumbersPreference {
                UserDefaults.standard.set(lineNumbersPreference, forKey: Self.lineNumbersKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lineNumbersKey)
            }
            applyRulers()
        }
    }
    var showsInvisibles = UserDefaults.standard.bool(forKey: ItemState.invisiblesKey) {
        didSet {
            UserDefaults.standard.set(showsInvisibles, forKey: Self.invisiblesKey)
            applyInvisibles()
        }
    }
    var wrapsLines = true {
        didSet { applyWrapping() }
    }
    var language: LanguageChoice {
        didSet { scheduleHighlight(after: .zero) }
    }
    private(set) var detectedLanguage: CodeLanguage?
    /// The text view has the keyboard focus: keys edit the text instead of moving between records.
    var isEditingText = false
    /// The text view takes the focus once loaded (⌘E, Edit) instead of leaving the arrows to the grid.
    @ObservationIgnored var focusOnLoad: Bool
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    /// Fit, Actual Size and zoom of an image or PDF record.
    let imageZoom = ImageZoom()
    /// The text recognized in an image, under it; ⌘F searches it.
    let recognizedText = TextSelection()
    /// ⌥⌘I asks the record view to show or hide the inspector.
    var inspectorToggleRequests = 0
    /// The link of a URL record as it is now, for the header above its text.
    private(set) var linkText = ""

    /// Formatted text (RTF, HTML) shown and edited with its formatting (§3.6); off = as plain
    /// text, and saving then keeps only the text.
    private(set) var isRich = false
    /// The record has formatted text that could be read.
    private(set) var hasRichSource = false
    @ObservationIgnored private var richSource: NSAttributedString?
    /// The formatted text as the text view holds it after loading or saving: *Edited* compares
    /// with it, so a change of formatting alone counts too.
    @ObservationIgnored private var initialRich: NSAttributedString?
    /// Formatted text is zoomed so most of it reads at about 14 pt (first-run feedback: web and
    /// app text often comes in at 9–11 pt and was too small to read).
    @ObservationIgnored private var richScale: CGFloat = 1

    /// Highlighting stops above this many UTF-16 units: colouring that much text costs more than it helps.
    private static let highlightLimit = 200_000

    init(card: HistoryCard, focusOnLoad: Bool, maxBytes: Int) {
        id = card.id
        self.maxBytes = maxBytes
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
    /// Unsaved text. The title does not count: it saves itself when the field is left.
    var isDirty: Bool { isTextDirty }

    /// Point size of the text (⌘+ / ⌘− / ⌘0 in the record window), kept for the next record.
    var fontSize: CGFloat = ItemState.storedFontSize {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
            applyFont()
        }
    }

    /// Monospaced (logs, JSON, code) or the system font (prose), whatever the highlighting.
    var usesMonospacedFont = UserDefaults.standard.object(forKey: ItemState.monospacedKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(usesMonospacedFont, forKey: Self.monospacedKey)
            applyFont()
        }
    }

    /// Within 80 % of the size limit: the status bar shows the size.
    var isNearSizeLimit: Bool { byteCount.map { $0 >= maxBytes / 5 * 4 } ?? false }
    var isOverSizeLimit: Bool { byteCount.map { $0 > maxBytes } ?? false }

    static let defaultFontSize: CGFloat = 12.5
    private static let fontSizeKey = "recordFontSize"
    private static let monospacedKey = "recordMonospacedFont"
    private static let lineNumbersKey = "recordLineNumbers"
    private static let invisiblesKey = "recordShowsInvisibles"
    private static var storedLineNumbers: Bool? { UserDefaults.standard.object(forKey: lineNumbersKey) as? Bool }

    var showsLineNumbers: Bool { lineNumbersPreference ?? (highlightedLanguage != nil) }

    private func applyRulers() {
        guard let scrollView = textView?.enclosingScrollView, scrollView.verticalRulerView != nil else { return }
        if scrollView.rulersVisible != showsLineNumbers { scrollView.rulersVisible = showsLineNumbers }
        (scrollView.verticalRulerView as? LineNumberRuler)?.textDidChange()
    }

    private func applyFont() {
        guard let textView else { return }
        if isRich {
            // Formatted text keeps its own fonts: the size controls zoom it instead.
            if let scrollView = textView.enclosingScrollView {
                scrollView.allowsMagnification = true
                scrollView.magnification = richScale * fontSize / Self.defaultFontSize
            }
        } else {
            textView.enclosingScrollView?.magnification = 1
            textView.font = usesMonospacedFont ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize)
        }
        // Line heights changed: the numbers move with them.
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func applyInvisibles() {
        (textView as? FocusReportingTextView)?.showsInvisibles = showsInvisibles
    }

    /// From the text view's delegate whenever the selection moves.
    func selectionDidChange() {
        guard let textView else { return }
        let range = textView.selectedRange()
        var characters = range.length
        var lines = 0
        // Counted exactly up to the size the status bar counts the whole text (UTF-16 above it).
        // Through the storage's own string: `textView.string` would copy all of the text.
        if range.length > 0, range.length < 200_000, let text = textView.textStorage?.mutableString {
            let selected = text.substring(with: range)
            characters = selected.count
            lines = TextStats.lineCount(selected)
        }
        if characters != selectedCharacters { selectedCharacters = characters }
        if lines != selectedLines { selectedLines = lines }
        scheduleAvailability()
    }

    @ObservationIgnored private var availabilityTask: Task<Void, Never>?

    /// Which text actions apply, a moment after the text or the selection changed. Very long text is
    /// not checked: every action stays on and reports when it does not apply.
    private func scheduleAvailability() {
        availabilityTask?.cancel()
        guard isEditable else { return }
        availabilityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let textView = self.textView, let text = textView.textStorage?.mutableString else { return }
            let selection = textView.selectedRange()
            let range = selection.length > 0 ? selection : NSRange(location: 0, length: text.length)
            guard range.length <= 100_000 else {
                if self.availableActions.count != TextAction.allCases.count { self.availableActions = Set(TextAction.allCases) }
                return
            }
            let target = text.substring(with: range)
            let available = await Task.detached(priority: .userInitiated) {
                Set(TextAction.allCases.filter { $0.isAvailable(for: target) })
            }.value
            guard !Task.isCancelled, available != self.availableActions else { return }
            self.availableActions = available
        }
    }
    private static var storedFontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored > 0 ? CGFloat(stored) : defaultFontSize
    }

    func changeFontSize(by step: CGFloat) {
        fontSize = min(max(fontSize + step, 9), 28)
    }

    func titleSaved() {
        originalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save kept the window open: what was saved is the new starting point. Typing during the save
    /// stays unsaved (review finding).
    func textSaved(_ text: String, rich: NSAttributedString?) {
        initialText = text
        if isRich, let rich {
            initialRich = rich
            richSource = rich
        } else if !isRich, hasRichSource {
            // Saved as plain text: the formatted original is no longer stored (review finding).
            richSource = nil
            initialRich = nil
            hasRichSource = false
        }
        updateDirty()
    }

    /// The title as stored, once the record's details are read: the card the window opened with
    /// may be older (review finding). A title being typed is left alone.
    /// Several items in one copy (bookmarks, notes): the editor shows the first one's text, and
    /// saving would drop the others (review finding).
    func makeReadOnly() {
        isEditable = false
        focusOnLoad = false
        textView?.isEditable = false
    }

    func adoptStoredTitle(_ stored: String?) {
        let stored = stored ?? ""
        guard stored != originalTitle, !titleChanged else { return }
        originalTitle = stored
        title = stored
    }

    /// Formatted text: shown with its formatting, editable as rich text.
    func load(rich: NSAttributedString) {
        richSource = rich
        hasRichSource = true
        isRich = true
        initialText = rich.string
        isLoaded = true
        if let textView {
            showRich(in: textView)
            textView.isEditable = isEditable
        }
        textDidChange()
        if focusOnLoad { focus() }
    }

    private func showRich(in textView: NSTextView) {
        guard let richSource, let storage = textView.textStorage else { return }
        textView.isRichText = true
        // On the page it was made for, in its own colours — a white page, or a dark one for light
        // text such as code copied from a dark editor theme — as a document, not recoloured for the
        // window (first-run feedback: mapped colours and small sizes were hard to read).
        let isDarkPage = Self.isWrittenForDarkPage(richSource)
        let page = isDarkPage ? NSColor(white: 0.13, alpha: 1) : NSColor.white
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.appearance = NSAppearance(named: isDarkPage ? .darkAqua : .aqua)
        textView.drawsBackground = true
        textView.backgroundColor = page
        textView.enclosingScrollView?.drawsBackground = true
        textView.enclosingScrollView?.backgroundColor = page
        textView.textContainerInset = NSSize(width: 22, height: 18)
        richScale = Self.readableScale(for: richSource)
        storage.setAttributedString(richSource)
        textView.undoManager?.removeAllActions()
        // As the text view holds it: loading may have fixed fonts or attributes.
        initialRich = storage.copy() as? NSAttributedString
        applyFont()
    }

    /// *Show Formatting* in the View menu. Only without unsaved changes: the other view starts from
    /// the stored text. Off, the text is plain — code features on — and saving keeps only the text.
    func setShowsFormatting(_ on: Bool) {
        guard hasRichSource, on != isRich, !isDirty, let textView, let storage = textView.textStorage else { return }
        isRich = on
        if on {
            highlightTask?.cancel()
            if highlightedLanguage != nil {
                highlightedLanguage = nil
                applyRulers()
            }
            showRich(in: textView)
        } else {
            let text = storage.string
            textView.isRichText = false
            textView.appearance = nil
            textView.drawsBackground = false
            textView.enclosingScrollView?.drawsBackground = false
            textView.textContainerInset = NSSize(width: 10, height: 10)
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: textView.defaultParagraphStyle ?? .default,
            ]))
            textView.undoManager?.removeAllActions()
            initialRich = nil
            initialText = text
            applyFont()
        }
        textDidChange()
    }

    /// Most of the text is light: it was written for a dark page.
    private static func isWrittenForDarkPage(_ text: NSAttributedString) -> Bool {
        var light = 0
        var dark = 0
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: min(text.length, 100_000)), options: []) { value, range, _ in
            // No colour of its own: black.
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else {
                dark += range.length
                return
            }
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            if luminance > 0.6 { light += range.length } else { dark += range.length }
        }
        return light > dark
    }

    /// The zoom at which the size most of the text has reads as 14 pt; never below 1 (large text
    /// stays as it is) and at most 2.5.
    private static func readableScale(for text: NSAttributedString) -> CGFloat {
        var characters: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: min(text.length, 100_000)), options: []) { value, range, _ in
            characters[((value as? NSFont)?.pointSize ?? 12).rounded(), default: 0] += range.length
        }
        guard let common = characters.max(by: { $0.value < $1.value })?.key, common > 0 else { return 1 }
        return min(max(14 / common, 1), 2.5)
    }

    /// RTF (flat RTFD with attachments) and HTML of the formatted text, for saving.
    func richContent() -> RichContent? {
        guard isRich, let storage = textView?.textStorage else { return nil }
        let range = NSRange(location: 0, length: storage.length)
        let hasAttachments = storage.containsAttachments(in: range)
        let data = hasAttachments
            ? storage.rtfd(from: range, documentAttributes: [:])
            : storage.rtf(from: range, documentAttributes: [:])
        guard let data else { return nil }
        let html = try? storage.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ])
        return RichContent(type: hasAttachments ? .flatRTFD : .rtf, data: data, html: html)
    }

    /// ⌘B, ⌘I and the toolbar: bold or italic for the selection — off when all of it has it —
    /// or for what is typed next. One change ⌘Z undoes.
    func toggleTrait(_ trait: NSFontTraitMask) {
        guard isRich, let textView, let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        let fallback = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let range = textView.selectedRange()
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? fallback
            let has = manager.traits(of: font).contains(trait)
            attributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attributes
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            if !manager.traits(of: value as? NSFont ?? fallback).contains(trait) {
                allHave = false
                stop.pointee = true
            }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = value as? NSFont ?? fallback
            let converted = allHave ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// ⌘U and the toolbar: underline the selection, or remove it when all of it is underlined.
    func toggleUnderline() {
        guard isRich, let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 {
                attributes.removeValue(forKey: .underlineStyle)
            } else {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            textView.typingAttributes = attributes
            return
        }
        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, stop in
            if (value as? Int ?? 0) == 0 {
                allUnderlined = false
                stop.pointee = true
            }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        if allUnderlined {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        textView.didChangeText()
    }

    /// ⌘F on an image: the find bar of the recognized text, opening its pane first.
    func findInRecognizedText() {
        UserDefaults.standard.set(true, forKey: "recordRecognizedTextShown")
        recognizedText.showFind()
    }

    func load(_ text: String) {
        initialText = text
        isLoaded = true
        if let textView {
            if textView.string.isEmpty { textView.string = text }
            textView.isEditable = isEditable
        }
        textDidChange()
        if focusOnLoad { focus() }
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        // Editable once the text is in: typed before, it would replace the record's text
        // (review finding).
        textView.isEditable = isEditable && isLoaded
        applyFont()
        applyInvisibles()
        if isLoaded, textView.string.isEmpty {
            if isRich { showRich(in: textView) } else { textView.string = initialText }
        }
        applyWrapping()
        applyRulers()
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
        editVersion += 1
        // Counting walks the whole text: for long text it waits until typing pauses (review
        // finding: every keystroke copied and counted megabytes).
        countsTask?.cancel()
        if (textView?.textStorage?.length ?? initialLength) > 200_000 {
            countsTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.updateCounts()
            }
        } else {
            updateCounts()
        }
        updateDirty()
        (textView?.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.textDidChange()
        scheduleAvailability()
        scheduleHighlight(after: .milliseconds(isLoaded && isTextDirty ? 300 : 0))
    }

    private func updateCounts() {
        // The storage itself, never a copy: a bridged copy of megabytes was walked byte by byte on
        // the main thread (review finding).
        let text: NSString = textView?.textStorage?.mutableString ?? (initialText as NSString)
        let length = text.length
        characterCount = length < 200_000 ? (text as String).count : length
        lineCount = Self.lineCount(of: text)
        // UTF-8 takes at most 3 bytes per UTF-16 unit: far from the limit there is nothing to count.
        let bytes: Int? = length * 3 < maxBytes / 5 * 4 ? nil : text.lengthOfBytes(using: String.Encoding.utf8.rawValue)
        if bytes != byteCount { byteCount = bytes }
        if card.displayType == .url {
            let link = length < 10_000 ? (text as String).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if link != linkText { linkText = link }
        }
    }

    /// `TextStats.lineCount` read in blocks of UTF-16 units: trailing line breaks start no line.
    private static func lineCount(of text: NSString) -> Int {
        var breaks = 0
        var trailing = 0
        var buffer = [unichar](repeating: 0, count: 4_096)
        var location = 0
        let length = text.length
        while location < length {
            let count = min(buffer.count, length - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for offset in 0..<count {
                let unit = buffer[offset]
                if unit == 10 {
                    breaks += 1
                    trailing += 1
                } else if unit != 13 {
                    trailing = 0
                }
            }
            location += count
        }
        return max(1, breaks - trailing + 1)
    }

    private func updateDirty() {
        let textChanged: Bool
        if !isLoaded {
            textChanged = false
        } else if isRich, let storage = textView?.textStorage, let initialRich {
            textChanged = !storage.isEqual(to: initialRich)
        } else if let storage = textView?.textStorage {
            // Lengths first; the text itself without copying it.
            textChanged = storage.length != initialLength || !storage.mutableString.isEqual(to: initialText)
        } else {
            textChanged = false
        }
        if textChanged != isTextDirty { isTextDirty = textChanged }
        // The dot in the close button, as in any Mac editor.
        if let window = textView?.window, window.isDocumentEdited != textChanged { window.isDocumentEdited = textChanged }
    }

    /// Back to the stored text and title, as one change ⌘Z undoes.
    func revert() {
        title = originalTitle
        guard let textView else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: range, replacementString: initialText) else { return }
        if isRich, let initialRich {
            textView.textStorage?.replaceCharacters(in: range, with: initialRich)
        } else {
            textView.textStorage?.replaceCharacters(in: range, with: initialText)
        }
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Runs a text action on the selection, or on everything when nothing is selected (§3.9).
    /// Long text is worked on off the main thread and replaced only if it did not change meanwhile
    /// (review finding: formatting a 10 MB JSON froze the app).
    func apply(_ action: TextAction) {
        guard let textView, isEditable, isLoaded, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: storage.length)
        let input = storage.mutableString.substring(with: range)
        guard range.length > 100_000 else { return replace(range, with: action.apply(to: input), for: action) }
        let version = editVersion
        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { action.apply(to: input) }.value
            guard let self, self.editVersion == version else { return }
            self.replace(range, with: output, for: action)
        }
    }

    private func replace(_ range: NSRange, with output: String?, for action: TextAction) {
        guard let textView else { return }
        guard let output else {
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

    /// The text view's find bar (⌘F), with Replace (⌥⌘F) when the text is editable.
    func showFind(replace: Bool = false) {
        guard let textView else { return }
        let item = NSMenuItem()
        item.tag = (replace && isEditable ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        textView.performFindPanelAction(item)
    }

    // MARK: Highlighting (§8.5)

    private func scheduleHighlight(after delay: Duration) {
        highlightTask?.cancel()
        // Formatted text keeps its own colours.
        guard hasText, card.displayType != .url, !isRich else { return }
        highlightTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.highlight()
        }
    }

    /// Tokenizes off the main actor and colours the text in place; edits made meanwhile win.
    private func highlight() async {
        guard let textView, let storage = textView.textStorage else { return }
        // The limit before the copy: copying megabytes only to skip them was a pause per edit.
        guard storage.length <= Self.highlightLimit else { return }
        let text = textView.string
        let length = (text as NSString).length
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
        if chosen != highlightedLanguage {
            highlightedLanguage = chosen
            applyRulers()
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
            // Back to the visible width first: the text view kept the width of its longest line. In
            // document units, so a zoomed page is not cut off on the right (review finding).
            let width = scrollView.contentView.bounds.width
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
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
    /// ⌘F came before the text view was shown.
    @ObservationIgnored private var findsOnAttach = false

    func attach(_ textView: NSTextView, text: String) {
        self.textView = textView
        textView.string = text
        update()
        if findsOnAttach {
            findsOnAttach = false
            Task { @MainActor in self.showFind() }
        }
    }

    /// The find bar of the text.
    func showFind() {
        guard let textView else {
            findsOnAttach = true
            return
        }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
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
