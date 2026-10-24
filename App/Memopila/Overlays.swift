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
/// - Toolbar: ‹ › and the position, Undo / Redo, *Transform*, bold / italic / underline for
///   formatted text, Find, the inspector toggle and **Select**.
/// - Content: the text (edited in place: code highlighted as you type, formatted text with its
///   formatting), a link's header, the image with the text found in it, the file through Quick Look
///   or the colour with its values.
/// - Inspector (hidden in a narrow window unless asked for): title, source, collections, details.
/// - Status bar: what to do next, counts, language, View, Changes / Revert / Save.
struct RecordView: View {
    let model: AppModel
    @Bindable var state: ItemState
    @State private var details: RecordDetails?
    @State private var image: NSImage?
    @State private var newCollectionName = ""
    @State private var showsChanges = false
    @State private var isNamingCollection = false
    @FocusState private var collectionNameFocused: Bool
    @State private var dragStartHeight: Double?
    @AppStorage(RecordView.inspectorKey) private var showsInspector = true
    @AppStorage("recordRecognizedTextShown") private var showsRecognizedText = true
    @AppStorage("recordRecognizedTextHeight") private var recognizedTextHeight = 170.0
    @AppStorage("recordDetailsExpanded") private var showsDetails = false
    /// The window's width: below `inspectorMinWidth` the inspector hides unless asked for.
    @State private var width: CGFloat = 1_000
    @State private var showsInspectorWhenNarrow = false

    static let inspectorKey = "recordInspectorShown"
    /// Narrower than this, the text or image keeps the room (first-run feedback).
    private static let inspectorMinWidth: CGFloat = 780

    private var isNarrow: Bool { width < Self.inspectorMinWidth }
    private var inspectorVisible: Bool { isNarrow ? showsInspectorWhenNarrow : showsInspector }

    private func toggleInspector() {
        if isNarrow { showsInspectorWhenNarrow.toggle() } else { showsInspector.toggle() }
    }

