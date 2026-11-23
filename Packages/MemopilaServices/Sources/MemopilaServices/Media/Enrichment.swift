import AppKit
import ImageIO
import MemopilaCore
import UniformTypeIdentifiers

/// Card and search metadata derived from a snapshot off the main actor before ingest (§7.3, §7.4).
public struct IngestEnrichment: Sendable, Equatable {
    public var cardPreview: String
    public var textIndex: String
    public var textLength: Int?
    public var lineCount: Int?
    public var thumbnail: Data?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var colorHex: String?
    public var sourceAppName: String?
    /// Focused window title of the source app, only when Accessibility is already granted (§5.2).
    public var sourceWindowTitle: String?
    public var filePaths: [String]

    public static let cardPreviewScalars = 300
    public static let searchScalars = 10_000

    public init(
        cardPreview: String = "",
        textIndex: String = "",
        textLength: Int? = nil,
        lineCount: Int? = nil,
        thumbnail: Data? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        colorHex: String? = nil,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        filePaths: [String] = []
    ) {
        self.cardPreview = cardPreview
        self.textIndex = textIndex
        self.textLength = textLength
        self.lineCount = lineCount
        self.thumbnail = thumbnail
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorHex = colorHex
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.filePaths = filePaths
    }

    public static func make(for items: [CanonicalItem], sourceAppName: String?, sourceWindowTitle: String? = nil) -> IngestEnrichment {
        var enrichment = IngestEnrichment(sourceAppName: sourceAppName, sourceWindowTitle: sourceWindowTitle)
        let representations = items.flatMap(\.representations)

        // Colour: preview/format cache must use pastePlainText SSOT (trimmed), not RichText/TextDecoding.
        if let colorText = ColorPayload.pastePlainText(of: items), ColorPayload.identity(of: items) != nil {
            enrichment.cardPreview = TextDecoding.prefix(colorText, maxScalars: cardPreviewScalars)
            enrichment.textIndex = TextDecoding.prefix(colorText, maxScalars: searchScalars)
            enrichment.textLength = colorText.count
            enrichment.lineCount = 1
        } else if let text = RichText.plainText(of: items) {
            enrichment.cardPreview = TextDecoding.prefix(text, maxScalars: cardPreviewScalars)
            enrichment.textIndex = TextDecoding.prefix(text, maxScalars: searchScalars)
            enrichment.textLength = text.count
            enrichment.lineCount = TextStats.lineCount(text)
        }

        enrichment.filePaths = representations.flatMap { representation -> [String] in
            if case .filePaths(let paths) = representation.payload { return paths }
            return []
        }

        let imageTypes = Set(PasteboardType.rasterImagePreference).union([.pdf])
        if let image = representations.first(where: { imageTypes.contains($0.type) }), let data = image.bytes,
           let thumbnail = Thumbnailer.thumbnail(from: data, isPDF: image.type == .pdf) {
            enrichment.thumbnail = thumbnail.data
            enrichment.pixelWidth = thumbnail.pixelWidth
            enrichment.pixelHeight = thumbnail.pixelHeight
        }

        if let hex = ColorPayload.identity(of: items)?.hex {
            enrichment.colorHex = hex
        } else if let colorData = representations.first(where: { $0.type == .color })?.bytes {
            enrichment.colorHex = ColorHex.string(fromPasteboardColor: colorData)
        }
        return enrichment
    }
}

public enum TextStats {
    /// Lines as an editor shows them: trailing line breaks do not start a new line.
    public static func lineCount(_ text: String) -> Int {
        var breaks = 0
        var trailing = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                breaks += 1
                trailing += 1
            } else if byte != 0x0D {
                trailing = 0
            }
        }
        return max(1, breaks - trailing + 1)
    }
}

