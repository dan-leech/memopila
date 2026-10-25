import Foundation

/// Keeps HTML reading local (§9): WebKit's HTML loader would otherwise fetch remote images,
/// stylesheets and `@import`s when a record opens. Cards already use `HTMLPreview` with no network;
/// the record window sanitizes first, then loads.
///
/// Only **subresource** URLs are blanked (`src`, stylesheets, CSS `url()`, `@import`, `<base>`, …).
/// Anchor `href`s are kept — they do not cause fetches during `loadFromHTML`. Colours and relative
/// links AppKit drops are restored afterwards via `HTMLPreview`.
public enum HTMLIsolation {
    private static let resourceTags: Set<String> = [
        "link", "script", "iframe", "source", "embed", "object", "base",
    ]

    /// Neutralizes remote subresource URLs so `NSAttributedString.loadFromHTML` / WebKit stay offline.
    public static func strippingRemoteLoads(_ html: String) -> String {
        var result = html
        for attribute in ["src", "srcset", "poster", "data-src"] {
            result = neutralize(attribute: attribute, in: result) { value, _ in
                let remote = attribute == "srcset" ? isRemoteSrcset(value) : isRemoteURL(value)
                return remote ? "about:blank" : nil
            }
        }
        result = neutralize(attribute: "href", in: result) { value, tag in
            guard let tag, resourceTags.contains(tag) else { return nil }
            return isRemoteURL(value) ? "about:blank" : nil
        }
        result = neutralizeCSSURLs(in: result)
        return neutralizeAtImports(in: result)
    }

    private static func isRemoteSrcset(_ raw: String) -> Bool {
        raw.split(separator: ",").contains { candidate in
            let url = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace }).first
                .map(String.init) ?? ""
            return isRemoteURL(url)
        }
    }

    static func isRemoteURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return false }
        if value.hasPrefix("data:") || value.hasPrefix("about:") || value.hasPrefix("#") { return false }
        if value.hasPrefix("//") { return true }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("file://") { return true }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "ftp"].contains(scheme) {
            return true
        }
        return false
    }

    /// Rewrites `attr="…"`, `attr='…'`, and unquoted `attr=value` (until whitespace or `>`).
    /// `replace` receives the attribute value and the enclosing tag name when known (`link`, `a`, …).
    private static func neutralize(
        attribute: String,
        in html: String,
        replace: (String, String?) -> String?
    ) -> String {
        var output = ""
        var remainder = html[...]
        let pattern = attribute + "="
        while let attrStart = remainder.range(of: pattern, options: .caseInsensitive) {
            let tag = enclosingTagName(before: attrStart.lowerBound, in: remainder)
            output += remainder[..<attrStart.lowerBound]
            let afterAttr = remainder[attrStart.upperBound...]
            guard let parsed = parseAttributeValue(afterAttr) else {
                output += remainder[attrStart]
                remainder = remainder[attrStart.upperBound...]
                continue
            }
            let rewritten = replace(parsed.value, tag) ?? parsed.value
            if let quote = parsed.quote {
                output += attribute + "=" + String(quote) + rewritten + String(quote)
            } else {
                output += attribute + "=" + rewritten
            }
            remainder = afterAttr[parsed.next...]
        }
        output += remainder
        return output
    }

    private static func enclosingTagName(before index: String.Index, in slice: Substring) -> String? {
        guard let open = slice[..<index].lastIndex(of: "<") else { return nil }
        var nameStart = slice.index(after: open)
        if nameStart < index, slice[nameStart] == "/" { nameStart = slice.index(after: nameStart) }
        var nameEnd = nameStart
        while nameEnd < index {
            let c = slice[nameEnd]
            if c.isWhitespace || c == ">" || c == "/" { break }
            nameEnd = slice.index(after: nameEnd)
        }
        guard nameEnd > nameStart else { return nil }
        return String(slice[nameStart..<nameEnd]).lowercased()
    }

    private struct ParsedValue {
        var value: String
        var next: String.Index
        var quote: Character?
    }

    private static func parseAttributeValue(_ afterAttr: Substring) -> ParsedValue? {
        guard let first = afterAttr.first else { return nil }
        if first == "\"" || first == "'" {
            let valueStart = afterAttr.index(after: afterAttr.startIndex)
            guard let valueEnd = afterAttr[valueStart...].firstIndex(of: first) else { return nil }
            return ParsedValue(
                value: String(afterAttr[valueStart..<valueEnd]),
                next: afterAttr.index(after: valueEnd),
                quote: first
            )
        }
        var end = afterAttr.startIndex
        while end < afterAttr.endIndex {
            let c = afterAttr[end]
            if c.isWhitespace || c == ">" { break }
            end = afterAttr.index(after: end)
        }
        guard end > afterAttr.startIndex else { return nil }
        return ParsedValue(value: String(afterAttr[afterAttr.startIndex..<end]), next: end, quote: nil)
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

    /// `@import "https://…"` / `@import '…'` without `url()` (`url(...)` is handled above).
    private static func neutralizeAtImports(in html: String) -> String {
        var output = ""
        var remainder = html[...]
        while let importStart = remainder.range(of: "@import", options: .caseInsensitive) {
            output += remainder[..<importStart.upperBound]
            var index = importStart.upperBound
            while index < remainder.endIndex, remainder[index].isWhitespace {
                output.append(remainder[index])
                index = remainder.index(after: index)
            }
            remainder = remainder[index...]
            guard let first = remainder.first, first == "\"" || first == "'" else { continue }
            let valueStart = remainder.index(after: remainder.startIndex)
            guard let valueEnd = remainder[valueStart...].firstIndex(of: first) else {
                output += remainder
                return output
            }
            let value = String(remainder[valueStart..<valueEnd])
            let rewritten = isRemoteURL(value) ? "about:blank" : value
            output += String(first) + rewritten + String(first)
            remainder = remainder[remainder.index(after: valueEnd)...]
        }
        output += remainder
        return output
    }
}
