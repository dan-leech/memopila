import AppKit
import MemopilaCore

/// Restores colours, span backgrounds and link destinations that WebKit/AppKit drop when reading
/// HTML (§3.6). Uses the same `HTMLPreview` walk as the card — Isolation blanks subresources first;
/// this paints what the importer lost. Kept separate from `RichPage` (page colour policy).
enum MarkupColorRestore {
    /// Colours, span backgrounds and link destinations the card already shows via `HTMLPreview`,
    /// applied onto WebKit/AppKit's reading of the same HTML: a parent `<font color>` around a
    /// link becomes default blue there, relative `href`s are dropped, and remote loads were
    /// blanked for privacy. Walks preview runs in order and paints matching substrings.
    static func restoreMarkupColors(html: String, into text: NSMutableAttributedString) {
        let preview = HTMLPreview.preview(of: html, maxCharacters: max(text.length, 1))
        let haystack = text.string as NSString
        var searchStart = 0
        for run in preview.runs {
            guard !run.text.isEmpty else { continue }
            let scope = NSRange(location: searchStart, length: max(0, haystack.length - searchStart))
            guard scope.length > 0 else { break }
            let found = haystack.range(of: run.text, options: [], range: scope)
            guard found.location != NSNotFound else { continue }
            searchStart = NSMaxRange(found)
            let color = run.style.color.map {
                NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
            }
            let background = run.style.background.map {
                NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
            }
            let href = run.style.link ? run.style.href : nil
            text.enumerateAttributes(in: found, options: []) { attributes, range, _ in
                if let color {
                    let current = attributes[.foregroundColor] as? NSColor
                    let needsPaint = run.style.link
                        || current == nil
                        || current.map(RichPage.isImporterDefaultLinkBlue) == true
                    if needsPaint {
                        text.addAttribute(.foregroundColor, value: color, range: range)
                    }
                }
                if let background, attributes[.backgroundColor] == nil {
                    text.addAttribute(.backgroundColor, value: background, range: range)
                }
                if let href, !href.isEmpty {
                    text.addAttribute(.link, value: linkValue(href), range: range)
                }
            }
        }
    }

    /// Absolute `http(s)` URLs as `URL`; relative paths (e.g. `/healthz`) as `String` so AppKit
    /// still marks the run as a link after the importer dropped them.
    private static func linkValue(_ href: String) -> Any {
        if let url = URL(string: href), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        return href
    }

    /// Links with no colour of their own (or only the importer's default blue) get the system
    /// link colour, as the card does when `foregroundColor` is missing.
    static func paintUncoloredLinks(in text: NSMutableAttributedString) {
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
            guard attributes[.link] != nil else { return }
            let current = attributes[.foregroundColor] as? NSColor
            if let current, !RichPage.isImporterDefaultLinkBlue(current) { return }
            text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
    }
}
