import Foundation

/// The single text decode helper for previews, search and text actions (PLAN §7.4).
/// Rich formats (RTF, RTFD, HTML) are converted by the app layer, not here.
public enum TextDecoding {
    /// UTF-8 for UTF-8/plain text; UTF-16 honoring a BOM, else little-endian. Invalid input → `nil`.
    public static func decode(_ data: Data, as type: PasteboardType) -> String? {
        switch type {
        case .utf8PlainText, .plainText, .url, .urlName:
            return String(validating: data, as: UTF8.self)
        case .utf16PlainText:
            return decodeUTF16(data)
        default:
            return nil
        }
    }

    /// The first plain-text representation of the first item that has one.
    public static func plainText(of items: [CanonicalItem]) -> String? {
        let order: [PasteboardType] = [.utf8PlainText, .plainText, .utf16PlainText]
        for item in items {
            for type in order {
                if let data = item.representations.first(where: { $0.type == type })?.bytes,
                   let text = decode(data, as: type) {
                    return text
                }
            }
        }
        return nil
    }

    /// Caps apply to Unicode scalars of the decoded string.
    public static func prefix(_ text: String, maxScalars: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(maxScalars))
        return String(scalars)
    }

    /// The whole text (ignoring surrounding whitespace) is one http(s) URL.
    public static func isSingleWebURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return false }
        return true
    }

    private static func decodeUTF16(_ data: Data) -> String? {
        guard data.count.isMultiple(of: 2) else { return nil }
        var bytes = Array(data)
        var bigEndian = false
        if bytes.count >= 2 {
            if bytes[0] == 0xFE, bytes[1] == 0xFF {
                bigEndian = true
                bytes.removeFirst(2)
            } else if bytes[0] == 0xFF, bytes[1] == 0xFE {
                bytes.removeFirst(2)
            }
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        return String(validating: units, as: UTF16.self)
    }
}
