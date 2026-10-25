/// A pasteboard type identifier (usually a UTI) exactly as it appears in `NSPasteboardItem.types`.
public struct PasteboardType: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

// MARK: - Known types (PLAN §3.2.1)

extension PasteboardType {
    public static let utf8PlainText: Self = "public.utf8-plain-text"
    public static let plainText: Self = "public.plain-text"
    public static let utf16PlainText: Self = "public.utf16-plain-text"
    public static let rtf: Self = "public.rtf"
    public static let flatRTFD: Self = "com.apple.flat-rtfd"
    public static let html: Self = "public.html"
    public static let webArchive: Self = "com.apple.webarchive"
    public static let legacyWebArchive: Self = "Apple Web Archive pasteboard type"
    public static let url: Self = "public.url"
    public static let urlName: Self = "public.url-name"

    public static let fileURL: Self = "public.file-url"
    public static let filenames: Self = "NSFilenamesPboardType"

    public static let gif: Self = "com.compuserve.gif"
    public static let png: Self = "public.png"
    public static let heic: Self = "public.heic"
    public static let jpeg: Self = "public.jpeg"
    public static let tiff: Self = "public.tiff"
    public static let pdf: Self = "com.adobe.pdf"

    public static let color: Self = "com.apple.cocoa.pasteboard.color"

    /// nspasteboard.org source attribution (§5). Metadata, never payload.
    public static let source: Self = "org.nspasteboard.source"
    /// Source page written by Chromium-based apps (§5.2). Metadata, never payload.
    public static let chromiumSourceURL: Self = "org.chromium.source-url"
    /// Universal Clipboard content from another device (§3.2.1; identifier to verify in the spike).
    public static let remoteClipboard: Self = "com.apple.is-remote-clipboard"
}

// MARK: - Classification

extension PasteboardType {
    /// Types stored by default (§3.2.1).
    public static let allowlist: Set<PasteboardType> = [
        .utf8PlainText, .plainText, .utf16PlainText,
        .rtf, .flatRTFD, .html, .webArchive, .legacyWebArchive,
        .url, .urlName,
        .fileURL, .filenames,
        .gif, .png, .heic, .jpeg, .tiff, .pdf,
        .color,
    ]

    /// Raster formats in redundant-image preference order (§3.2.2).
    public static let rasterImagePreference: [PasteboardType] = [.gif, .png, .heic, .jpeg, .tiff]

    /// Richest → plainest for card preview and the record window (§8.2, §3.6). Caps differ by caller.
    public static let richDisplayPriority: [PasteboardType] = [
        .flatRTFD, .rtf, .html, .webArchive, .legacyWebArchive,
    ]

    public static let plainTextTypes: Set<PasteboardType> = [.utf8PlainText, .plainText, .utf16PlainText]
    public static let richTextTypes: Set<PasteboardType> = [.rtf, .flatRTFD, .html, .webArchive, .legacyWebArchive]

    public var isAllowlisted: Bool { Self.allowlist.contains(self) }
    public var isFileReference: Bool { self == .fileURL || self == .filenames }
    public var isRasterImage: Bool { Self.rasterImagePreference.contains(self) }

    /// Metadata types are read for decisions only and are never stored or kept by rules.
    public var isMetadataOnly: Bool {
        self == .source || self == .chromiumSourceURL || self == .remoteClipboard || PrivacyMarker.kind(of: self) != nil
    }
}
