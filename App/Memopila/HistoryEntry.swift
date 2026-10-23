import AppKit
import ImageIO
import MemopilaCore

/// One history card. Phase 1 shell keeps the owned snapshot in memory (bounded by `HistoryLimits`).
struct HistoryEntry: Identifiable {
    let id = UUID()
    let snapshot: OwnedSnapshot
    var metadata: RecordMetadata
    let previewText: String?
    let searchText: String
    let thumbnail: NSImage?
    let pixelSize: CGSize?

    @MainActor
    init(snapshot: OwnedSnapshot, metadata: RecordMetadata) {
        self.snapshot = snapshot
        self.metadata = metadata
        let text = TextDecoding.plainText(of: snapshot.items)
        previewText = text.map { TextDecoding.prefix($0, maxScalars: 300) }
        let files = snapshot.items.flatMap(\.representations).compactMap { representation -> [String]? in
            if case .filePaths(let paths) = representation.payload { return paths }
            return nil
        }.joined()
        let appName = snapshot.identity.bundleID.flatMap(AppInfo.name(for:)) ?? ""
        searchText = [text.map { TextDecoding.prefix($0, maxScalars: 10_000) }, files.joined(separator: "\n"), appName, snapshot.sourceURL]
            .compactMap { $0 }
            .joined(separator: "\n")
        let image = Thumbnail.make(from: snapshot.items)
        thumbnail = image?.image
        pixelSize = image?.pixelSize
    }

    var filePaths: [String] {
        snapshot.items.flatMap(\.representations).flatMap { representation -> [String] in
            if case .filePaths(let paths) = representation.payload { return paths }
            return []
        }
    }

    /// Copy as plain text (§3.4).
    var plainTextItems: [CanonicalItem]? {
        TextDecoding.plainText(of: snapshot.items).map { [CanonicalItem([.bytes(.utf8PlainText, Data($0.utf8))])] }
    }

    var metric: String {
        switch snapshot.displayType {
        case .image, .pdf:
            if let pixelSize { return "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px" }
            return ByteCountFormatter.string(fromByteCount: Int64(snapshot.payloadSizeBytes), countStyle: .file)
        case .file:
            let count = filePaths.count
            return count == 1 ? URL(fileURLWithPath: filePaths[0]).lastPathComponent : "\(count) files"
        default:
            guard let previewText else {
                return ByteCountFormatter.string(fromByteCount: Int64(snapshot.payloadSizeBytes), countStyle: .file)
            }
            let count = TextDecoding.plainText(of: snapshot.items)?.count ?? previewText.count
            return "\(count) characters"
        }
    }
}

/// Downsampled thumbnails through ImageIO: full-size images are never decoded for cards (§7.3).
enum Thumbnail {
    static let maxPixelSize = 512

    static func make(from items: [CanonicalItem]) -> (image: NSImage, pixelSize: CGSize)? {
        let imageTypes: Set<PasteboardType> = Set(PasteboardType.rasterImagePreference).union([.pdf])
        guard let data = items.lazy.flatMap(\.representations).first(where: { imageTypes.contains($0.type) })?.bytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? thumbnail.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? thumbnail.height
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        return (image, CGSize(width: width, height: height))
    }
}

/// App names and icons for source bundle IDs.
@MainActor
enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(for bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}