/// Plain text for previews and search, including RTF/RTFD (§7.4). HTML uses `HTMLPreview` first
/// (same path as cards); tag stripping is a last resort when preview yields nothing.
public enum RichText {
    public static func plainText(of items: [CanonicalItem]) -> String? {
        if let text = TextDecoding.plainText(of: items) { return text }
        let representations = items.flatMap(\.representations)
        for representation in representations {
            guard let data = representation.bytes else { continue }
            switch representation.type {
            case .rtf:
                if let text = attributed(data, .rtf) { return text }
            case .flatRTFD:
                if let text = attributed(data, .rtfd) { return text }
            case .html:
                if let html = String(data: data, encoding: .utf8) {
                    let preview = HTMLPreview.preview(of: html, maxCharacters: IngestEnrichment.searchScalars).text
                    if !preview.isEmpty { return preview }
                    return stripTags(html)
                }
            case .webArchive, .legacyWebArchive:
                if let html = WebArchiveHTML.mainHTML(from: data) {
                    let preview = HTMLPreview.preview(of: html, maxCharacters: IngestEnrichment.searchScalars).text
                    if !preview.isEmpty { return preview }
                    return stripTags(html)
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func attributed(_ data: Data, _ type: NSAttributedString.DocumentType) -> String? {
        try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
    }

    static func stripTags(_ html: String) -> String {
        var result = ""
        var inTag = false
        for character in html {
            switch character {
            case "<": inTag = true
            case ">": inTag = false
            default: if !inTag { result.append(character) }
            }
        }
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Downsampled thumbnails through ImageIO / Core Graphics: full-size images are never decoded (§7.3).
public enum Thumbnailer {
    public static let maxPixelSize = 512

    public struct Result: Sendable, Equatable {
        public let data: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public static func thumbnail(from data: Data, isPDF: Bool) -> Result? {
        isPDF ? pdfThumbnail(data) : rasterThumbnail(data)
    }

    /// Downsampled `CGImage` for display at `maxPixelSize` (preview, recognition).
    public static func downsampledImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func rasterThumbnail(_ data: Data) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsampledImage(from: data, maxPixelSize: maxPixelSize),
              let encoded = encode(image) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return Result(
            data: encoded,
            pixelWidth: properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width,
            pixelHeight: properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
        )
    }

    private static func pdfThumbnail(_ data: Data) -> Result? {
        guard let rendered = renderPDFPage(data, maxPixelSize: maxPixelSize), let encoded = encode(rendered.image) else { return nil }
        return Result(data: encoded, pixelWidth: rendered.pageWidth, pixelHeight: rendered.pageHeight)
    }

    /// First PDF page on white, scaled to fit `maxPixelSize`.
    public static func renderPDFPage(_ data: Data, maxPixelSize: Int) -> (image: CGImage, pageWidth: Int, pageHeight: Int)? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixelSize) / max(box.width, box.height))
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return (image, Int(box.width), Int(box.height))
    }

    /// PNG when the image has alpha, JPEG otherwise (smaller).
    private static func encode(_ image: CGImage) -> Data? {
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let output = NSMutableData()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// `#RRGGBB` or `#RRGGBBAA` for a `com.apple.cocoa.pasteboard.color` payload (AA when translucent).
public enum ColorHex {
    public static func string(fromPasteboardColor data: Data) -> String? {
        guard let color = NSColor(pasteboardPropertyList: data, ofType: .color) else { return nil }
        return string(from: color)
    }

    /// sRGB HEX matching `ColorValues.hex`.
    public static func string(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return ColorValues(
            red: component(rgb.redComponent),
            green: component(rgb.greenComponent),
            blue: component(rgb.blueComponent),
            alpha: component(rgb.alphaComponent)
        )?.hex
    }
}

/// Colour pasteboard identity: UTI alone is not enough — text fields need a CSS string, and MCS1
/// must match what `PasteboardWriter.makeItems` writes (synthesis on write alone diverged hashes).
public enum ColorPayload {
    /// Colour-UTI-only → +HEX; lone CSS text → colour; rebuild UTI from sRGB channels so Color Picker
    /// vs `colorItems` vs `#hex` text share one MCS1 for the same channels + paste format.
    public static func normalized(_ items: [CanonicalItem]) -> [CanonicalItem] {
        canonicalizingColorItems(promotingLoneCSSColor(ensuringPasteText(items)))
    }

    /// Append HEX plain text when a colour item has no plain-text representation. Idempotent.
    public static func ensuringPasteText(_ items: [CanonicalItem]) -> [CanonicalItem] {
        items.map { item in
            let types = Set(item.representations.map(\.type))
            guard types.contains(.color) else { return item }
            if !types.isDisjoint(with: PasteboardType.plainTextTypes) { return item }
            guard let data = item.representations.first(where: { $0.type == .color })?.bytes,
                  let hex = ColorHex.string(fromPasteboardColor: data) else { return item }
            return CanonicalItem(item.representations + [.bytes(.utf8PlainText, Data(hex.utf8))])
        }
    }

    /// A single item whose plain text is only `#…` / `rgb(…)` / `hsl(…)` → Color card (UTI + text).
    /// Keeps files / images / *significant* rich text (promoting would drop real formatting).
    /// Insignificant RTF/HTML (browser/Notes chrome) aligns with `DisplayType`: those copies are
    /// already classified as text — refusing them here left text+#hex forks vs Color Picker MCS1.
    public static func promotingLoneCSSColor(_ items: [CanonicalItem]) -> [CanonicalItem] {
        guard items.count == 1 else { return items }
        let item = items[0]
        let types = Set(item.representations.map(\.type))
        if types.contains(.color) { return items }
        if types.contains(where: \.isFileReference)
            || types.contains(where: \.isRasterImage)
            || types.contains(.pdf) { return items }
        if !types.isDisjoint(with: PasteboardType.richTextTypes),
           FormattingSignificance.isSignificant(item) {
            return items
        }
        // RichText: HTML/RTF-only copies (no utf8) still expose a lone CSS string.
        guard let text = RichText.plainText(of: items) else { return items }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let values = ColorValues(css: trimmed) else { return items }
        let format = ColorPasteFormat.matching(trimmed) ?? .hex
        let promoted = PasteboardWriter.colorItems(values, textFormat: format)
        return promoted.isEmpty ? items : promoted
    }

    /// Replace opaque NSColor archives with deterministic sRGB `colorItems` for the same channels.
    /// Paste format comes from the CSS string's *shape* (`hsl(` / `rgb(` / `#`), not channel equality:
    /// HSL↔RGB routinely drifts ±1, and requiring `ColorValues` equality forced HEX and forked MCS1.
    public static func canonicalizingColorItems(_ items: [CanonicalItem]) -> [CanonicalItem] {
        items.map { item in
            guard let colorData = item.representations.first(where: { $0.type == .color })?.bytes,
                  let hex = ColorHex.string(fromPasteboardColor: colorData),
                  let values = ColorValues(hex: hex) else { return item }
            // UTI channels win; format enum from a parseable CSS paste string (else HEX).
            let format = pasteFormat(forPlainText: pastePlainText(of: item))
            let rebuilt = PasteboardWriter.colorItems(values, textFormat: format)
            return rebuilt.first ?? item
        }
    }

    /// Logical colour identity: canonical sRGB HEX + paste-format shape (§8.5).
    public struct Identity: Sendable, Equatable {
        public let hex: String
        public let format: ColorPasteFormat
    }

    /// Payload-derived identity (UTI channels + CSS shape). Nil when there is no readable colour UTI.
    public static func identity(of items: [CanonicalItem]) -> Identity? {
        let reps = items.flatMap(\.representations)
        guard let data = reps.first(where: { $0.type == .color })?.bytes,
              let hex = ColorHex.string(fromPasteboardColor: data).flatMap({ ColorValues(hex: $0)?.hex })
        else { return nil }
        return Identity(hex: hex, format: pasteFormat(forPlainText: pastePlainText(of: items)))
    }

    /// Trimmed paste string of the first colour-bearing item (or first item).
    public static func pastePlainText(of items: [CanonicalItem]) -> String? {
        if let item = items.first(where: { $0.representations.contains(where: { $0.type == .color }) }) {
            return pastePlainText(of: item)
        }
        return items.first.flatMap(pastePlainText(of:))
    }

    /// HEX / RGB / HSL from a stored paste string when it is a CSS colour; otherwise HEX.
    public static func pasteFormat(forPlainText text: String?) -> ColorPasteFormat {
        guard let text, ColorValues(css: text) != nil else { return .hex }
        return ColorPasteFormat.matching(text) ?? .hex
    }

    /// Record-window Choose: honour a picker change; otherwise trust the stored paste string so ↩
    /// before `details` heals an empty preview does not rewrite RGB/HSL cards as HEX.
    public static func chooseFormat(
        picker: ColorPasteFormat,
        openTimePreview: String,
        payloadPlainText: String?
    ) -> ColorPasteFormat {
        let seeded = ColorPasteFormat.matching(openTimePreview) ?? .hex
        if picker != seeded { return picker }
        return pasteFormat(forPlainText: payloadPlainText)
    }

    /// Plain text on a colour item in the same preference order as `TextDecoding` (utf8 before utf16).
    /// Decoding utf16 as UTF-8 used to miss HSL/RGB and force HEX. Always trimmed.
    public static func pastePlainText(of item: CanonicalItem) -> String? {
        let order: [PasteboardType] = [.utf8PlainText, .plainText, .utf16PlainText]
        for type in order {
            guard let data = item.representations.first(where: { $0.type == type })?.bytes,
                  let text = TextDecoding.decode(data, as: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Rebuild via `colorItems` so format changes never keep a legacy NSColor archive (forked MCS1).
    public static func replacingPasteText(in items: [CanonicalItem], text: String) -> [CanonicalItem] {
        let format = pasteFormat(forPlainText: text)
        return items.map { item in
            guard let colorData = item.representations.first(where: { $0.type == .color })?.bytes,
                  let hex = ColorHex.string(fromPasteboardColor: colorData),
                  let values = ColorValues(hex: hex) else { return item }
            return PasteboardWriter.colorItems(values, textFormat: format).first ?? item
        }
    }

    /// UI channels from caches: paste string when it parses as CSS, else `colorHex`.
    /// Never let a stale HEX cache override a readable paste string (same class of bug as
    /// cache-first Choose rewriting RGB/HSL cards).
    public static func displayValues(preview: String, colorHex: String?) -> ColorValues? {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let values = ColorValues(css: trimmed) { return values }
        if let hex = colorHex, let values = ColorValues(hex: hex) { return values }
        return nil
    }

    /// Rehash after normalisation so ingest stores the same bytes Choose will write.
    public static func normalizedSnapshot(_ snapshot: OwnedSnapshot) -> OwnedSnapshot {
        let items = normalized(snapshot.items)
        guard items != snapshot.items else { return snapshot }
        return OwnedSnapshot(
            changeCount: snapshot.changeCount,
            observedAt: snapshot.observedAt,
            identity: snapshot.identity,
            settings: snapshot.settings,
            items: items,
            contentHash: MCS1.contentHash(of: items),
            payloadSizeBytes: MCS1.payloadSize(of: items),
            displayType: DisplayType.classify(items),
            skippedTypes: snapshot.skippedTypes,
            sourceURL: snapshot.sourceURL,
            sensitiveKind: snapshot.sensitiveKind
        )
    }
}
