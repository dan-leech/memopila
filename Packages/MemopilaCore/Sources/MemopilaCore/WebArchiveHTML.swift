import Foundation

/// Web archive PropertyList helpers (§3.6, §9): extract main HTML for cards / restore, and
/// sanitize HTML/CSS payloads so WebKit loads no remote subresources.
public enum WebArchiveHTML {
    /// UTF-8 (or Latin-1 fallback) text of `WebMainResource.WebResourceData`.
    public static func mainHTML(from archive: Data) -> String? {
        guard let main = mainResource(from: archive),
              let data = main["WebResourceData"] as? Data else { return nil }
        return decodeText(data)
    }

    /// Main resource URL string when present (for `SourcePage`).
    public static func mainResourceURL(from archive: Data) -> String? {
        mainResource(from: archive)?["WebResourceURL"] as? String
    }

    /// Walks main + `WebSubresources`, runs `HTMLIsolation` on `text/html` and `text/css` payloads,
    /// rebuilds the plist. `nil` if the archive cannot be parsed or rebuilt.
    public static func strippingRemoteLoads(inWebArchive data: Data) -> Data? {
        guard var root = plist(from: data) else { return nil }
        if var main = root["WebMainResource"] as? [String: Any] {
            sanitizeResource(&main)
            root["WebMainResource"] = main
        }
        if var subs = root["WebSubresources"] as? [[String: Any]] {
            for index in subs.indices {
                sanitizeResource(&subs[index])
            }
            root["WebSubresources"] = subs
        }
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private static func mainResource(from archive: Data) -> [String: Any]? {
        plist(from: archive)?["WebMainResource"] as? [String: Any]
    }

    private static func plist(from data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func sanitizeResource(_ resource: inout [String: Any]) {
        guard let mime = resource["WebResourceMIMEType"] as? String,
              isHTMLOrCSS(mime),
              let data = resource["WebResourceData"] as? Data,
              let text = decodeText(data) else { return }
        let cleaned = HTMLIsolation.strippingRemoteLoads(text)
        resource["WebResourceData"] = Data(cleaned.utf8)
    }

    private static func isHTMLOrCSS(_ mime: String) -> Bool {
        let lower = mime.lowercased()
        return lower.hasPrefix("text/html") || lower.hasPrefix("text/css") || lower.hasPrefix("application/xhtml")
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1)
    }
}
