import Foundation

/// Keeps HTML reading local (§9): WebKit's HTML loader would otherwise fetch remote images,
/// stylesheets and `@import`s when a record opens. Cards already use `HTMLPreview` with no network;
/// the record window sanitizes first, then loads. Link destinations are restored from the
/// original markup via `HTMLPreview` so relative `href`s AppKit drops still work.
public enum HTMLIsolation {
    /// Neutralizes remote subresource URLs so `NSAttributedString.loadFromHTML` / WebKit stay offline.
    /// Text, colours and structure are kept; remote `href`s are blanked (re-applied later).
    public static func strippingRemoteLoads(_ html: String) -> String {
        var result = neutralize(attribute: "src", in: html) { isRemoteURL($0) ? "about:blank" : nil }
        result = neutralize(attribute: "href", in: result) { isRemoteURL($0) ? "about:blank" : nil }
        return neutralizeCSSURLs(in: result)
    }

    private static func isRemoteURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("data:") || value.hasPrefix("about:") || value.hasPrefix("#") { return false }
        if value.hasPrefix("//") { return true }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("file://") { return true }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "ftp"].contains(scheme) {
            return true
        }
        return false
    }

    private static func neutralize(attribute: String, in html: String, replace: (String) -> String?) -> String {
        var output = ""
        var remainder = html[...]
        let pattern = attribute + "="
        while let attrStart = remainder.range(of: pattern, options: .caseInsensitive) {
            output += remainder[..<attrStart.lowerBound]
            let afterAttr = remainder[attrStart.upperBound...]
            guard let quote = afterAttr.first, quote == "\"" || quote == "'" else {
                output += remainder[attrStart]
                remainder = remainder[attrStart.upperBound...]
                continue
            }
            let valueStart = afterAttr.index(after: afterAttr.startIndex)
            guard let valueEnd = afterAttr[valueStart...].firstIndex(of: quote) else {
                output += remainder[attrStart]
                remainder = remainder[attrStart.upperBound...]
                continue
            }
            let value = String(afterAttr[valueStart..<valueEnd])
            let rewritten = replace(value) ?? value
            output += attribute + "=" + String(quote) + rewritten + String(quote)
            remainder = afterAttr[afterAttr.index(after: valueEnd)...]
        }
        output += remainder
        return output
    }

    private static func neutralizeCSSURLs(in html: String) -> String {
        var output = ""
        var remainder = html[...]
        while let urlStart = remainder.range(of: "url(", options: .caseInsensitive) {
            output += remainder[..<urlStart.lowerBound]
            let after = remainder[urlStart.upperBound...]
            var index = after.startIndex
            while index < after.endIndex, after[index].isWhitespace { index = after.index(after: index) }
            guard index < after.endIndex else {
                output += remainder[urlStart]
                remainder = remainder[urlStart.upperBound...]
                continue
            }
            let quote: Character?
            let valueStart: String.Index
            if after[index] == "\"" || after[index] == "'" {
                quote = after[index]
                valueStart = after.index(after: index)
            } else {
                quote = nil
                valueStart = index
            }
            let valueEnd: String.Index
            if let quote {
                guard let end = after[valueStart...].firstIndex(of: quote) else {
                    output += remainder[urlStart]
                    remainder = remainder[urlStart.upperBound...]
                    continue
                }
                valueEnd = end
            } else {
                guard let end = after[valueStart...].firstIndex(where: { $0 == ")" || $0.isWhitespace }) else {
                    output += remainder[urlStart]
                    remainder = remainder[urlStart.upperBound...]
                    continue
                }
                valueEnd = end
            }
            let value = String(after[valueStart..<valueEnd])
            let rewritten = isRemoteURL(value) ? "about:blank" : value
            if let quote {
                output += "url(" + String(quote) + rewritten + String(quote)
                remainder = after[after.index(after: valueEnd)...]
            } else {
                output += "url(" + rewritten
                remainder = after[valueEnd...]
            }
        }
        output += remainder
        return output
    }
}
