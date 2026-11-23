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
        (try? itemTypesStrict()) ?? []
    }

    /// Declared types only; throws when the pasteboard raised (monitor maps to `.peekFailed`).
    public func itemTypesStrict() throws -> [[PasteboardType]] {
        var types: [[PasteboardType]] = []
        var failed = false
        let ok = MPLCatchException({
            items = pasteboard.pasteboardItems ?? []
            types = items.map { $0.types.map { PasteboardType($0.rawValue) } }
        }, nil)
        if !ok { failed = true }
        if failed { throw PasteboardPeekError.failed }
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

public enum PasteboardPeekError: Error {
    case failed
}

/// Cheap types-only peek for capture Phase B / resume (pass 16).
public enum PasteboardTypesPeek {
    public static func read(from pasteboard: NSPasteboard = .general) -> TypesPeek {
        do {
            return PasteboardTypesClassifier.peek(try GeneralPasteboardSource(pasteboard).itemTypesStrict())
        } catch {
            return .peekFailed
        }
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
            var wrotePlainText = false
            for representation in others {
                let type = NSPasteboard.PasteboardType(representation.type.rawValue)
                // Plain text as a string: many fields ignore UTF-8 `setData` for paste.
                // Decode via TextDecoding (utf16 must not be read as UTF-8 — that forced HEX synthesis
                // on colour cards and left raw utf16 bytes on the pasteboard).
                if PasteboardType.plainTextTypes.contains(representation.type),
                   let data = representation.bytes,
                   let string = TextDecoding.decode(data, as: representation.type) {
                    carrier.setString(string, forType: .string)
                    wrotePlainText = true
                } else if !PasteboardType.plainTextTypes.contains(representation.type),
                          let data = representation.bytes {
                    carrier.setData(data, forType: type)
                }
            }
            // Color cards show HEX in the UI from metadata, but older / Color Picker payloads are
            // colour-UTI only — synthesize HEX so Choose/Restore pastes into text fields.
            if !wrotePlainText,
               let colorData = others.first(where: { $0.type == .color })?.bytes,
               let hex = ColorHex.string(fromPasteboardColor: colorData) {
                carrier.setString(hex, forType: .string)
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

    /// Colour UTI plus one CSS string (HEX / RGB / HSL) so Color Wells and text fields both paste.
    /// `DisplayType` stays `.color`; the string is the paste format for text fields (§8.5).
    public static func colorItems(_ values: ColorValues, textFormat: ColorPasteFormat = .hex) -> [CanonicalItem] {
        let color = NSColor(
            srgbRed: CGFloat(values.red) / 255,
            green: CGFloat(values.green) / 255,
            blue: CGFloat(values.blue) / 255,
            alpha: CGFloat(values.alpha) / 255
        )
        guard let data = color.pasteboardPropertyList(forType: .color) as? Data else { return [] }
        let text = textFormat.string(from: values)
        return [CanonicalItem([
            .bytes(.color, data),
            .bytes(.utf8PlainText, Data(text.utf8)),
        ])]
    }
}
