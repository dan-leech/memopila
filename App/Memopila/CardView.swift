import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

/// One history card (PLAN §8.2): content, footer with source app, metric, badges and time.
/// Hovering shows quick controls (favorite, preview, menu); a title sits in its own tinted strip so
/// it never reads as clipboard content.
struct CardView: View {
    let card: HistoryCard
    let index: Int
    /// The selection (↑ ↓ ← →, a click): where ↩ and the shortcuts act; the usual accent border.
    let hasCursor: Bool
    let model: AppModel
    @State private var image: NSImage?
    @State private var richPreview: RichPreview?
    @Environment(\.colorScheme) private var colorScheme
    @State private var fileStatus: ThumbnailCache.FileStatus?
    @State private var isHovered = false

    private static let radius: CGFloat = 9

    private var thumbnails: ThumbnailCache { model.thumbnails }
    private var isUnavailable: Bool { fileStatus?.allMissing ?? false }
    private var isMedia: Bool { secretKind == nil && (card.displayType == .image || card.displayType == .pdf) }
    /// The clipboard holds this record now (§8.2): a thin green line drawn over the inner side of the
    /// selection border (blue outside, green next to the content), or at the edge without it. Selecting another record changes it; no card
    /// has it when the clipboard holds something that is not in history.
    private var isOnClipboard: Bool { model.monitor.clipboardRecordID == card.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = card.customTitle { titleStrip(title) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .padding(.horizontal, isMedia ? 6 : 10)
                .padding(.top, isMedia ? 6 : 9)
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))

        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(
                    hasCursor ? Color.accentColor : Color.primary.opacity(isHovered ? 0.2 : 0.08),
                    lineWidth: hasCursor ? 3 : 1
                )
        }
        .overlay {
            if isOnClipboard {
                // Drawn second, over the inner point of the 3 pt selection border.
                let inset: CGFloat = hasCursor ? 2 : 0
                RoundedRectangle(cornerRadius: Self.radius - inset, style: .continuous)
                    .strokeBorder(Color.green, lineWidth: 1)
                    .padding(inset)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { cornerControls }
        .overlay {
            if model.chooseBadgeCardID == card.id {
                ChooseBadge(pasted: model.chooseBadgeWasPasted).transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .opacity(isUnavailable ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.chooseBadgeCardID)
        .help(card.sourceURL.map { String(localized: "Copied from \($0)") } ?? "")
        // Formatted text shows formatted, as in the record window (owner feedback).
        .task(id: card.displayType == .richText && secretKind == nil ? ThumbnailCache.richKey(for: card) : "") {
            guard card.displayType == .richText, secretKind == nil else { return richPreview = nil }
            if let cached = thumbnails.cachedRichPreview(for: card) {
                richPreview = cached
            } else {
                richPreview = await thumbnails.richPreview(for: card)
            }
        }
        .task(id: card.id) {
            image = thumbnails.cachedImage(for: card)
            if card.displayType == .file { fileStatus = await thumbnails.fileStatus(for: card) }
            if image == nil, card.hasThumbnail || card.displayType == .file {
                image = await thumbnails.image(for: card)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(hasCursor ? [.isButton, .isSelected] : .isButton)
    }

    private func titleStrip(_ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "tag.fill").font(.system(size: 9, weight: .semibold))
            Text(highlighted(title)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
    }

    /// ⌘1…⌘9 while ⌘ is held. (The hover actions sit in the footer, so they never cover the content.)
    @ViewBuilder
    private var cornerControls: some View {
        if model.isCommandHeld, index < 9 {
            Text("⌘\(index + 1)")
                .font(.caption.monospaced().bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thickMaterial, in: Capsule())
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    /// Favorite, Edit Record and the menu, in the footer while the pointer is over the card.
    private var hoverActions: some View {
        HStack(spacing: 0) {
            CardIconButton(
                systemImage: card.isFavorite ? "heart.fill" : "heart",
                tint: card.isFavorite ? .pink : .secondary,
                help: card.isFavorite ? String(localized: "Remove from Favorites (⌘D)") : String(localized: "Add to Favorites (⌘D)")
            ) { model.toggleFavorite(card.id) }
            .symbolEffect(.bounce, value: card.isFavorite)
            CardIconButton(systemImage: "pencil", help: String(localized: "Edit Record (Space or ⌘E)")) {
                model.openRecord(card.id)
            }
            Menu {
                CardContextMenu(card: card, model: model)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 16)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(String(localized: "More"))
        }
        .transition(.opacity)
    }

    /// A credential (§3.10): the card shows its kind and first characters only.
    private var secretKind: SecretKind? {
        card.sensitiveKind.flatMap(SecretKind.init(rawValue:))
    }

    @ViewBuilder
    private var content: some View {
        if let secretKind {
            VStack(alignment: .leading, spacing: 6) {
                Label(secretKind.cardTitle, systemImage: "key.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(SecretDetector.maskedPreview(of: card.preview))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            unmaskedContent
        }
    }

    @ViewBuilder
    private var unmaskedContent: some View {
        switch card.displayType {
        case .image, .pdf:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Checkerboard().opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                placeholder(card.displayType.systemImage)
            }
        case .color:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(card.colorHex.flatMap(Color.init(hex:)) ?? .clear)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .frame(width: 40, height: 40)
                Text(card.colorHex ?? "").font(.system(size: 13, design: .monospaced))
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 48)
                } else {
                    Image(systemName: "doc").font(.title).foregroundStyle(.secondary)
                }
                Text(card.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                if isUnavailable {
                    Text("Unavailable").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
        case .url:
            Text(highlighted(card.preview))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .linkColor))
                .lineLimit(6)
        case .richText where richPreview.map({ $0.text.length > 0 }) ?? false:
            if let richPreview { formatted(richPreview) }
        case .text, .richText, .mixed:
            if card.preview.isEmpty {
                placeholder(card.displayType.systemImage)
            } else {
                Text(highlighted(card.preview))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(8)
            }
        }
    }

    /// On the page the record window shows it on: the copy's own background, a dark page for light
    /// text, else the card's, with the colours inverted in Dark Mode (§8.5).
    private func formatted(_ preview: RichPreview) -> some View {
        let page = preview.page.color
        return Text(mark(preview.cardText(dark: colorScheme == .dark)))
            .lineLimit(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(page == nil ? 0 : 6)
            .background {
                if let page {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: page))
                }
            }
    }

    private func placeholder(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.largeTitle)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Source app, size or where a search matched, badges, time. Narrow cards drop the size first,
    /// then the collection name; on hover the actions take the right side.
    private var footer: some View {
        HStack(spacing: 5) {
            if let icon = AppInfo.icon(for: card.sourceAppBundleID) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            } else {
                Image(systemName: card.displayType.systemImage).frame(width: 14, height: 14)
            }
            if isHovered, !model.isCommandHeld {
                info
                Spacer(minLength: 2)
                hoverActions
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { info; Spacer(minLength: 2); badges(namingCollections: true); time }
                    HStack(spacing: 5) { Spacer(minLength: 2); badges(namingCollections: true); time }
                    HStack(spacing: 5) { Spacer(minLength: 2); badges(namingCollections: false); time }
                }
            }
        }
        .frame(height: 16)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    /// The size, or where a search matched when the card does not show it.
    @ViewBuilder
    private var info: some View {
        if let matchNote {
            Label(matchNote, systemImage: "magnifyingglass")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        } else {
            Text(metric).lineLimit(1)
        }
    }

    private var time: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(RelativeTime.short(card.lastCopiedAt, now: context.date))
        }
    }

    private var searchWords: [String] {
        model.history.search.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The search matched this card outside what it shows: in the app name, the page, a file name,
    /// the text found in an image or further down the text (first-run feedback).
    private var matchNote: String? {
        let words = searchWords
        guard !words.isEmpty else { return nil }
        let shown = card.preview + " " + (card.customTitle ?? "")
        let hidden = words.filter { !shown.localizedStandardContains($0) }
        guard !hidden.isEmpty else { return nil }
        func matches(_ text: String?) -> Bool {
            guard let text else { return false }
            return hidden.allSatisfy { text.localizedStandardContains($0) }
        }
        if matches(card.sourceAppName) { return String(localized: "Found in the app name") }
        if matches(card.sourceURL) { return String(localized: "Found in the page address") }
        if matches(card.filePaths.joined(separator: " ")) { return String(localized: "Found in the file name") }
        if card.hasRecognizedText { return String(localized: "Found in the text in the image") }
        return String(localized: "Found further in the text")
    }

    /// The search words marked in the text the card shows.
    private func highlighted(_ text: String) -> AttributedString {
        mark(AttributedString(text))
    }

    private func mark(_ base: AttributedString) -> AttributedString {
        guard !searchWords.isEmpty else { return base }
        var result = base
        let text = String(base.characters)
        for word in searchWords {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let marked = Range(range, in: result) {
                    result[marked].backgroundColor = Color.yellow.opacity(0.45)
                }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return result
    }

    /// The collections this card is in, by name (first-run feedback: membership was visible only
    /// from inside each collection).
    private var collectionNames: [String] { model.history.collectionNames(of: card.id) }

    @ViewBuilder
    private func collectionsBadge(naming: Bool) -> some View {
        let names = collectionNames
        if let first = names.first {
            HStack(spacing: 2) {
                Image(systemName: "folder.fill")
                if naming {
                    Text(names.count > 1 ? "\(first) +\(names.count - 1)" : first).lineLimit(1)
                } else if names.count > 1 {
                    Text("\(names.count)")
                }
            }
            .frame(maxWidth: 90, alignment: .leading)
            .fixedSize()
            .help(String(localized: "In collections: \(names.joined(separator: ", "))"))
        }
    }

    @ViewBuilder
    private func badges(namingCollections: Bool) -> some View {
        collectionsBadge(naming: namingCollections)
        if card.isFavorite {
            Image(systemName: "heart.fill").foregroundStyle(.pink).help(String(localized: "Favorite"))
        }
        if card.isEdited {
            Image(systemName: "pencil").help(String(localized: "Edited"))
        }
        if card.hasRecognizedText {
            Image(systemName: "text.viewfinder").help(String(localized: "Text found in this image"))
        }
        if let expires = card.expiresAt, expires.timeIntervalSinceNow < 3_600 {
            Image(systemName: "clock").help(String(localized: "Deleted \(expires.formatted(.relative(presentation: .named)))"))
        }
    }

    private var metric: String {
        switch card.displayType {
        case .text, .richText, .url, .mixed:
            guard let length = card.textLength else { return ByteCount.string(card.payloadSizeBytes) }
            let characters = String(localized: "\(length) characters")
            if let lines = card.lineCount, lines > 1 { return String(localized: "\(lines) lines") + ", " + characters }
            return characters
        case .image:
            if let width = card.pixelWidth, let height = card.pixelHeight { return "\(width) × \(height) px" }
            return ByteCount.string(card.payloadSizeBytes)
        case .pdf:
            return "PDF · " + ByteCount.string(card.payloadSizeBytes)
        case .color:
            return card.colorHex ?? String(localized: "Color")
        case .file:
            let count = card.filePaths.count
            let files = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
            if let bytes = fileStatus?.totalBytes { return files + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return files
        }
    }

    private var accessibilityText: String {
        var parts = [card.displayType.title]
        if let title = card.customTitle { parts.append(title) }
        if let secretKind {
            parts.append(secretKind.cardTitle)
        } else if !card.preview.isEmpty {
            parts.append(String(card.preview.prefix(120)))
        }
        if card.displayType == .file { parts.append(card.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")) }
        parts.append(metric)
        if let name = card.sourceAppName { parts.append(String(localized: "from \(name)")) }
        if card.isFavorite { parts.append(String(localized: "Favorite")) }
        let collections = collectionNames
        if !collections.isEmpty { parts.append(String(localized: "In collections: \(collections.joined(separator: ", "))")) }
        if isOnClipboard { parts.append(String(localized: "In Clipboard")) }
        parts.append(card.lastCopiedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: ", ")
    }
}


private struct CardIconButton: View {
    let systemImage: String
    var tint: Color = .secondary
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Shown on a card for a moment after Choose for Clipboard while the window is pinned.
private struct ChooseBadge: View {
    let pasted: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.green)
            Text(pasted ? String(localized: "Pasted") : String(localized: "On Clipboard")).font(.caption.bold())
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

/// Red *Current — not saved* card (§3.2.3). Content is never shown for skipped changes; this card
/// only appears for oversize, unsupported, failed reads and failed or refused saves.
struct CurrentCardView: View {
    let current: CurrentClipboard
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Current — not saved", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(current.title).font(.callout).lineLimit(2)
            HStack(alignment: .top, spacing: 8) {
                if let data = current.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let bundleID = current.change.identity.bundleID {
                        Text(AppInfo.displayName(for: bundleID)).font(.caption)
                    }
                    Text(current.change.declaredTypes.map(\.rawValue).joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if current.change.knownBytes > 0 {
                        Text(String(localized: "At least \(ByteCount.string(current.change.knownBytes))"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if current.allowsSaveAnyway {
                    Button("Save Anyway") { model.monitor.saveCurrentAnyway() }
                        .disabled(model.monitor.isSavingAnyway || model.monitor.isBusy)
                }
                Menu {
                    ActionMenuItems(items: ActionRegistry.currentCardActions(current, model: model))
                } label: {
                    Text(current.change.identity.bundleID.map { AppInfo.displayName(for: $0) } ?? String(localized: "App"))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(current.change.identity.bundleID == nil)
                Spacer()
                Button("Dismiss") { model.monitor.dismissCurrent() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.red.opacity(0.6), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Current clipboard, not saved: \(current.title)"))
    }
}

/// A password on the clipboard (§3.2.3): a card with a red line where a saved card has the green
/// one, never its content (it is never read). It cannot be selected or opened; the only action
/// clears the clipboard (owner feedback: the panel looked as if the clipboard were empty).
struct ConcealedCardView: View {
    let current: CurrentClipboard
    let model: AppModel
    @State private var isHovered = false

    private static let radius: CGFloat = 9

    private var appName: String? {
        current.change.identity.bundleID.map { AppInfo.displayName(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(current.title, systemImage: "key.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.red)
                Text(verbatim: "••••••••••")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Not saved and not shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.top, 9)
            HStack(spacing: 5) {
                if let icon = AppInfo.icon(for: current.change.identity.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "key").frame(width: 14, height: 14)
                }
                if let appName { Text(appName).lineLimit(1) }
                Spacer(minLength: 2)
                if isHovered {
                    Button { model.monitor.clearConcealed() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Clear Clipboard: remove the password from the clipboard"))
                    .accessibilityLabel(Text("Clear Clipboard"))
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(RelativeTime.short(current.observedAt, now: context.date))
                    }
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.red, lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Clear Clipboard") { model.monitor.clearConcealed() }
        }
        .help(String(localized: "A password is on the clipboard. Memopila never reads, saves or shows it."))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Password on the clipboard, not saved"))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// *Now*, *2m*, *3h*, *4d* (§8.2).
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return String(localized: "Now")
        case ..<3_600: return String(localized: "\(seconds / 60)m")
        case ..<86_400: return String(localized: "\(seconds / 3_600)h")
        default: return String(localized: "\(seconds / 86_400)d")
        }
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
