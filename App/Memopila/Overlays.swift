import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

// MARK: - Preview (§8.5)

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

struct PreviewOverlay: View {
    let model: AppModel
    let id: UUID
    @State private var details: RecordDetails?
    @State private var styledText: NSAttributedString?
    @State private var image: NSImage?
    @State private var choice: LanguageChoice = .auto
    @State private var detected: CodeLanguage?
    @State private var isLoading = true
    /// The choice that came from the store, so loading it does not save it back.
    @State private var loadedChoice: LanguageChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let details { metadata(details) }
        }
        .padding(16)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .task(id: id) { await load() }
    }

    private var card: HistoryCard? { details?.card }

    private var header: some View {
        HStack(spacing: 10) {
            if let card {
                if let icon = AppInfo.icon(for: card.sourceAppBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.customTitle ?? card.displayType.title).font(.headline).lineLimit(1)
                    sourceLine(card)
                }
            }
            Spacer()
            if details?.text != nil, card?.displayType != .url {
                Picker("Language", selection: $choice) {
                    Text(String(localized: "Automatic (\(detected?.displayName ?? String(localized: "plain text")))")).tag(LanguageChoice.auto)
                    Text("Plain Text").tag(LanguageChoice.plain)
                    Divider()
                    ForEach(CodeLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(LanguageChoice.language(language))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: choice) { _, value in
                    guard value != loadedChoice else { return }
                    loadedChoice = value
                    model.setCodeLanguage(id, value.stored)
                    Task { await restyle() }
                }
            }
            Button("Copy") { model.restore(id) }
            Button {
                model.present(nil)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Close preview"))
        }
    }

    @ViewBuilder
    private func sourceLine(_ card: HistoryCard) -> some View {
        if let url = card.sourceURL, let link = URL(string: url) {
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    // ⌥-click copies the URL; the token keeps it out of history (§3.4).
                    _ = model.monitor.write(PasteboardWriter.plainTextItems(url), sourceBundleID: nil)
                    model.toasts.show(String(localized: "Link copied"))
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

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if let details {
            switch details.card.displayType {
            case .image, .pdf:
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: details.card.displayType.systemImage).font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Checkerboard().opacity(0.15))
                    if let text = details.recognizedText {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Text in Image").font(.subheadline.bold())
                            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            Button("Copy Text") { model.restore(id, variant: .recognizedText) }
                        }
                        .frame(width: 220)
                    }
                }
            case .color:
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(details.card.colorHex.flatMap(Color.init(hex:)) ?? .clear)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                        .frame(width: 140, height: 140)
                    Text(details.card.colorHex ?? "").font(.title.monospaced()).textSelection(.enabled)
                }
            case .file:
                FilePreview(card: details.card, thumbnails: model.thumbnails)
            case .text, .richText, .url, .mixed:
                if let styledText {
                    StyledTextView(text: styledText)
                } else {
                    Text("No preview available.").foregroundStyle(.secondary)
                }
            }
        } else {
            Text("The item no longer exists.").foregroundStyle(.secondary)
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

    private func load() async {
        isLoading = true
        styledText = nil
        image = nil
        details = await model.details(id)
        guard let details else {
            isLoading = false
            return
        }
        let stored = LanguageChoice(stored: details.card.codeLanguage)
        loadedChoice = stored
        choice = stored
        switch details.card.displayType {
        case .image, .pdf:
            isLoading = false
            image = await model.previewImage(id, maxPixelSize: 1_600)
        default:
            await restyle()
            isLoading = false
        }
    }

    /// Tokenizes off the main actor; the highlighter holds nothing after the view goes away (§7.3).
    private func restyle() async {
        guard let details, let text = details.text else { return }
        let autoDetected = details.card.displayType == .url ? nil : CodeHighlighter.detect(text, sourceBundleID: details.card.sourceAppBundleID)
        detected = autoDetected
        let language: CodeLanguage? = switch choice {
        case .auto: autoDetected
        case .plain: nil
        case .language(let language): language
        }
        let ranges = await CodeStyler.ranges(text, language: language)
        styledText = CodeStyler.attributed(text, ranges: ranges)
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

/// Read-only, selectable text with highlighting; `NSTextView` handles 20 000 scalars smoothly.
struct StyledTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 4, height: 4)
        }
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.textStorage?.isEqual(to: text) != true else { return }
        textView.textStorage?.setAttributedString(text)
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

    @MainActor
    static func attributed(_ text: String, ranges: [StyledRange]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        let length = result.length
        for range in ranges where range.location + range.length <= length {
            result.addAttribute(.foregroundColor, value: color(for: range.kind), range: NSRange(location: range.location, length: range.length))
        }
        return result
    }

    /// System colors adapt to light and dark appearance.
    @MainActor
    private static func color(for kind: CodeToken.Kind) -> NSColor {
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

// MARK: - Editor (§3.6)

struct EditorOverlay: View {
    let model: AppModel
    let state: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edit Text").font(.headline)
                Spacer()
                Menu("Text") {
                    ForEach(TextAction.allCases, id: \.self) { action in
                        Button(action.title) { state.apply(action) }
                    }
                }
                .fixedSize()
                .help(String(localized: "Applies to the selection, or to all text when nothing is selected"))
            }
            if state.hasFormatting {
                Label("Formatting will be removed when you save.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            PlainTextEditor(state: state)
                .frame(minHeight: 200)
                .overlay {
                    if !state.isLoaded { ProgressView().controlSize(.small) }
                }
            if let error = state.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Text("⌘S Save · ⌘↩ Save & Copy · Esc Cancel").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.present(nil) }
                Button("Save") { model.saveEditor(thenCopy: false) }
                    .disabled(!state.isLoaded || state.isSaving)
                Button("Save & Copy") { model.saveEditor(thenCopy: true) }
                    .disabled(!state.isLoaded || state.isSaving)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }
}

/// Plain `NSTextView` with its own undo stack (§3.6).
struct PlainTextEditor: NSViewRepresentable {
    let state: EditorState

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        if state.isLoaded { textView.string = state.initialText }
        state.textView = textView
        let state = state
        Task { @MainActor in state.focus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
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
