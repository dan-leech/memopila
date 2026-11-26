import Foundation

/// Pure decisions behind layout-convert delivery (PLAN §3.9.1). The app posts the keys and reads
/// the host's `AXValue`; these functions say what the host did and what to type next, so the
/// text-loss-prone parts are testable without a host.
public enum LayoutConvertDelivery {
    // MARK: Typing vs paste

    /// Text that must go through a transient ⌘V instead of typed Unicode: Monaco/VS Code
    /// auto-surround or auto-close typed brackets and quotes (`[jhjij` → `[jhjij]`), and a typed
    /// line break is an Enter command (Cursor chat dropped the first line of a 2-line selection).
    public static func needsPaste(_ text: String) -> Bool {
        text.contains { $0.isNewline || "[](){}<>'\"`".contains($0) }
    }

    // MARK: VS Code empty-selection copy

    /// `true`/`false` when a custom pasteboard blob carries VS Code's `"isFromEmptySelection"`
    /// flag (Chromium packs custom DataTransfer types into one pickle, UTF-16), `nil` when it
    /// does not mention it. With nothing selected VS Code copies the whole line and sets `true`.
    public static func emptySelectionCopyFlag(in data: Data) -> Bool? {
        let utf8 = String(decoding: data, as: UTF8.self)
        let utf16: String = data.withUnsafeBytes { raw in
            String(decoding: raw.bindMemory(to: UInt16.self), as: UTF16.self)
        }
        for text in [utf8, utf16] {
            let compact = text.replacingOccurrences(of: " ", with: "")
            if compact.contains("\"isFromEmptySelection\":true") { return true }
            if compact.contains("\"isFromEmptySelection\":false") { return false }
        }
        return nil
    }

    // MARK: One ⌫ over a selection (fake-AX hosts)

    /// How the host's ⌫ treated a selection, judged by how many UTF-16 units the first ⌫
    /// removed from the field. Raw values of `.standard`/`.caretAtEnd` are persisted per bundle.
    public enum BackspaceSemantics: String, Sendable, Equatable {
        /// ⌫ deleted exactly the selection; typing replaces it too.
        case standard
        /// Keys ignore the selection; the insertion point sits at its end (Telegram): one
        /// character went, the rest of the selection needs more ⌫.
        case caretAtEnd
        /// Cocoa smart delete: a whole-word selection took one or two adjacent spaces along.
        case smartDelete
        /// Anything else (nothing removed, or far more than the selection) — roll back.
        case unknown
    }

    public static func backspaceSemantics(removed: Int?, selectionLength: Int) -> BackspaceSemantics {
        guard let removed else { return .unknown }
        if removed == 1, selectionLength > 1 { return .caretAtEnd }
        if removed == selectionLength { return .standard }
        if removed > selectionLength, removed <= selectionLength + 2 { return .smartDelete }
        return .unknown
    }

    /// What left the field and what to type around the output to make up for it.
    public struct DeletionReading: Equatable, Sendable {
        /// The contiguous block that left the field, when the value diff is one block — typed
        /// back on rollback.
        public var removed: String?
        /// Whitespace smart delete took along, typed back before / after the output.
        public var leadingExtra = ""
        public var trailingExtra = ""
        /// `false` → roll back (type `removed`, or the selection, back) and fail the convert.
        public var understood: Bool

        public init(removed: String?, leadingExtra: String = "", trailingExtra: String = "", understood: Bool) {
            self.removed = removed
            self.leadingExtra = leadingExtra
            self.trailingExtra = trailingExtra
            self.understood = understood
        }
    }

    /// Reads the field before and after the ⌫s. Understood only when one contiguous block left
    /// and it is the selection — or, for smart delete, the selection plus whitespace, given back
    /// on the leading side when both sides fit (“␣word” and “word␣” leave the same text; Cocoa
    /// takes the space *before* the word — KeePassium lost the left space when it was put back
    /// on the right).
    public static func readDeletion(
        before: String,
        after: String,
        selectionLength: Int,
        semantics: BackspaceSemantics
    ) -> DeletionReading {
        let b = before as NSString
        let removedLength = b.length - (after as NSString).length
        let offset = removedLength > 0
            ? contiguousRemovalOffset(length: removedLength, from: before, giving: after)
            : nil
        let block = offset.map { b.substring(with: NSRange(location: $0, length: removedLength)) }
        guard block != nil, removedLength == selectionLength || semantics == .smartDelete else {
            return DeletionReading(removed: block, understood: false)
        }
        guard semantics == .smartDelete else {
            return DeletionReading(removed: block, understood: true)
        }
        let extra = removedLength - selectionLength
        // The field settled on exactly the selection after all: plain delete, nothing to give back.
        if extra == 0 { return DeletionReading(removed: block, understood: true) }
        guard extra > 0 else { return DeletionReading(removed: block, understood: false) }
        let candidates = removalOffsets(length: removedLength, from: before, giving: after)
        func whitespace(at location: Int) -> String? {
            let piece = b.substring(with: NSRange(location: location, length: extra))
            return piece.allSatisfy(\.isWhitespace) ? piece : nil
        }
        if let lead = candidates.lazy.compactMap({ whitespace(at: $0) }).first {
            return DeletionReading(removed: block, leadingExtra: lead, understood: true)
        }
        if let trail = candidates.lazy.compactMap({ whitespace(at: $0 + removedLength - extra) }).first {
            return DeletionReading(removed: block, trailingExtra: trail, understood: true)
        }
        return DeletionReading(removed: block, understood: false)
    }

    /// Every UTF-16 offset at which cutting a `length`-unit block from `before` gives `after`
    /// (repeated characters make the cut ambiguous: “a␣word␣b” → “a␣b” from 1 or 2).
    static func removalOffsets(length: Int, from before: String, giving after: String) -> [Int] {
        let b = before as NSString
        let a = after as NSString
        guard length > 0, b.length - length == a.length else { return [] }
        let common = min(commonPrefixUTF16(before, after), a.length)
        return stride(from: common, through: max(0, common - length), by: -1).filter { offset in
            b.replacingCharacters(in: NSRange(location: offset, length: length), with: "") == after
        }
    }

    /// UTF-16 offset of a contiguous `length`-unit block cut out of `before` to give `after`.
    static func contiguousRemovalOffset(length: Int, from before: String, giving after: String) -> Int? {
        let b = before as NSString
        let a = after as NSString
        guard length > 0, b.length - length == a.length else { return nil }
        let common = min(commonPrefixUTF16(before, after), a.length)
        let rebuilt = b.replacingCharacters(in: NSRange(location: common, length: length), with: "")
        return rebuilt == after ? common : nil
    }

    static func commonPrefixUTF16(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs as NSString
        let r = rhs as NSString
        var i = 0
        while i < l.length, i < r.length, l.character(at: i) == r.character(at: i) { i += 1 }
        return i
    }
}
