import Foundation

/// The start of an HTML copy as styled runs, for its card (PLAN §8.2): what a card can show —
/// bold, italic, underline, strike-through, monospace, links, colours, backgrounds and sizes —
/// without WebKit, so the grid never starts a web process or loads anything from the network.
/// The record window reads the full HTML with WebKit (§8.5).
public enum HTMLPreview {
    public struct Color: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    public struct Style: Equatable, Sendable {
        public var bold = false
        public var italic = false
        public var underline = false
        public var strikethrough = false
        public var monospace = false
        public var link = false
        /// `<pre>` or CSS `white-space: pre…`: spaces and line breaks are kept (code from editors).
        public var preservesWhitespace = false
        /// In CSS pixels; 16 is a browser's normal text.
        public var size: Double = 16
        public var color: Color?
        public var background: Color?

        public init() {}
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var style: Style
    }

    public struct Preview: Equatable, Sendable {
        public var runs: [Run]
        /// The `<body>` or `<html>` background: the page the copy was made on.
        public var pageBackground: Color?
        /// Lists, tables, images or quotes: structure a plain text loses.
        public var hasStructure = false

        public var text: String { runs.map(\.text).joined() }
    }

    public static func preview(of html: String, maxCharacters: Int = 600) -> Preview {
        var parser = Parser(scalars: Array(html.unicodeScalars), limit: maxCharacters)
        parser.run()
        return Preview(runs: parser.runs, pageBackground: parser.pageBackground, hasStructure: parser.hasStructure)
    }

    // MARK: - CSS colours

