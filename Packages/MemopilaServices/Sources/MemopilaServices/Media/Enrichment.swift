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

        if let text = RichText.plainText(of: items) {
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

        if let colorData = representations.first(where: { $0.type == .color })?.bytes {
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

/// `#RRGGBB` for a `com.apple.cocoa.pasteboard.color` payload.
public enum ColorHex {
    public static func string(fromPasteboardColor data: Data) -> String? {
        guard let color = NSColor(pasteboardPropertyList: data, ofType: .color),
              let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(rgb.redComponent), component(rgb.greenComponent), component(rgb.blueComponent))
    }
}
