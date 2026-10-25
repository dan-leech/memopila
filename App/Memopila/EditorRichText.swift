import AppKit
import MemopilaCore
import WebKit

/// Loads the richest readable format for the record window (§3.6, §8.2): RTFD → RTF → HTML →
/// web archive. HTML and archives go through Isolation (and restore) so opening history starts no
/// background network (§9).
enum EditorRichText {
    static let maxBytes = 4 * 1_048_576
    static let maxArchiveBytes = 1_048_576

    /// Representations of one record → attributed text + optional document background.
    static func load(from representations: [(PasteboardType, Data)]) async -> (text: NSAttributedString, background: NSColor?)? {
        for type in PasteboardType.richDisplayPriority {
            guard let data = representations.first(where: { $0.0 == type })?.1, data.count <= maxBytes else { continue }
            if let read = await attributedString(data, type: type), read.text.length > 0 { return read }
        }
        return nil
    }

    private static func attributedString(_ data: Data, type: PasteboardType) async -> (text: NSAttributedString, background: NSColor?)? {
        switch type {
        case .html:
            return await loadHTML(data)
        case .webArchive, .legacyWebArchive:
            return await loadWebArchive(data)
        case .flatRTFD:
            return await loadRTF(data, documentType: .rtfd)
        case .rtf:
            return await loadRTF(data, documentType: .rtf)
        default:
            return nil
        }
    }

    /// Isolate first (§9), then WebKit's async loader, then restore colours/links from the
    /// original markup (AppKit drops some of them).
    private static func loadHTML(_ data: Data) async -> (text: NSAttributedString, background: NSColor?)? {
        let html = String(decoding: data, as: UTF8.self)
        let loadData = Data(HTMLIsolation.strippingRemoteLoads(html).utf8)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Transfer<(NSAttributedString, NSColor?)?>, Never>) in
            NSAttributedString.loadFromHTML(data: loadData, options: [.characterEncoding: String.Encoding.utf8.rawValue, .timeout: 5]) { text, attributes, _ in
                continuation.resume(returning: Transfer(value: text.map { ($0, attributes?[.backgroundColor] as? NSColor) }))
            }
        }
        guard let loaded = result.value else { return nil }
        let text = NSMutableAttributedString(attributedString: loaded.0)
        MarkupColorRestore.restoreMarkupColors(html: html, into: text)
        MarkupColorRestore.paintUncoloredLinks(in: text)
        return (text, loaded.1)
    }

    /// Sanitize HTML/CSS inside the plist; fail closed to sanitized main HTML → `loadFromHTML`.
    /// Never loads a raw unsanitized archive.
    private static func loadWebArchive(_ data: Data) async -> (text: NSAttributedString, background: NSColor?)? {
        guard data.count <= maxArchiveBytes else { return nil }
        let originalHTML = WebArchiveHTML.mainHTML(from: data)
        if let sanitized = WebArchiveHTML.strippingRemoteLoads(inWebArchive: data) {
            var attributes: NSDictionary?
            if let text = try? NSAttributedString(
                data: sanitized,
                options: [.documentType: NSAttributedString.DocumentType.webArchive, .timeout: 2],
                documentAttributes: &attributes
            ), text.length > 0 {
                let mutable = NSMutableAttributedString(attributedString: text)
                if let originalHTML {
                    MarkupColorRestore.restoreMarkupColors(html: originalHTML, into: mutable)
                    MarkupColorRestore.paintUncoloredLinks(in: mutable)
                }
                let background = (attributes as? [NSAttributedString.DocumentAttributeKey: Any])?[.backgroundColor] as? NSColor
                return (mutable, background)
            }
        }
        guard let html = originalHTML else { return nil }
        return await loadHTML(Data(html.utf8))
    }

    private static func loadRTF(_ data: Data, documentType: NSAttributedString.DocumentType) async -> (text: NSAttributedString, background: NSColor?)? {
        let raw = documentType.rawValue
        return await Task.detached(priority: .userInitiated) { () -> Transfer<(text: NSAttributedString, background: NSColor?)>? in
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType(rawValue: raw)]
            var attributes: NSDictionary?
            guard let text = try? NSAttributedString(data: data, options: options, documentAttributes: &attributes) else { return nil }
            let background = (attributes as? [NSAttributedString.DocumentAttributeKey: Any])?[.backgroundColor] as? NSColor
            return Transfer(value: (text, background))
        }.value?.value
    }
}
