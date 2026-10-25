import Foundation

/// Web archive PropertyList helpers (§3.6, §9): extract main HTML for cards / restore, and
/// sanitize HTML/CSS payloads so WebKit loads no remote subresources.
///
/// URLs that resolve to a `WebResourceURL` already in the plist are kept (local bytes). Everything
/// else fetchable — absolute remote or path-relative that would miss the archive — is blanked.
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

    /// Walks main + `WebSubresources`, runs `HTMLIsolation` on `text/html` and `text/css` payloads
    /// with a keep-list of archive URLs, rebuilds the plist. `nil` if unparseable.
    public static func strippingRemoteLoads(inWebArchive data: Data) -> Data? {
        guard var root = plist(from: data) else { return nil }
        let localURLs = resourceURLs(in: root)
        let mainURL = (root["WebMainResource"] as? [String: Any])?["WebResourceURL"] as? String
        let base = mainURL.flatMap { URL(string: $0) }
        let keeping: (String) -> Bool = { raw in isLocalResource(raw, base: base, localURLs: localURLs) }

        if var main = root["WebMainResource"] as? [String: Any] {
            sanitizeResource(&main, keeping: keeping)
            root["WebMainResource"] = main
        }
        if var subs = root["WebSubresources"] as? [[String: Any]] {
            for index in subs.indices {
                sanitizeResource(&subs[index], keeping: keeping)
            }
            root["WebSubresources"] = subs
        }
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// True when `raw` is a URL already stored in the archive (exact or resolved against the main URL).
    static func isLocalResource(_ raw: String, base: URL?, localURLs: Set<String>) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if localURLs.contains(trimmed) { return true }
        guard let base,
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL.absoluteString
        else { return false }
        return localURLs.contains(resolved)
    }

    private static func mainResource(from archive: Data) -> [String: Any]? {
        plist(from: archive)?["WebMainResource"] as? [String: Any]
    }

    private static func plist(from data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func resourceURLs(in root: [String: Any]) -> Set<String> {
        var urls = Set<String>()
        if let main = root["WebMainResource"] as? [String: Any],
           let url = main["WebResourceURL"] as? String {
            urls.insert(url)
        }
        if let subs = root["WebSubresources"] as? [[String: Any]] {
            for sub in subs {
                if let url = sub["WebResourceURL"] as? String { urls.insert(url) }
            }
        }
        return urls
    }

    private static func sanitizeResource(_ resource: inout [String: Any], keeping: @escaping (String) -> Bool) {
        guard let mime = resource["WebResourceMIMEType"] as? String,
              isHTMLOrCSS(mime),
              let data = resource["WebResourceData"] as? Data,
              let text = decodeText(data) else { return }
        let cleaned = HTMLIsolation.strippingRemoteLoads(text, keeping: keeping)
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
