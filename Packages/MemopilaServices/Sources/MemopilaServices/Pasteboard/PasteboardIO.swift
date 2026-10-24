import AppKit
import MemopilaCore
import MPLObjCSupport

/// `NSPasteboard` adapter for `SnapshotReader`. Lives for one read only; items are never kept (§3.2).
/// Reads go through the Objective-C boundary, so a raised pasteboard exception becomes a read failure.
public final class GeneralPasteboardSource: PasteboardSource {
    private let pasteboard: NSPasteboard
    private var items: [NSPasteboardItem] = []

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func itemTypes() -> [[PasteboardType]] {
        var types: [[PasteboardType]] = []
        _ = MPLCatchException({
            items = pasteboard.pasteboardItems ?? []
            types = items.map { $0.types.map { PasteboardType($0.rawValue) } }
        }, nil)
        return types
    }

    public func data(forItem index: Int, type: PasteboardType) -> Data? {
        guard items.indices.contains(index) else { return nil }
        var data: Data?
        let item = items[index]
        guard MPLCatchException({ data = item.data(forType: NSPasteboard.PasteboardType(type.rawValue)) }, nil) else { return nil }
        return data
    }

    public func string(forItem index: Int, type: PasteboardType) -> String? {
        guard items.indices.contains(index) else { return nil }
        var string: String?
        let item = items[index]
        guard MPLCatchException({ string = item.string(forType: NSPasteboard.PasteboardType(type.rawValue)) }, nil) else { return nil }
        return string
    }
}

/// Clear → write → confirm (§3.4). Call on the main actor so no capture tick can interleave between
/// `clearContents()` and publishing the token.
public enum PasteboardWriter {
    public enum Result: Sendable, Equatable {
        /// Confirmed: `ownedCount` may be used as the suppression token.
        case written(ownedCount: Int)
        /// Written, but another change may have happened: no token.
        case unconfirmed
        /// Another app changed the clipboard after `clearContents()`; nothing written.
        case aborted
        case failed
    }

    public static func write(_ items: [CanonicalItem], sourceBundleID: String?, to pasteboard: NSPasteboard = .general) -> Result {
        let pasteboardItems = makeItems(items, sourceBundleID: sourceBundleID)
        guard !pasteboardItems.isEmpty else { return .failed }
        let ownedCount = pasteboard.clearContents()
        guard pasteboard.changeCount == ownedCount else { return .aborted }
        guard pasteboard.writeObjects(pasteboardItems) else { return .failed }
        return pasteboard.changeCount == ownedCount ? .written(ownedCount: ownedCount) : .unconfirmed
    }

    /// File lists expand to one item per URL; the item's other representations go on the first of them (§3.3).
    /// The source marker is set exactly once, on the first item (§5).
    public static func makeItems(_ items: [CanonicalItem], sourceBundleID: String?) -> [NSPasteboardItem] {
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

    public static func plainTextItems(_ text: String) -> [CanonicalItem] {
        [CanonicalItem([.bytes(.utf8PlainText, Data(text.utf8))])]
    }
}
