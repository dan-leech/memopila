import Foundation

/// *Copied from …* metadata (PLAN §5.2). Never payload, never hashed.
public enum SourcePage {
    public static let maxURLBytes = 2048
    private static let allowedSchemes: Set<String> = ["http", "https", "file"]

    /// Trimmed URL if it is http(s)/file and at most 2 048 bytes; anything else → `nil`.
    public static func validatedURL(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxURLBytes,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        return trimmed
    }

    /// `org.chromium.source-url` payload: a UTF-8 URL string.
    public static func url(fromChromiumSourceURL data: Data) -> String? {
        String(validating: data, as: UTF8.self).flatMap(validatedURL)
    }

    /// Main resource URL of a web archive (`WebMainResource` → `WebResourceURL`).
    public static func url(fromWebArchive data: Data) -> String? {
        WebArchiveHTML.mainResourceURL(from: data).flatMap(validatedURL)
    }

    /// Host for display (`example.com`); `nil` for file URLs.
    public static func host(of url: String) -> String? {
        URL(string: url)?.host(percentEncoded: false)
    }
}
