import AppKit
import MemopilaCore
import MemopilaServices
import QuickLookThumbnailing

/// One bounded cache for card thumbnails and QuickLook file thumbnails (PLAN §3.3, §7.3).
@MainActor
final class ThumbnailCache {
    static let costLimit = 24 * 1_024 * 1_024

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = ThumbnailCache.costLimit
        return cache
    }()
    private var fileStatus: [UUID: FileStatus] = [:]
    /// Formatted text for cards (§8.2): small, and keyed by content so an edit shows at once.
    private let richPreviews: NSCache<NSString, RichPreview> = {
        let cache = NSCache<NSString, RichPreview>()
        cache.countLimit = 200
        return cache
    }()
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    struct FileStatus: Sendable, Equatable {
        var missing: Int
        var totalBytes: Int64?
        var allMissing: Bool
    }

    func cachedImage(for card: HistoryCard) -> NSImage? {
        cache.object(forKey: key(for: card))
    }

    /// Stored ingest thumbnail for images and PDFs; QuickLook for files.
    func image(for card: HistoryCard) async -> NSImage? {
        let key = key(for: card)
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage?
        if card.hasThumbnail {
            image = (try? await store.thumbnail(for: card.id)).flatMap(NSImage.init(data:))
        } else if card.displayType == .file, let path = card.filePaths.first, FileVolumes.isLocal(path) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            image = await Self.quickLookThumbnail(for: URL(fileURLWithPath: path), scale: scale)?.value
        } else {
            image = nil
        }
        if let image {
            cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
        return image
    }

    /// Existence and total size of a file card's paths, from `stat` off the main actor (§3.3).
    func fileStatus(for card: HistoryCard) async -> FileStatus {
        if let cached = fileStatus[card.id] { return cached }
        let paths = card.filePaths
        // Files on a network volume are not looked at: a share that has gone away blocks for its
        // timeout. Size and existence stay unknown for them.
        let unknown = FileStatus(missing: 0, totalBytes: nil, allMissing: false)
        let status = await FileVolumes.run(timeout: 5) {
            paths.allSatisfy(FileVolumes.isLocal) ? Self.stat(paths) : unknown
        } ?? unknown
        fileStatus[card.id] = status
        return status
    }

    func removeAll() {
        cache.removeAllObjects()
        richPreviews.removeAllObjects()
        fileStatus = [:]
    }

    static func richKey(for card: HistoryCard) -> String {
        "\(card.id.uuidString)|\(card.payloadSizeBytes)|\(card.preview.hashValue)"
    }

    func cachedRichPreview(for card: HistoryCard) -> RichPreview? {
        richPreviews.object(forKey: Self.richKey(for: card) as NSString)
    }

    /// RTF off the main thread; HTML through `HTMLPreview`, never WebKit: a card starts no web
    /// process and loads nothing from the network (the record window reads the HTML with WebKit).
    func richPreview(for card: HistoryCard) async -> RichPreview? {
        let key = Self.richKey(for: card) as NSString
        if let cached = richPreviews.object(forKey: key) { return cached }
        guard let source = try? await store.richPreviewSource(for: card.id) else { return nil }
        let made = await Task.detached(priority: .utility) { () -> Transfer<(start: NSAttributedString, page: RichPage)>? in
            Self.parse(source.data, type: source.type).map { Transfer(value: RichPreview.make(from: $0.text, documentBackground: $0.background)) }
        }.value
        guard let made else { return nil }
        let preview = RichPreview(start: made.value.start, page: made.value.page)
        richPreviews.setObject(preview, forKey: key)
        return preview
    }

    nonisolated private static func parse(_ data: Data, type: PasteboardType) -> (text: NSAttributedString, background: NSColor?)? {
        if type == .html {
            let preview = HTMLPreview.preview(of: String(decoding: data, as: UTF8.self), maxCharacters: RichPreview.characters)
            return (attributed(preview), preview.pageBackground.map(nsColor))
        }
        var attributes: NSDictionary?
        let documentType: NSAttributedString.DocumentType = type == .flatRTFD ? .rtfd : .rtf
        guard let text = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: &attributes) else { return nil }
        let background = (attributes as? [NSAttributedString.DocumentAttributeKey: Any])?[.backgroundColor] as? NSColor
        return (text, background)
    }

    nonisolated private static func attributed(_ preview: HTMLPreview.Preview) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in preview.runs {
            let style = run.style
            let size = CGFloat(style.size)
            let weight: NSFont.Weight = style.bold ? .bold : .regular
            var font = style.monospace ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            if style.italic, let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) { font = italic }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let color = style.color { attributes[.foregroundColor] = nsColor(color) }
            if let background = style.background { attributes[.backgroundColor] = nsColor(background) }
            if style.link { attributes[.link] = style.href ?? "preview" }
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    nonisolated private static func nsColor(_ color: HTMLPreview.Color) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    func invalidate(_ id: UUID) {
        fileStatus[id] = nil
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    private func key(for card: HistoryCard) -> NSString {
        card.id.uuidString as NSString
    }

    private static func cost(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 1 }
        return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
    }

    nonisolated private static func stat(_ paths: [String]) -> FileStatus {
        var missing = 0
        var total: Int64 = 0
        var sized = true
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                missing += 1
                continue
            }
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                sized = false
            } else if let size = attributes[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return FileStatus(missing: missing, totalBytes: sized && missing == 0 ? total : nil, allMissing: missing == paths.count)
    }

    /// Nonisolated: QuickLook calls back on its own queue.
    nonisolated private static func quickLookThumbnail(for url: URL, scale: CGFloat) async -> Transfer<NSImage>? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 180),
            scale: scale,
            representationTypes: .all
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation.map { Transfer(value: $0.nsImage) })
            }
        }
    }
}