    /// `#rgb`, `#rrggbb` (with alpha), `rgb()` / `rgba()` and the common names; `nil` for anything
    /// else, `transparent` included.
    public static func color(_ value: String) -> Color? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") { return hexColor(String(text.dropFirst())) }
        if text.hasPrefix("rgb") {
            guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
            let parts = text[text.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map(String.init)
            guard parts.count >= 3, let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2]) else { return nil }
            let alpha = parts.count > 3 ? alphaValue(parts[3]) ?? 1 : 1
            return alpha > 0 ? Color(red: red, green: green, blue: blue, alpha: alpha) : nil
        }
        return namedColors[text]
    }

    private static func hexColor(_ digits: String) -> Color? {
        let expanded: String
        switch digits.count {
        case 3, 4: expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = digits
        default: return nil
        }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        guard alpha > 0 else { return nil }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: alpha)
    }

    private static func channel(_ text: String) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { min(max($0 / 100, 0), 1) } }
        return Double(text).map { min(max($0 / 255, 0), 1) }
    }

    private static func alphaValue(_ text: String) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { min(max($0 / 100, 0), 1) } }
        return Double(text).map { min(max($0, 0), 1) }
    }

    private static let namedColors: [String: Color] = [
        "black": Color(red: 0, green: 0, blue: 0),
        "white": Color(red: 1, green: 1, blue: 1),
        "red": Color(red: 1, green: 0, blue: 0),
        "green": Color(red: 0, green: 0.5, blue: 0),
        "blue": Color(red: 0, green: 0, blue: 1),
        "gray": Color(red: 0.5, green: 0.5, blue: 0.5),
        "grey": Color(red: 0.5, green: 0.5, blue: 0.5),
        "silver": Color(red: 0.75, green: 0.75, blue: 0.75),
        "maroon": Color(red: 0.5, green: 0, blue: 0),
        "purple": Color(red: 0.5, green: 0, blue: 0.5),
        "fuchsia": Color(red: 1, green: 0, blue: 1),
        "lime": Color(red: 0, green: 1, blue: 0),
        "olive": Color(red: 0.5, green: 0.5, blue: 0),
        "yellow": Color(red: 1, green: 1, blue: 0),
        "navy": Color(red: 0, green: 0, blue: 0.5),
        "teal": Color(red: 0, green: 0.5, blue: 0.5),
        "aqua": Color(red: 0, green: 1, blue: 1),
        "orange": Color(red: 1, green: 0.65, blue: 0),
    ]

    // MARK: - Parser

    private struct Parser {
        let scalars: [Unicode.Scalar]
        let limit: Int
        var index = 0
        var runs: [Run] = []
        var pageBackground: Color?
        var hasStructure = false
        private var count = 0
        private var stack: [(name: String, style: Style)] = []
        private var atLineStart = true

        init(scalars: [Unicode.Scalar], limit: Int) {
            self.scalars = scalars
            self.limit = limit
        }

        private var style: Style { stack.last?.style ?? Style() }
        private var preformatted: Bool { style.preservesWhitespace }

        private static let blocks: Set<String> = [
            "p", "div", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
            "blockquote", "section", "article", "header", "footer", "hr", "dl", "dt", "dd", "figure",
        ]
        private static let voids: Set<String> = [
            "br", "img", "hr", "meta", "link", "input", "wbr", "col", "area", "base", "source", "embed", "param", "track",
        ]
        /// Their content is never text to show.
        private static let skipped: Set<String> = ["script", "style", "head", "title", "noscript", "template", "svg", "math"]

        mutating func run() {
            while index < scalars.count, count < limit {
                if scalars[index] == "<" {
                    readMarkup()
                } else {
                    readText()
                }
            }
            // No blank lines or spaces after the text.
            while let last = runs.last?.text.last, last == " " || last == "\n" {
                removeLast()
            }
        }

        // MARK: Text

        private mutating func readText() {
            var text = String.UnicodeScalarView()
            while index < scalars.count, scalars[index] != "<" {
                if scalars[index] == "&" {
                    text.append(contentsOf: readEntity().unicodeScalars)
                } else {
                    text.append(scalars[index])
                    index += 1
                }
            }
            emit(String(text))
        }

        private mutating func readEntity() -> String {
            let start = index
            var end = index + 1
            while end < scalars.count, end - start < 12, scalars[end] != ";", scalars[end] != "&", scalars[end] != "<" { end += 1 }
            guard end < scalars.count, scalars[end] == ";" else {
                index += 1
                return "&"
            }
            let name = String(String.UnicodeScalarView(scalars[(start + 1)..<end]))
            index = end + 1
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
            }
            return Self.entities[name] ?? "&\(name);"
        }

        private static let entities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®",
            "trade": "™", "bull": "•", "middot": "·", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        ]

        /// Whitespace collapses to one space outside `<pre>`, and none starts a line, as a browser
        /// shows it.
        private mutating func emit(_ raw: String) {
            guard !raw.isEmpty else { return }
            if preformatted {
                append(raw)
                return
            }
            var collapsed = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar == "\u{0C}" {
                    let afterSpace = collapsed.last.map { $0 == " " } ?? (runs.last?.text.last == " ")
                    let lineStart = collapsed.isEmpty && atLineStart
                    if !afterSpace, !lineStart { collapsed.append(" ") }
                } else {
                    collapsed.append(scalar)
                }
            }
            if !collapsed.isEmpty { append(String(collapsed)) }
        }

        private mutating func removeLast() {
            guard !runs.isEmpty else { return }
            runs[runs.count - 1].text.removeLast()
            count -= 1
            if runs[runs.count - 1].text.isEmpty { runs.removeLast() }
            atLineStart = runs.last?.text.last.map { $0 == "\n" } ?? true
        }

        private mutating func append(_ text: String) {
            var text = text
            let room = limit - count
            guard room > 0 else { return }
            if text.count > room { text = String(text.prefix(room)) }
            count += text.count
            atLineStart = text.last == "\n"
            let style = style
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, style: style))
            }
        }

        /// A line ends: without the space before it, and never a second blank line.
        private mutating func newline() {
            if !preformatted, runs.last?.text.last == " " { removeLast() }
            guard !runs.isEmpty, !atLineStart else { return }
            append("\n")
        }

        // MARK: Markup

        private mutating func readMarkup() {
            // Comments, doctype and processing instructions.
            if matches("<!--") {
                index = find("-->").map { $0 + 3 } ?? scalars.count
                return
            }
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                index = find(">").map { $0 + 1 } ?? scalars.count
                return
            }
            var position = index + 1
            let closing = position < scalars.count && scalars[position] == "/"
            if closing { position += 1 }
            var name = String.UnicodeScalarView()
            while position < scalars.count, scalars[position].properties.isAlphabetic || ("0"..."9").contains(scalars[position]) {
                name.append(scalars[position])
                position += 1
            }
            guard !name.isEmpty else {
                // A lone "<" is text.
                index += 1
                emit("<")
                return
            }
            let tag = String(name).lowercased()
            let (attributes, selfClosing, end) = readAttributes(from: position)
            index = end
            if closing {
                close(tag)
            } else {
                open(tag, attributes: attributes, selfClosing: selfClosing)
            }
        }

        private mutating func open(_ tag: String, attributes: [String: String], selfClosing: Bool) {
            if Self.skipped.contains(tag) {
                if !selfClosing { skip(to: tag) }
                return
            }
            if tag == "br" {
                if !preformatted, runs.last?.text.last == " " { removeLast() }
                append("\n")
                return
            }
            if Self.blocks.contains(tag) { newline() }
            if ["li", "table", "img", "blockquote", "hr"].contains(tag) { hasStructure = true }
            if tag == "body" || tag == "html" {
                pageBackground = pageBackground ?? background(in: attributes)
            }
            guard !Self.voids.contains(tag), !selfClosing else { return }
            var style = style
            apply(tag, attributes: attributes, to: &style)
            stack.append((tag, style))
            if tag == "li" { append("• ") }
        }

        private mutating func close(_ tag: String) {
            guard let position = stack.lastIndex(where: { $0.name == tag }) else { return }
            stack.removeSubrange(position...)
            if Self.blocks.contains(tag) { newline() }
        }

        private mutating func skip(to tag: String) {
            let closing = Array("</\(tag)".unicodeScalars)
            while index < scalars.count {
                if scalars[index] == "<", index + closing.count <= scalars.count,
                   String(String.UnicodeScalarView(scalars[index..<(index + closing.count)])).lowercased() == String(String.UnicodeScalarView(closing)) {
                    index = find(">").map { $0 + 1 } ?? scalars.count
                    return
                }
                index += 1
            }
        }

        private func apply(_ tag: String, attributes: [String: String], to style: inout Style) {
            switch tag {
            case "b", "strong": style.bold = true
            case "i", "em", "cite", "var", "dfn": style.italic = true
            case "u", "ins": style.underline = true
            case "s", "strike", "del": style.strikethrough = true
            case "pre", "textarea": style.monospace = true; style.preservesWhitespace = true
            case "code", "kbd", "samp", "tt": style.monospace = true
            case "a" where attributes["href"] != nil: style.link = true
            case "h1": style.size *= 2; style.bold = true
            case "h2": style.size *= 1.5; style.bold = true
            case "h3": style.size *= 1.17; style.bold = true
            case "h4", "h5", "h6", "th", "dt": style.bold = true
            case "small", "sub", "sup": style.size *= 0.83
            case "big": style.size *= 1.2
            case "mark": style.background = Color(red: 1, green: 1, blue: 0)
            case "font":
                if let color = attributes["color"].flatMap(HTMLPreview.color) { style.color = color }
            default: break
            }
            if let color = attributes["bgcolor"].flatMap(HTMLPreview.color) { style.background = color }
            if let css = attributes["style"] { applyCSS(css, to: &style) }
        }

        private func applyCSS(_ css: String, to style: inout Style) {
            for declaration in css.split(separator: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = declaration[declaration.index(after: colon)...]
                    .replacingOccurrences(of: "!important", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let lowered = value.lowercased()
                switch property {
                case "color":
                    if let color = HTMLPreview.color(value) { style.color = color }
                case "background-color", "background":
                    if let color = firstColor(in: value) { style.background = color }
                case "font-weight":
                    if lowered == "bold" || lowered == "bolder" || (Int(lowered) ?? 0) >= 600 {
                        style.bold = true
                    } else if lowered == "normal" || lowered == "lighter" || (Int(lowered) ?? 600) < 600 {
                        style.bold = false
                    }
                case "font-style":
                    style.italic = lowered.contains("italic") || lowered.contains("oblique")
                case "text-decoration", "text-decoration-line":
                    if lowered.contains("underline") { style.underline = true }
                    if lowered.contains("line-through") { style.strikethrough = true }
                    if lowered == "none" { style.underline = false; style.strikethrough = false }
                case "font-family":
                    let monospaced = ["mono", "menlo", "monaco", "courier", "consolas", "sf mono", "source code"]
                    if monospaced.contains(where: lowered.contains) { style.monospace = true }
                case "font-size":
                    if let size = fontSize(lowered, parent: style.size) { style.size = size }
                case "white-space":
                    style.preservesWhitespace = lowered.hasPrefix("pre") || lowered == "break-spaces"
                default:
                    break
                }
            }
        }

        private func firstColor(in value: String) -> Color? {
            // `background: #1e1e1e url(…) no-repeat`: the colour part; rgb() keeps its spaces.
            if let color = HTMLPreview.color(value) { return color }
            if let start = value.range(of: "rgb"), let end = value[start.lowerBound...].firstIndex(of: ")") {
                return HTMLPreview.color(String(value[start.lowerBound...end]))
            }
            return value.split(separator: " ").lazy.compactMap { HTMLPreview.color(String($0)) }.first
        }

        private func fontSize(_ value: String, parent: Double) -> Double? {
            let named: [String: Double] = ["xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32]
            if let size = named[value] { return size }
            func number(_ suffix: String) -> Double? {
                value.hasSuffix(suffix) ? Double(value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) : nil
            }
            let size: Double? = number("px") ?? number("pt").map { $0 * 4 / 3 } ?? number("rem").map { $0 * 16 }
                ?? number("em").map { $0 * parent } ?? number("%").map { $0 / 100 * parent }
            return size.map { min(max($0, 6), 96) }
        }

        private func background(in attributes: [String: String]) -> Color? {
            if let color = attributes["bgcolor"].flatMap(HTMLPreview.color) { return color }
            var style = Style()
            if let css = attributes["style"] { applyCSS(css, to: &style) }
            return style.background
        }

        /// Attributes up to the end of the tag, quotes respected; `/>` closes it.
        private func readAttributes(from start: Int) -> ([String: String], Bool, Int) {
            var attributes: [String: String] = [:]
            var position = start
            var selfClosing = false
            func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" }
            while position < scalars.count {
                let before = position
                let scalar = scalars[position]
                if scalar == ">" { return (attributes, selfClosing, position + 1) }
                if scalar == "/" {
                    selfClosing = true
                    position += 1
                    continue
                }
                if isSpace(scalar) {
                    position += 1
                    continue
                }
                selfClosing = false
                var name = String.UnicodeScalarView()
                while position < scalars.count, !isSpace(scalars[position]), scalars[position] != "=", scalars[position] != ">", scalars[position] != "/" {
                    name.append(scalars[position])
                    position += 1
                }
                while position < scalars.count, isSpace(scalars[position]) { position += 1 }
                var value = ""
                if position < scalars.count, scalars[position] == "=" {
                    position += 1
                    while position < scalars.count, isSpace(scalars[position]) { position += 1 }
                    var characters = String.UnicodeScalarView()
                    if position < scalars.count, scalars[position] == "\"" || scalars[position] == "'" {
                        let quote = scalars[position]
                        position += 1
                        while position < scalars.count, scalars[position] != quote {
                            characters.append(scalars[position])
                            position += 1
                        }
                        position += 1
                    } else {
                        while position < scalars.count, !isSpace(scalars[position]), scalars[position] != ">" {
                            characters.append(scalars[position])
                            position += 1
                        }
                    }
                    value = String(characters)
                }
                if !name.isEmpty { attributes[String(name).lowercased()] = value }
                // A stray "=" or quote: never stuck on it.
                if position == before { position += 1 }
            }
            return (attributes, selfClosing, scalars.count)
        }

        private func matches(_ text: String) -> Bool {
            let pattern = Array(text.unicodeScalars)
            guard index + pattern.count <= scalars.count else { return false }
            return scalars[index..<(index + pattern.count)].elementsEqual(pattern)
        }

        private func find(_ text: String) -> Int? {
            let pattern = Array(text.unicodeScalars)
            var position = index
            while position + pattern.count <= scalars.count {
                if scalars[position..<(position + pattern.count)].elementsEqual(pattern) { return position }
                position += 1
            }
            return nil
        }
    }
}
