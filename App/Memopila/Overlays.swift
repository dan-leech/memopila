import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

// MARK: - Record window content (§8.5, §3.6)

/// `nil` in the store = detect automatically; `plain` = no highlighting; otherwise a language.
enum LanguageChoice: Hashable {
    case auto
    case plain
    case language(CodeLanguage)

    init(stored: String?) {
        switch stored {
        case nil: self = .auto
        case "plain": self = .plain
        case let raw?: self = CodeLanguage(rawValue: raw).map(LanguageChoice.language) ?? .auto
        }
    }

    var stored: String? {
        switch self {
        case .auto: nil
        case .plain: "plain"
        case .language(let language): language.rawValue
        }
    }
}

/// The record window's content (PLAN §8.5): one place to look at a record and to edit it.
/// First-run feedback: icon-only controls and a hidden details popover left too much to guess, so
/// every control has a label or a tooltip, the details sit in an inspector, and the status bar
/// says what the keys do right now.
///
/// - Toolbar: ‹ › and the position, Undo / Redo and labelled text-action menus, Find, the inspector
///   toggle and **Select**.
/// - Content: the text (edited in place, code highlighted as you type), the image, the file or the
///   colour.
/// - Inspector: title, source, highlighting language, text found in an image, details.
/// - Status bar: what to do next, counts, Wrap lines, Revert / Save.
struct RecordView: View {
    let model: AppModel
    @Bindable var state: ItemState
    @State private var details: RecordDetails?
    @State private var image: NSImage?
    @State private var recognizedText = TextSelection()
    @State private var newCollectionName = ""
    @AppStorage(RecordView.inspectorKey) private var showsInspector = true

    static let inspectorKey = "recordInspectorShown"