    private var card: HistoryCard { details?.card ?? state.card }
    private var isImage: Bool { [.image, .pdf].contains(state.card.displayType) }
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspectorVisible {
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
        .animation(.easeOut(duration: 0.15), value: inspectorVisible)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: isNarrow) { _, _ in showsInspectorWhenNarrow = false }
        .onChange(of: state.inspectorToggleRequests) { _, _ in toggleInspector() }
        .task(id: state.id) { await load() }
        // Recognition finished while the record is open: its text appears under the image.
        .onChange(of: model.recognitionTick) { _, _ in
            Task { details = await model.details(state.id, maxTextScalars: 0) }
        }
        .onChange(of: state.language) { _, value in model.setCodeLanguage(state.id, value.stored) }
        .sheet(isPresented: $showsChanges) {
            ChangesSheet(
                original: state.initialText,
                edited: state.currentText() ?? state.initialText,
                formattingChanged: state.isRich && state.isDirty
            ) { model.saveItem() }
        }
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
                transformMenu
                if state.isRich {
                    ToolbarIcon(systemImage: "bold", help: String(localized: "Bold (⌘B)")) { state.toggleTrait(.boldFontMask) }
                    ToolbarIcon(systemImage: "italic", help: String(localized: "Italic (⌘I)")) { state.toggleTrait(.italicFontMask) }
                    ToolbarIcon(systemImage: "underline", help: String(localized: "Underline (⌘U)")) { state.toggleUnderline() }
                }
            }
            if isImage, details?.recognizedText != nil {
                Button { state.findInRecognizedText() } label: { Label("Find", systemImage: "magnifyingglass") }
                    .help(String(localized: "Find in the text recognized in the image (⌘F)"))
            }
            if state.hasText {
                Button { state.showFind() } label: { Label("Find", systemImage: "magnifyingglass") }
                    .help(state.isEditable
                        ? String(localized: "Find in the text (⌘F); Find and Replace (⌥⌘F)")
                        : String(localized: "Find in the text (⌘F)"))
            }
            if isImage { imageControls }
            Spacer(minLength: 8)
            Button {
                toggleInspector()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help(inspectorVisible
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
            .disabled(state.isDirty && cannotSaveReason != nil)
            .help(state.isDirty
                ? cannotSaveReason ?? String(localized: "Save the changes, make this record the clipboard content and go back to the app you were in (⌘↩)")
                : String(localized: "Make this record the clipboard content and go back to the app you were in (↩)"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Zoom, Fit, Actual Size and Preview for an image or PDF (§8.5).
    @ViewBuilder
    private var imageControls: some View {
        let zoom = state.imageZoom
        Divider().frame(height: 18).padding(.horizontal, 4)
        ToolbarIcon(systemImage: "minus.magnifyingglass", help: String(localized: "Zoom Out (⌘−)")) { zoom.zoom(by: 1 / 1.25) }
        Text(verbatim: "\(zoom.percent) %")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 44)
            .help(String(localized: "Zoom level: at 100, one image pixel is one screen pixel"))
        ToolbarIcon(systemImage: "plus.magnifyingglass", help: String(localized: "Zoom In (⌘+)")) { zoom.zoom(by: 1.25) }
        Button("Fit") { zoom.fit() }
            .help(String(localized: "Fit the image in the window (⌘0)"))
        Button("Actual Size") { zoom.actualSize() }
            .help(String(localized: "One image pixel per screen pixel"))
        // Preview's own icon right next to the words: one button, not an icon and a label apart.
        Button { model.openInPreview(state.id) } label: {
            HStack(spacing: 4) {
                if let icon = AppInfo.icon(for: "com.apple.Preview") {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                }
                Text("Open in Preview")
            }
        }
        .help(String(localized: "Open the image in Preview to mark it up, crop or export it"))
    }

    /// ‹ › and *3 of 120*: the records of the panel's current list. With unsaved text they ask to
    /// save first.
    private var navigation: some View {
        let history = model.history
        let index = history.selectedIndex
        return HStack(spacing: 2) {
            ToolbarIcon(systemImage: "chevron.left", help: String(localized: "Previous record (←)")) { model.openAdjacentRecord(-1) }
                .disabled((index ?? 0) == 0)
            ToolbarIcon(systemImage: "chevron.right", help: String(localized: "Next record (→)")) { model.openAdjacentRecord(1) }
                .disabled(index.map { $0 >= history.cards.count - 1 } ?? true)
            if let index {
                Text(String(localized: "\(index + 1) of \(history.totalCount)"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    /// Text actions on the selection, or on all text when nothing is selected (§3.9), in one menu
    /// grouped as Case, Lines, JSON, Encode (first-run feedback: four menus took the toolbar). One that
    /// does not apply is disabled and says why, as in ⌘K.
    private var transformMenu: some View {
        let scope = state.selectedCharacters > 0 ? String(localized: "the selected text") : String(localized: "all of the text")
        let groups: [(String, [TextAction])] = [
            (String(localized: "Case"), [.uppercase, .lowercase, .titleCase]),
            (String(localized: "Lines"), [.trimWhitespace, .removeLineBreaks, .sortLines, .removeDuplicateLines]),
            ("JSON", [.formatJSON, .minifyJSON]),
            (String(localized: "Encode"), [.urlEncode, .urlDecode, .base64Encode, .base64Decode]),
        ]
        let anyAvailable = !state.availableActions.isEmpty
        return Menu {
            ForEach(groups.indices, id: \.self) { index in
                Section(groups[index].0) {
                    ForEach(groups[index].1, id: \.self) { action in
                        let isAvailable = state.availableActions.contains(action)
                        Button(action.title) { state.apply(action) }
                            .disabled(!isAvailable)
                            .help(isAvailable ? String(localized: "Applies to \(scope)") : action.unavailableReason)
                    }
                }
            }
        } label: {
            Label("Transform", systemImage: "wand.and.stars")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!anyAvailable)
        .help(String(localized: "Change case, lines, JSON or encoding; applies to \(scope); ⌘Z undoes it"))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.hasText {
            VStack(spacing: 0) {
                if state.card.displayType == .url {
                    linkHeader
                    Divider()
                }
                textEditor
            }
        } else if isImage {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    // Zoom with ⌘+ / ⌘− / ⌘0, a pinch or the toolbar; scroll when larger than the window.
                    Group {
                        if let image {
                            ZoomableImage(image: image, zoom: state.imageZoom)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    recognizedTextPane(availableHeight: proxy.size.height)
                }
            }
        } else if card.displayType == .file {
            FilePreview(card: card, thumbnails: model.thumbnails) { [model, id = state.id] path in
                model.copyNewText(path, from: id)
            }
        } else if card.displayType == .color {
            colorView
        }
    }

    /// The text, editable for text, rich text and links (read-only for mixed items).
    private var textEditor: some View {
        TextPane(isEditable: state.isEditable, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular), hasLineNumbers: true) { textView in
            state.attach(textView)
        } onTextChange: {
            state.textDidChange()
        } onSelectionChange: {
            state.selectionDidChange()
        } onFocusChange: { focused in
            state.isEditingText = focused
        }
        .overlay {
            if !state.isLoaded, state.error == nil { ProgressView().controlSize(.small) }
        }
    }

    /// A link: where it leads, large, the page title when the browser gave one, and *Open* (⌘O).
    /// The link itself stays editable below.
    private var linkHeader: some View {
        let address = state.linkText
        let url = URL(string: address)
        let title = details?.linkTitle ?? (card.sourceURL == address ? details?.sourceWindowTitle : nil)
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: url?.host() ?? address)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let title {
                    Text(verbatim: title).font(.callout).lineLimit(2)
                }
                Text(verbatim: address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .controlSize(.large)
            .disabled(url?.scheme == nil)
            .help(String(localized: "Open the link in your browser (⌘O)"))
        }
        .padding(16)
    }

    /// A colour: the swatch and its HEX, RGB and HSL, each copied with one click.
    @ViewBuilder
    private var colorView: some View {
        let values = card.colorHex.flatMap(ColorValues.init(hex:))
        HStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 14)
                .fill(card.colorHex.flatMap(Color.init(hex:)) ?? .clear)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                .frame(width: 160, height: 160)
            if let values {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    colorRow("HEX", values.hex)
                    colorRow("RGB", values.rgb)
                    colorRow("HSL", values.hsl)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colorRow(_ name: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.monospaced()).textSelection(.enabled)
            Button { model.copyNewText(value, from: state.id) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy \(name): it goes to the clipboard and into history"))
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorSection(String(localized: "Title")) {
                    // Saved when the field is left or ↩ is pressed; no Save needed.
                    TextField("Title", text: $state.title, prompt: Text("Shown on the card"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($titleFocused)
                        .onSubmit { model.saveTitle() }
                        .onChange(of: titleFocused) { _, focused in if !focused { model.saveTitle() } }
                        // Tab goes on to the text, the usual next step after naming it.
                        .onKeyPress(.tab) {
                            guard state.hasText else { return .ignored }
                            state.focus()
                            return .handled
                        }
                        .help(String(localized: "Shown on the card and found by search; saved when you leave the field"))
                }
                Divider()
                inspectorSection(String(localized: "Source")) { source }
                Divider()
                inspectorSection(String(localized: "Collections")) { collections }
                if let details {
                    Divider()
                    DisclosureGroup(isExpanded: $showsDetails) {
                        metadata(details).padding(.top, 6)
                    } label: {
                        Text("Details").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .help(String(localized: "When it was copied, how often, its size and formats"))
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

    /// The collections the record is in, each removable, and *Add to Collection* for the others
    /// (first-run feedback: a checkbox for every collection read as a pile).
    private var collections: some View {
        let history = model.history
        let members = history.memberships[state.id] ?? []
        let recordID = state.id
        return VStack(alignment: .leading, spacing: 6) {
            if members.isEmpty {
                Text("In no collection").foregroundStyle(.secondary)
            }
            ForEach(history.collections.filter { members.contains($0.id) }) { collection in
                let collectionID = collection.id
                HStack(spacing: 6) {
                    Label(collection.name, systemImage: "folder").lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        model.setMembership(recordID, collection: collectionID, isMember: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Remove from “\(collection.name)”"))
                }
            }
            if isNamingCollection {
                TextField("New Collection", text: $newCollectionName, prompt: Text("Name of the new collection"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($collectionNameFocused)
                    .onAppear { collectionNameFocused = true }
                    .onSubmit {
                        model.createCollection(named: newCollectionName, adding: recordID)
                        newCollectionName = ""
                        isNamingCollection = false
                    }
                    .onChange(of: collectionNameFocused) { _, focused in
                        if !focused { isNamingCollection = false }
                    }
                    .help(String(localized: "Press Return: the collection is created with this record in it; Esc cancels"))
            } else {
                Menu {
                    ForEach(history.collections) { collection in
                        let collectionID = collection.id
                        Toggle(collection.name, isOn: Binding.main(
                            get: { members.contains(collectionID) },
                            set: { [model] isMember in model.setMembership(recordID, collection: collectionID, isMember: isMember) }
                        ))
                    }
                    if !history.collections.isEmpty { Divider() }
                    Button("New Collection…") { isNamingCollection = true }
                } label: {
                    Label("Add to Collection", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help(String(localized: "Put this record into a collection, or into a new one"))
            }
        }
        .font(.callout)
    }

    /// Syntax highlighting in the status bar, as code editors have it: the language shown, the
    /// choice saved with the record.
    private var languageMenu: some View {
        Menu {
            Picker("Language", selection: $state.language) {
                Text(String(localized: "Automatic (\(state.detectedLanguage?.displayName ?? String(localized: "plain text")))")).tag(LanguageChoice.auto)
                Text("Plain Text").tag(LanguageChoice.plain)
                Divider()
                ForEach(CodeLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(LanguageChoice.language(language))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(state.highlightedLanguage?.displayName ?? String(localized: "Plain Text"))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help(String(localized: "Language for syntax highlighting; Automatic detects code"))
    }

    // MARK: Text in Image

    /// Under the image: what text recognition found, selectable and copyable, in a pane that can be
    /// folded away and made taller by dragging its header (first-run feedback: in the inspector
    /// the text was out of sight).
    private func recognizedTextPane(availableHeight: CGFloat) -> some View {
        let text = details?.recognizedText
        let isOpen = showsRecognizedText && text != nil
        let maxHeight = max(80, availableHeight - 140)
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    showsRecognizedText.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .disabled(text == nil)
                .help(isOpen ? String(localized: "Hide the text") : String(localized: "Show the text"))
                Label("Text in Image", systemImage: "text.viewfinder")
                    .font(.callout.weight(.semibold))
                Text(recognitionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                recognitionActions(text)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .pointerStyle(isOpen ? PointerStyle.rowResize : nil)
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                guard isOpen else { return }
                let start = dragStartHeight ?? recognizedTextHeight
                dragStartHeight = start
                recognizedTextHeight = min(max(start - Double(value.translation.height), 80), Double(maxHeight))
            }.onEnded { _ in dragStartHeight = nil })
            if isOpen, let text {
                Divider()
                TextPane(isEditable: false, font: .systemFont(ofSize: 13)) { textView in
                    state.recognizedText.attach(textView, text: text)
                } onSelectionChange: {
                    state.recognizedText.update()
                }
                .frame(height: min(CGFloat(recognizedTextHeight), maxHeight))
            }
        }
        .background(.bar)
    }

    private var recognitionSummary: String {
        guard let details else { return "" }
        switch details.recognitionState {
        case .done:
            let lines = TextStats.lineCount(details.recognizedText ?? "")
            return lines > 1 ? String(localized: "\(lines) lines") : ""
        case .pending: return String(localized: "Recognizing…")
        case .noText: return String(localized: "No text found")
        case .failed: return String(localized: "Could not be recognized")
        case .off: return String(localized: "Off for this app")
        }
    }

    @ViewBuilder
    private func recognitionActions(_ text: String?) -> some View {
        if let text {
            Button(state.recognizedText.hasSelection ? String(localized: "Copy Selected Text") : String(localized: "Copy All Text")) {
                model.copyNewText(state.recognizedText.selectedOrAll ?? text, from: state.id)
            }
            .help(String(localized: "The text goes to the clipboard and appears in history as a new item"))
        } else if details?.recognitionState == .pending {
            ProgressView().controlSize(.mini)
        } else if details?.recognitionState == .off, let bundleID = card.sourceAppBundleID {
            let name = card.sourceAppName ?? bundleID
            Button("Recognize Text") { model.setRecognition(true, for: bundleID, name: name) }
                .help(String(localized: "Recognize text in images from \(name), on this Mac"))
        }
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
            if state.isDirty {
                Label("Edited", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if state.hasFormatting, !state.isRich, state.isTextDirty {
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
                if let bytes = state.byteCount, state.isNearSizeLimit {
                    Text(String(localized: "\(ByteCount.string(bytes)) of \(ByteCount.string(state.maxBytes))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(state.isOverSizeLimit ? Color.red : Color.orange)
                        .help(String(localized: "Size of the text against the “Largest item” limit (Settings → Apps → All Apps)"))
                }
                Text(stats).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                if card.displayType != .url, !state.isRich { languageMenu }
                viewMenu
            } else if isImage, let width = card.pixelWidth, let height = card.pixelHeight {
                Text(verbatim: "\(width) × \(height) px · \(ByteCount.string(card.payloadSizeBytes))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if state.isDirty {
                Button("Changes…") { showsChanges = true }
                    .help(String(localized: "Compare the edited text with the saved text, line by line"))
                Button("Revert") { state.revert() }
                    .help(String(localized: "Go back to the saved text (⌘Z undoes this)"))
                Button { model.saveItem() } label: { ShortcutLabel(title: String(localized: "Save"), shortcut: "⌘S") }
                    .buttonStyle(.borderedProminent)
                    .disabled(cannotSaveReason != nil)
                    .help(cannotSaveReason ?? String(localized: "Save the changes; the window stays open (⌘S)"))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Why Save is disabled right now; `nil` when it can save.
    private var cannotSaveReason: String? {
        if state.isSaving { return String(localized: "Saving…") }
        if !state.isLoaded { return String(localized: "The text is still loading") }
        if state.characterCount == 0 { return String(localized: "A record can’t be empty: type some text, or Revert") }
        if state.isOverSizeLimit {
            return String(localized: "Larger than the “Largest item” limit (\(ByteCount.string(state.maxBytes)), Settings → Apps → All Apps)")
        }
        return nil
    }

    /// Wrapping, line numbers, invisible characters and text size: how the text is shown, never
    /// what is saved.
    private var viewMenu: some View {
        Menu {
            Toggle("Wrap Lines", isOn: $state.wrapsLines)
            Picker("Line Numbers", selection: $state.lineNumbersPreference) {
                Text("Automatic (for Code)").tag(Bool?.none)
                Text("Always").tag(Bool?.some(true))
                Text("Never").tag(Bool?.some(false))
            }
            .pickerStyle(.menu)
            Toggle("Show Invisible Characters", isOn: $state.showsInvisibles)
            if state.hasRichSource {
                Toggle("Show Formatting", isOn: Binding.main(get: { state.isRich }, set: { [state] on in state.setShowsFormatting(on) }))
                    .disabled(state.isDirty)
                    .help(state.isDirty
                        ? String(localized: "Save or revert your changes first")
                        : String(localized: "Off: edit as plain text; saving then keeps only the text"))
            }
            if !state.isRich {
                Toggle("Monospaced Font", isOn: $state.usesMonospacedFont)
            }
            Divider()
            Button("Larger Text (⌘+)") { state.changeFontSize(by: 1) }
            Button("Smaller Text (⌘−)") { state.changeFontSize(by: -1) }
            Button("Default Text Size (⌘0)") { state.fontSize = ItemState.defaultFontSize }
        } label: {
            Label("View", systemImage: "eye")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help(String(localized: "Wrap lines, line numbers, invisible characters (spaces, tabs, line breaks), font and text size"))
    }

    /// What the keys do right now.
    private var hint: String {
        if state.isDirty {
            return String(localized: "⌘S saves · ⌘↩ saves and selects · Esc asks to save")
        }
        if state.isEditingText {
            return String(localized: "Editing · Esc stops editing")
        }
        if state.isEditable {
            return String(localized: "Click the text to edit · ← → other records · ↩ selects · Esc closes")
        }
        if isImage {
            return String(localized: "⌘+ ⌘− zoom · ⌘0 fit · ← → other records · ↩ selects · Esc closes")
        }
        return String(localized: "← → other records · ↩ selects · Esc closes")
    }

    /// The selection when there is one, else the whole text.
    private var stats: String {
        if state.selectedCharacters > 0 {
            let selected = String(localized: "\(state.selectedCharacters) of \(state.characterCount) characters selected")
            guard state.selectedLines > 1 else { return selected }
            return selected + " · " + String(localized: "\(state.selectedLines) lines")
        }
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
        // Large enough for Actual Size on most screenshots, still bounded in memory (§7.3).
        let loadedImage = await model.previewImage(state.id, maxPixelSize: 4_096)
        guard !Task.isCancelled else { return }
        image = loadedImage
    }
}

/// A file record: the file itself through Quick Look — rendered only while the window shows it —
/// then its path(s), size, *Reveal in Finder* and *Copy Path*. A file that was moved or deleted
/// shows its stored thumbnail.
private struct FilePreview: View {
    let card: HistoryCard
    let thumbnails: ThumbnailCache
    /// The full path as text, to the clipboard and into history.
    let copyPath: @MainActor (String) -> Void
    @State private var image: NSImage?
    @State private var status: ThumbnailCache.FileStatus?
    /// With several files, the one shown.
    @State private var shownPath: String?

    private var previewPath: String? { shownPath ?? card.filePaths.first }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let path = previewPath, FileManager.default.fileExists(atPath: path) {
                    QuickLookView(url: URL(fileURLWithPath: path))
                } else {
                    VStack(spacing: 10) {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                        } else {
                            Image(systemName: "doc").font(.system(size: 48)).foregroundStyle(.secondary)
                        }
                        Text("Unavailable: the file was moved or deleted.").font(.callout).foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if card.filePaths.count > 4 {
                    ScrollView { paths }.frame(maxHeight: 110)
                } else {
                    paths
                }
                HStack(spacing: 8) {
                    if let bytes = status?.totalBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Reveal in Finder") {
                        let urls = card.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                    .disabled(status?.allMissing ?? false)
                    Button(card.filePaths.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path")) {
                        copyPath(card.filePaths.joined(separator: "\n"))
                    }
                    .help(card.filePaths.count > 1
                        ? String(localized: "Copy the full paths, one per line, to the clipboard")
                        : String(localized: "Copy the full path to the clipboard"))
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .task(id: card.id) {
            status = await thumbnails.fileStatus(for: card)
            image = await thumbnails.image(for: card)
        }
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(card.filePaths, id: \.self) { path in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if card.filePaths.count > 1 {
                        Button { shownPath = path } label: {
                            Image(systemName: path == previewPath ? "eye.fill" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Show this file above"))
                    }
                    Text(verbatim: path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if card.filePaths.count > 1 {
                        Spacer(minLength: 4)
                        Button { copyPath(path) } label: { Image(systemName: "doc.on.clipboard") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Copy this path"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// A line-number ruler, shown or hidden later through `scrollView.rulersVisible`.
    var hasLineNumbers = false
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
        // TextKit 1, built explicitly: line numbers and invisible characters are placed with its
        // layout manager, without the switch from TextKit 2 that asking for one would cause.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = FocusReportingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
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
        if hasLineNumbers {
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = LineNumberRuler(textView: textView)
            scrollView.rulersVisible = false
        }
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

/// Line numbers beside the text (§8.5): one per line of text, also when long lines wrap. The line
/// starts are kept up to date on each edit, so drawing only looks at the visible lines.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    /// The text changed while the ruler was hidden: count the lines when it is drawn.
    private var isStale = true

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    @objc private func boundsChanged(_ notification: Notification) {
        needsDisplay = true
    }

    /// After every edit, and when the text is set. Nothing to do while the ruler is hidden.
    func textDidChange() {
        isStale = true
        guard scrollView?.rulersVisible == true else { return }
        countLines()
        needsDisplay = true
    }

    private func countLines() {
        isStale = false
        guard let text = textView?.string as NSString? else { return }
        var starts = [0]
        let length = text.length
        // In blocks rather than a call per character: this runs on every edit while numbers show.
        var buffer = [unichar](repeating: 0, count: 4_096)
        var location = 0
        var afterReturn = false
        while location < length {
            let count = min(buffer.count, length - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for offset in 0..<count {
                switch buffer[offset] {
                case 10:
                    // \r\n is one break: the line starts after the \n.
                    if afterReturn { starts[starts.count - 1] = location + offset + 1 } else { starts.append(location + offset + 1) }
                    afterReturn = false
                case 13:
                    starts.append(location + offset + 1)
                    afterReturn = true
                default:
                    afterReturn = false
                }
            }
            location += count
        }
        lineStarts = starts
        let thickness = CGFloat(max(2, String(starts.count).count)) * 7.5 + 14
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
    }

    /// The last line that starts at or before `location`.
    private func line(containing location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let clip = scrollView?.contentView else { return }
        if isStale { countLines() }
        let visible = clip.bounds
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView.font?.pointSize ?? 12) - 2), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var number = line(containing: characters.location)
        while number < lineStarts.count, lineStarts[number] <= NSMaxRange(characters) {
            let start = lineStarts[number]
            let fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
            } else {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            let label = "\(number + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: top + (fragment.height - size.height) / 2), withAttributes: attributes)
            number += 1
        }
    }
}

/// Tells when it becomes or stops being the first responder, and can show invisible characters.
final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// · for spaces, → for tabs, ° for no-break spaces and ¬ for line breaks (§8.5), drawn over
    /// what is on screen only; nothing is added to the text.
    var showsInvisibles = false {
        didSet { if showsInvisibles != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsInvisibles { drawInvisibles(in: dirtyRect) }
    }

    private func drawInvisibles(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0 else { return }
        let text = storage.string as NSString
        let font = self.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        for index in characters.location..<NSMaxRange(characters) {
            let symbol: String
            switch text.character(at: index) {
            case 0x20: symbol = "·"
            case 0x09: symbol = "→"
            case 0xA0: symbol = "°"
            case 0x0D: symbol = "¬"
            // \r\n shows one mark.
            case 0x0A where index == 0 || text.character(at: index - 1) != 0x0D: symbol = "¬"
            default: continue
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = layoutManager.location(forGlyphAt: glyph)
            let point = NSPoint(x: origin.x + fragment.minX + baseline.x, y: origin.y + fragment.minY + baseline.y - font.ascender)
            (symbol as NSString).draw(at: point, withAttributes: attributes)
        }
    }

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
