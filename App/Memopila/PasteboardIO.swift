import AppKit
import MemopilaCore

/// `NSPasteboard` adapter for `SnapshotReader`. Lives for one read only; items are never kept.
final class GeneralPasteboardSource: PasteboardSource {
    private let pasteboard: NSPasteboard
    private var items: [NSPasteboardItem] = []

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func itemTypes() -> [[PasteboardType]] {
        items = pasteboard.pasteboardItems ?? []
        return items.map { $0.types.map { PasteboardType($0.rawValue) } }
    }

    func data(forItem index: Int, type: PasteboardType) -> Data? {
        guard items.indices.contains(index) else { return nil }
        return items[index].data(forType: NSPasteboard.PasteboardType(type.rawValue))
    }

    func string(forItem index: Int, type: PasteboardType) -> String? {
        guard items.indices.contains(index) else { return nil }
        return items[index].string(forType: NSPasteboard.PasteboardType(type.rawValue))
    }
}

/// Clear → write → confirm (PLAN §3.4). Runs synchronously on the main actor, so no capture tick
/// can interleave between `clearContents()` and publishing the token.
@MainActor
enum PasteboardWriter {
    enum Result {
        /// Confirmed: `ownedCount` may be used as the suppression token.
        case written(ownedCount: Int)
        /// Written, but another change may have happened: no token.
        case unconfirmed
        /// Another app changed the clipboard after `clearContents()`; nothing written.
        case aborted
        case failed
    }

    static func write(_ items: [CanonicalItem], sourceBundleID: String?, to pasteboard: NSPasteboard = .general) -> Result {
        let pasteboardItems = makeItems(items, sourceBundleID: sourceBundleID)
        guard !pasteboardItems.isEmpty else { return .failed }
        let ownedCount = pasteboard.clearContents()
        guard pasteboard.changeCount == ownedCount else { return .aborted }
        guard pasteboard.writeObjects(pasteboardItems) else { return .failed }
        return pasteboard.changeCount == ownedCount ? .written(ownedCount: ownedCount) : .unconfirmed
    }

    /// File lists expand to one item per URL; the item's other representations go on the first of them (§3.3).
    /// The source marker is set exactly once, on the first item (§5).
    static func makeItems(_ items: [CanonicalItem], sourceBundleID: String?) -> [NSPasteboardItem] {
        var result: [NSPasteboardItem] = []
        for item in items {
            var paths: [String] = []
            var others: [CanonicalRepresentation] = []
            for representation in item.representations {
                if case .filePaths(let list) = representation.payload { paths += list } else { others.append(representation) }
            }
            let fileItems = paths.map { path -> NSPasteboardItem in
                let fileItem = NSPasteboardItem()
                fileItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                return fileItem
            }
            let carrier = fileItems.first ?? NSPasteboardItem()
            for representation in others {
                if let data = representation.bytes {
                    carrier.setData(data, forType: NSPasteboard.PasteboardType(representation.type.rawValue))
                }
            }
            result += fileItems.isEmpty ? [carrier] : fileItems
        }
        let validSource = sourceBundleID.flatMap { BundleIdentifier.isValid($0) ? $0 : nil }
        result.first?.setString(validSource ?? "", forType: NSPasteboard.PasteboardType(PasteboardType.source.rawValue))
        return result
    }
}