    private var card: HistoryCard { details?.card ?? state.card }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsInspector {
                    Divider()
                    inspector
                        .frame(width: 260)
                        .transition(.move(edge: .trailing))
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: showsInspector)
        .task(id: state.id) { await load() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            navigation
            if state.isEditable {
                Divider().frame(height: 18).padding(.horizontal, 4)
                ToolbarIcon(systemImage: "arrow.uturn.backward", help: String(localized: "Undo (⌘Z)")) { state.undo() }
                ToolbarIcon(systemImage: "arrow.uturn.forward", help: String(localized: "Redo (⇧⌘Z)")) { state.redo() }
                Divider().frame(height: 18).padding(.horizontal, 4)
                actionMenu(String(localized: "Case"), systemImage: "textformat.size", actions: [.uppercase, .lowercase, .titleCase])
                actionMenu(
                    String(localized: "Lines"),
                    systemImage: "line.3.horizontal.decrease",
                    actions: [.trimWhitespace, .removeLineBreaks, .sortLines, .removeDuplicateLines]
                )
                actionMenu("JSON", systemImage: "curlybraces", actions: [.formatJSON, .minifyJSON])
                actionMenu(
                    String(localized: "Encode"),
                    systemImage: "percent",
                    actions: [.urlEncode, .urlDecode, .base64Encode, .base64Decode]
                )
            }
            if state.hasText {
                Button { state.showFind() } label: { Label("Find", systemImage: "magnifyingglass") }
                    .help(String(localized: "Find in the text (⌘F)"))
            }
            Spacer(minLength: 8)
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help(showsInspector
                ? String(localized: "Hide the title, source and details (⌥⌘I)")
                : String(localized: "Show the title, source and details (⌥⌘I)"))
            .accessibilityLabel(Text("Inspector"))
            // ↩ and ⌘↩ come through the window's key handler: ↩ must stay a new line while typing.
            Button { model.copyItem() } label: {
                ShortcutLabel(
                    title: state.isDirty ? String(localized: "Save and Select") : String(localized: "Select"),
                    shortcut: state.isDirty || state.isEditingText ? "⌘↩" : "↩"
                )
            }
            .buttonStyle(.borderedProminent)
            .help(state.isDirty
                ? String(localized: "Save the changes, make this record the clipboard content and go back to the app you were in (⌘↩)")
                : String(localized: "Make this record the clipboard content and go back to the app you were in (↩)"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// ‹ › and *3 of 120*: the records of the panel's current list.
    private var navigation: some View {
        let history = model.history
        let index = history.selectedIndex
        let blocked = state.isDirty
        return HStack(spacing: 2) {
            ToolbarIcon(
                systemImage: "chevron.left",
                help: blocked ? String(localized: "Save or revert your changes first") : String(localized: "Previous record (←)")
            ) { model.openAdjacentRecord(-1) }
            .disabled(blocked || (index ?? 0) == 0)
            ToolbarIcon(
                systemImage: "chevron.right",
                help: blocked ? String(localized: "Save or revert your changes first") : String(localized: "Next record (→)")
            ) { model.openAdjacentRecord(1) }
            .disabled(blocked || index.map { $0 >= history.cards.count - 1 } ?? true)
            if let index {
                Text(String(localized: "\(index + 1) of \(history.totalCount)"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    /// Text actions on the selection, or on all text when nothing is selected (§3.9).
    private func actionMenu(_ title: String, systemImage: String, actions: [TextAction]) -> some View {
        Menu {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { state.apply(action) }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .menuStyle(.button)
        .fixedSize()
        .help(String(localized: "\(title): applies to the selected text, or to all of it"))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.hasText {
            TextPane(isEditable: state.isEditable, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular)) { textView in
                state.attach(textView)
            } onTextChange: {
                state.textDidChange()
            } onFocusChange: { focused in
                state.isEditingText = focused
            }
            .overlay {
                if !state.isLoaded, state.error == nil { ProgressView().controlSize(.small) }
            }
        } else {
            Group {
                switch card.displayType {
                case .image, .pdf:
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: card.displayType.systemImage).font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Checkerboard().opacity(0.15))
                case .color:
                    VStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(card.colorHex.flatMap(Color.init(hex:)) ?? .clear)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                            .frame(width: 160, height: 160)
                        Text(card.colorHex ?? "").font(.title.monospaced()).textSelection(.enabled)
                    }
                case .file:
                    FilePreview(card: card, thumbnails: model.thumbnails)
                case .text, .richText, .url, .mixed:
                    EmptyView()
                }
            }
            .padding(16)
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorSection(String(localized: "Title")) {
                    TextField("Title", text: $state.title, prompt: Text("Shown on the card"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .help(String(localized: "A title is shown on the card and found by search"))
                }
                inspectorSection(String(localized: "Source")) { source }
                inspectorSection(String(localized: "Collections")) { collections }
                if state.hasText, card.displayType != .url {
                    inspectorSection(String(localized: "Highlighting")) { languagePicker }
                }
                if let text = details?.recognizedText {
                    inspectorSection(String(localized: "Text in Image")) {
                        TextPane(isEditable: false, font: .systemFont(ofSize: 12)) { textView in
                            recognizedText.attach(textView, text: text)
                        } onSelectionChange: {
                            recognizedText.update()
                        }
                        .frame(height: 160)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        Button(recognizedText.hasSelection ? String(localized: "Copy Selected Text") : String(localized: "Copy All Text")) {
                            model.copyNewText(recognizedText.selectedOrAll ?? text, from: state.id)
                        }
                        .controlSize(.small)
                        .help(String(localized: "The text goes to the clipboard and appears in history as a new item"))
                    }
                }
                if let details {
                    inspectorSection(String(localized: "Details")) { metadata(details) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var source: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let icon = AppInfo.icon(for: card.sourceAppBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(card.sourceAppName ?? String(localized: "App unknown")).lineLimit(1)
            }
            if let url = card.sourceURL, let link = URL(string: url) {
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        model.copyNewText(url, from: state.id)
                    } else {
                        NSWorkspace.shared.open(link)
                    }
                } label: {
                    Label(link.host() ?? url, systemImage: "arrow.up.right.square").lineLimit(1)
                }
                .buttonStyle(.link)
                .help(String(localized: "Click to open, Option-click to copy the link"))
            }
            if let title = details?.sourceWindowTitle {
                Text(String(localized: "Window: “\(title)”")).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .font(.callout)
    }

    /// Every collection with a checkbox: membership is seen and changed in one place.
    private var collections: some View {
        let history = model.history
        let members = history.memberships[state.id] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(history.collections) { collection in
                let recordID = state.id
                let collectionID = collection.id
                Toggle(collection.name, isOn: Binding.main(
                    get: { members.contains(collectionID) },
                    set: { [model] isMember in model.setMembership(recordID, collection: collectionID, isMember: isMember) }
                ))
                .toggleStyle(.checkbox)
                .lineLimit(1)
            }
            TextField("New Collection", text: $newCollectionName, prompt: Text("New collection…"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit {
                    model.createCollection(named: newCollectionName, adding: state.id)
                    newCollectionName = ""
                }
                .help(String(localized: "Type a name and press Return: the collection is created with this record in it"))
        }
        .font(.callout)
    }

    private var languagePicker: some View {
        Picker("Language", selection: $state.language) {
            Text(String(localized: "Automatic (\(state.detectedLanguage?.displayName ?? String(localized: "plain text")))")).tag(LanguageChoice.auto)
            Text("Plain Text").tag(LanguageChoice.plain)
            Divider()
            ForEach(CodeLanguage.allCases, id: \.self) { language in
                Text(language.displayName).tag(LanguageChoice.language(language))
            }
        }
        .labelsHidden()
        .help(String(localized: "Language for syntax highlighting"))
        .onChange(of: state.language) { _, value in model.setCodeLanguage(state.id, value.stored) }
    }

    private func metadata(_ details: RecordDetails) -> some View {
        let card = details.card
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            row(String(localized: "First copied"), card.firstCopiedAt.formatted(date: .abbreviated, time: .shortened))
            row(String(localized: "Last copied"), card.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
            row(String(localized: "Copies"), "\(card.copyCount)")
            row(String(localized: "Size"), ByteCount.string(card.payloadSizeBytes))
            row(String(localized: "Formats"), Self.formatList(details.storedTypes))
            if !card.skippedTypes.isEmpty {
                row(String(localized: "Skipped"), Self.formatList(card.skippedTypes))
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    /// Readable, without repeats (UTF-8 and legacy plain text both read *Plain text*).
    private static func formatList(_ types: [String]) -> String {
        var seen = Set<String>()
        return types.map(FormatNames.short).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if state.isConfirmingDiscard {
                Text("Discard your changes?").font(.callout)
                Spacer()
                Button("Keep Editing") { state.isConfirmingDiscard = false }
                Button("Discard", role: .destructive) { model.closeRecord() }
            } else {
                if state.isDirty {
                    Label("Edited", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                }
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if state.hasFormatting, state.isTextDirty {
                    Label("Formatting will be removed", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(String(localized: "This item has rich text; saving keeps the plain text only."))
                }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer(minLength: 8)
                if state.hasText {
                    Text(stats).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Toggle("Wrap lines", isOn: $state.wrapsLines)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help(String(localized: "Break long lines at the window edge instead of scrolling sideways"))
                }
                if state.isDirty {
                    Button("Revert") { state.revert() }
                        .help(String(localized: "Go back to the saved text and title"))
                    Button { model.saveItem() } label: { ShortcutLabel(title: String(localized: "Save"), shortcut: "⌘S") }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isSaving || (state.hasText && !state.isLoaded))
                        .help(String(localized: "Save the changes"))
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// What the keys do right now.
    private var hint: String {
        if state.isDirty {
            return String(localized: "⌘S saves · ⌘↩ saves and selects · Esc discards")
        }
        if state.isEditingText {
            return String(localized: "Editing · Esc stops editing")
        }
        if state.isEditable {
            return String(localized: "Click the text to edit · ← → other records · ↩ selects · Esc closes")
        }
        return String(localized: "← → other records · ↩ selects · Esc closes")
    }

    private var stats: String {
        let characters = String(localized: "\(state.characterCount) characters")
        guard state.lineCount > 1 else { return characters }
        return String(localized: "\(state.lineCount) lines") + " · " + characters
    }

    private func load() async {
        // The text comes through `ItemState`; this is the source, the details and the image.
        let loaded = await model.details(state.id, maxTextScalars: 0)
        // `.task(id:)` cancels a load for a record the user already moved past; never let it overwrite.
        guard !Task.isCancelled else { return }
        details = loaded
        guard [.image, .pdf].contains(state.card.displayType) else { return }
        let loadedImage = await model.previewImage(state.id, maxPixelSize: 1_600)
        guard !Task.isCancelled else { return }
        image = loadedImage
    }
}

private struct FilePreview: View {
    let card: HistoryCard
    let thumbnails: ThumbnailCache
    @State private var image: NSImage?
    @State private var status: ThumbnailCache.FileStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc").font(.system(size: 48)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 140)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(card.filePaths, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                }
                if let status {
                    if status.allMissing {
                        Text("Unavailable: the file was moved or deleted.").font(.caption).foregroundStyle(.orange)
                    } else if let bytes = status.totalBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Reveal in Finder") {
                    let urls = card.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .disabled(status?.allMissing ?? false)
            }
            Spacer(minLength: 0)
        }
        .task(id: card.id) {
            status = await thumbnails.fileStatus(for: card)
            image = await thumbnails.image(for: card)
        }
    }
}

struct StyledRange: Sendable {
    let location: Int
    let length: Int
    let kind: CodeToken.Kind
}

enum CodeStyler {
    static func ranges(_ text: String, language: CodeLanguage?) async -> [StyledRange] {
        guard let language else { return [] }
        return await Task.detached(priority: .userInitiated) {
            CodeHighlighter.tokenize(text, as: language).map { token in
                let range = NSRange(token.range, in: text)
                return StyledRange(location: range.location, length: range.length, kind: token.kind)
            }
        }.value
    }

    /// System colors adapt to light and dark appearance.
    @MainActor
    static func color(for kind: CodeToken.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .systemGray
        case .number: .systemPurple
        case .key: .systemBlue
        case .tag: .systemBlue
        case .attribute: .systemTeal
        }
    }
}

private struct ToolbarIcon: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private struct ShortcutLabel: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut).opacity(0.6)
        }
    }
}

/// `NSTextView` for the record window: editable plain text with its own undo stack and the system
/// find bar, or read-only selectable text (the text found in an image). Reports when it takes or
/// loses the keyboard focus, so the window can say whether the text is being edited.
struct TextPane: NSViewRepresentable {
    let isEditable: Bool
    let font: NSFont
    let onAttach: @MainActor (NSTextView) -> Void
    var onTextChange: @MainActor () -> Void = {}
    var onSelectionChange: @MainActor () -> Void = {}
    var onFocusChange: @MainActor (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = FocusReportingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = font
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        textView.defaultParagraphStyle = paragraph
        scrollView.documentView = textView
        context.coordinator.pane = self
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.pane?.onFocusChange(focused)
        }
        onAttach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.pane = self
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var pane: TextPane?

        func textDidChange(_ notification: Notification) {
            pane?.onTextChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            pane?.onSelectionChange()
        }
    }
}

/// Tells when it becomes or stops being the first responder.
final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

// MARK: - ⌘K actions panel (§8.4)

struct ActionsPanel: View {
    @Bindable var state: ActionsPanelState
    let model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search actions", text: $state.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.filtered.enumerated()), id: \.element.id) { index, item in
                            row(item, isHighlighted: index == state.highlighted)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    state.highlighted = index
                                    model.runHighlightedAction()
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.highlighted) { _, index in
                    let items = state.filtered
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
            .frame(height: 320)
        }
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func row(_ item: ActionItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage ?? "circle.dashed")
                .frame(width: 18)
                .foregroundStyle(item.isDestructive ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let reason = item.disabledReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(item.isEnabled ? 1 : 0.5)
        .background(isHighlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
