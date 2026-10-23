import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

/// One history card (PLAN §8.2): content preview, footer with source app, metric, badges and time.
struct CardView: View {
    let card: HistoryCard
    let index: Int
    let isSelected: Bool
    /// ⌘ is held: show the card's ⌘1…⌘9 shortcut (§8.3).
    let showsShortcut: Bool
    let thumbnails: ThumbnailCache
    @State private var image: NSImage?
    @State private var fileStatus: ThumbnailCache.FileStatus?

    private var isUnavailable: Bool { fileStatus?.allMissing ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = card.customTitle {
                Text(title).font(.headline).lineLimit(1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsShortcut, index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption.monospaced().bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thickMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isUnavailable ? 0.55 : 1)
        .contentShape(Rectangle())
        .help(card.sourceURL.map { String(localized: "Copied from \($0)") } ?? "")
        .task(id: card.id) {
            image = thumbnails.cachedImage(for: card)
            if card.displayType == .file { fileStatus = await thumbnails.fileStatus(for: card) }
            if image == nil, card.hasThumbnail || card.displayType == .file {
                image = await thumbnails.image(for: card)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(SecretDetector.maskedPreview(of: card.preview))
                    .font(.system(size: 13, design: .monospaced))
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
                    .background(Checkerboard().opacity(0.2))
            } else {
                placeholder(card.displayType.systemImage)
            }
        case .color:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(card.colorHex.flatMap(Color.init(hex:)) ?? .clear)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .frame(width: 56, height: 56)
                Text(card.colorHex ?? "").font(.title3.monospaced())
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 64)
                } else {
                    Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                }
                Text(card.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                    .font(.callout)
                    .lineLimit(2)
                if isUnavailable {
                    Text("Unavailable").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
        case .url:
            Text(card.preview)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .lineLimit(6)
        case .text, .richText, .mixed:
            if card.preview.isEmpty {
                placeholder(card.displayType.systemImage)
            } else {
                Text(card.preview)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(8)
            }
        }
    }

    private func placeholder(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.largeTitle)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if let icon = AppInfo.icon(for: card.sourceAppBundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: card.displayType.systemImage).frame(width: 16, height: 16)
            }
            Text(metric).lineLimit(1)
            Spacer(minLength: 2)
            badges
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(RelativeTime.short(card.lastCopiedAt, now: context.date))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var badges: some View {
        if card.isFavorite {
            Image(systemName: "heart.fill").foregroundStyle(.pink).help(String(localized: "Favorite"))
        }
        if card.isEdited {
            Image(systemName: "pencil").help(String(localized: "Edited"))
        }
        if card.hasRecognizedText {
            Text("T").font(.caption.bold()).help(String(localized: "Text found in this image"))
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
        parts.append(card.lastCopiedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: ", ")
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
