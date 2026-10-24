import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

// MARK: - Item view (§8.5, §3.6)

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

/// One view to look at an item and to edit it (first-run feedback: preview and editor were two
/// screens for nearly the same thing). Text, rich text and links are edited in place, with code
/// highlighted as you type; images show the text found in them; files and colours show what they
/// are. The title, the source and the details are part of the same view.
struct ItemOverlay: View {
    let model: AppModel
    @Bindable var state: ItemState
    @State private var details: RecordDetails?
    @State private var image: NSImage?
    @State private var showsDetails = false
    @State private var recognizedText = TextSelection()

    private var card: HistoryCard { details?.card ?? state.card }

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.hasText, state.isEditable { toolbar }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsDetails, let details {
                Divider()
                metadata(details)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
        .task(id: state.id) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = AppInfo.icon(for: card.sourceAppBundleID) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: card.displayType.systemImage).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Add a title", text: $state.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .help(String(localized: "A title is shown on the card and found by search"))
                sourceLine
            }
            Spacer(minLength: 8)
            if state.hasText, card.displayType != .url { languagePicker }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsDetails.toggle() }
            } label: {
                Image(systemName: showsDetails ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Details: when it was copied, size, formats"))
            .accessibilityLabel(Text("Details"))
            Button("Copy to Clipboard") { model.copyItem() }
                .help(state.isDirty
                    ? String(localized: "Save the changes, put the item on the clipboard and go back to the app you were in (⌘↩)")
                    : String(localized: "Put the item on the clipboard and go back to the app you were in (↩)"))
            Button {
                model.dismissOverlay()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Close (Esc)"))
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
        .fixedSize()
        .help(String(localized: "Language for syntax highlighting"))
        .onChange(of: state.language) { _, value in model.setCodeLanguage(state.id, value.stored) }
    }

    @ViewBuilder
    private var sourceLine: some View {
        if let url = card.sourceURL, let link = URL(string: url) {
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    model.copyNewText(url, from: state.id)
                } else {
                    NSWorkspace.shared.open(link)
                }
            } label: {
                Text(String(localized: "Copied from \(link.host() ?? url)"))
                    .font(.caption)
                    .underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(String(localized: "Click to open, Option-click to copy the link"))
        } else if let title = details?.sourceWindowTitle {
            Text(String(localized: "Copied from “\(title)”")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let name = card.sourceAppName {
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Toolbar (editable text)

    private var toolbar: some View {
        HStack(spacing: 2) {
            ToolbarIcon(systemImage: "arrow.uturn.backward", help: String(localized: "Undo (⌘Z)")) { state.undo() }
            ToolbarIcon(systemImage: "arrow.uturn.forward", help: String(localized: "Redo (⇧⌘Z)")) { state.redo() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            actionMenu(systemImage: "textformat.size", help: String(localized: "Change Case"), actions: [.uppercase, .lowercase, .titleCase])
            actionMenu(
                systemImage: "line.3.horizontal.decrease",
                help: String(localized: "Lines and Spaces"),
                actions: [.trimWhitespace, .removeLineBreaks, .sortLines, .removeDuplicateLines]
            )
            actionMenu(systemImage: "curlybraces", help: String(localized: "JSON"), actions: [.formatJSON, .minifyJSON])
            actionMenu(
                systemImage: "chevron.left.forwardslash.chevron.right",
                help: String(localized: "Encode and Decode"),
                actions: [.urlEncode, .urlDecode, .base64Encode, .base64Decode]
            )
            Spacer()
            ToolbarIcon(systemImage: "magnifyingglass", help: String(localized: "Find in the text (⌘F)")) { state.showFind() }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Text actions on the selection, or on all text when nothing is selected (§3.9).
    private func actionMenu(systemImage: String, help: String, actions: [TextAction]) -> some View {
        Menu {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { state.apply(action) }
            }
        } label: {
            Image(systemName: systemImage).frame(width: 26, height: 22)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .help(help + " — " + String(localized: "applies to the selection, or to all text"))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.hasText {
            TextPane(isEditable: state.isEditable, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular)) { textView in
                state.attach(textView)
            } onTextChange: {
                state.textDidChange()
            }
            .overlay {
                if !state.isLoaded, state.error == nil { ProgressView().controlSize(.small) }
            }
        } else {
            Group {
                switch card.displayType {
                case .image, .pdf: imageContent
                case .color: colorContent
                case .file: FilePreview(card: card, thumbnails: model.thumbnails)
                case .text, .richText, .url, .mixed: EmptyView()
                }
            }
            .padding(16)
        }
    }

    private var imageContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: card.displayType.systemImage).font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Checkerboard().opacity(0.15))
            if let text = details?.recognizedText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text in Image").font(.subheadline.bold())
                    TextPane(isEditable: false, font: .systemFont(ofSize: 12)) { textView in
                        recognizedText.attach(textView, text: text)
                    } onSelectionChange: {
                        recognizedText.update()
                    }
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    Button(recognizedText.hasSelection ? String(localized: "Copy Selected Text") : String(localized: "Copy All Text")) {
                        model.copyNewText(recognizedText.selectedOrAll ?? text, from: state.id)
                    }
                    .help(String(localized: "The text goes to the clipboard and appears in history as a new item"))
                }
                .frame(width: 240)
            }
        }
    }

    private var colorContent: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(card.colorHex.flatMap(Color.init(hex:)) ?? .clear)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                .frame(width: 140, height: 140)
            Text(card.colorHex ?? "").font(.title.monospaced()).textSelection(.enabled)
        }
    }

    private func metadata(_ details: RecordDetails) -> some View {
        let card = details.card
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                Text("First copied").foregroundStyle(.secondary)
                Text(card.firstCopiedAt.formatted(date: .abbreviated, time: .shortened))
                Text("Copies").foregroundStyle(.secondary)
                Text("\(card.copyCount)")
            }
            GridRow {
                Text("Last copied").foregroundStyle(.secondary)
                Text(card.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                Text("Size").foregroundStyle(.secondary)
                Text(ByteCount.string(card.payloadSizeBytes))
            }
            GridRow {
                Text("Formats").foregroundStyle(.secondary)
                Text(details.storedTypes.joined(separator: ", ")).lineLimit(2).gridCellColumns(3)
            }
            if !card.skippedTypes.isEmpty {
                GridRow {
                    Text("Skipped").foregroundStyle(.secondary)
                    Text(card.skippedTypes.joined(separator: ", ")).lineLimit(2).gridCellColumns(3)
                }
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if state.hasText {
                Text(stats)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Toggle("Wrap lines", isOn: $state.wrapsLines)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(String(localized: "Break long lines at the window edge instead of scrolling sideways"))
            }
            if state.isDirty {
                Label("Edited", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            if state.hasFormatting, state.isTextDirty {
                Label("Formatting will be removed", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(String(localized: "This item has rich text; saving keeps the plain text only."))
            }
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if state.isConfirmingDiscard {
                Text("Discard your changes?").font(.callout)
                Button("Keep Editing") { state.isConfirmingDiscard = false }
                Button("Discard", role: .destructive) { model.present(nil) }
            } else if state.isDirty {
                Button("Revert") { state.revert() }
                    .help(String(localized: "Go back to the saved text and title"))
                Button { model.saveItem() } label: { ShortcutLabel(title: String(localized: "Save"), shortcut: "⌘S") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isSaving || (state.hasText && !state.isLoaded))
                    .help(String(localized: "Save the changes"))
            } else if state.isEditable {
                Text("Click in the text to edit it").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var stats: String {
        let characters = String(localized: "\(state.characterCount) characters")
        guard state.lineCount > 1 else { return characters }
        return String(localized: "\(state.lineCount) lines") + " · " + characters
    }

    private func load() async {
        // The text comes through `ItemState`; this is the source, the details and the image.
        let loaded = await model.details(state.id, maxTextScalars: 0)
        // `.task(id:)` cancels a load for an item the user already moved past; never let it overwrite.
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

/// `NSTextView` for the item view: editable plain text with its own undo stack and the system find
/// bar, or read-only selectable text (the text found in an image).
struct TextPane: NSViewRepresentable {
    let isEditable: Bool
    let font: NSFont
    let onAttach: @MainActor (NSTextView) -> Void
    var onTextChange: @MainActor () -> Void = {}
    var onSelectionChange: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
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
        context.coordinator.pane = self
        textView.delegate = context.coordinator
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
