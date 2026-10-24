import AppKit
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
        } else if card.displayType == .file, let path = card.filePaths.first {
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
        let status = await Task.detached(priority: .utility) { Self.stat(paths) }.value
        fileStatus[card.id] = status
        return status
    }

    func removeAll() {
        cache.removeAllObjects()
        fileStatus = [:]
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
