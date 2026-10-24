import Foundation

/// Whether the formatting a copy carries says anything (PLAN §3.2). Browsers, Terminal, Notes and
/// code editors put RTF or HTML on the pasteboard for nearly every copy — one plain sentence, one
/// command — so a copy counts as rich text only with bold, italic, underline, strike-through,
/// links, images, lists or tables, or more than one font, size, colour or background. One font in
/// one colour is plain text; its RTF and HTML are still kept and pasted (owner feedback: far too
/// much was shown as formatted).
public enum FormattingSignificance {
    /// Larger formatted text is taken as formatted without reading it.
    public static let maxScannedBytes = 256 * 1_024

    /// The item's RTF, else its HTML; other formats (RTFD, web archives) always count.
    public static func isSignificant(_ item: CanonicalItem) -> Bool {
        if let rtf = item.representations.first(where: { $0.type == .rtf })?.bytes { return isSignificant(rtf: rtf) }
        if let html = item.representations.first(where: { $0.type == .html })?.bytes {
            guard html.count <= maxScannedBytes else { return true }
            return isSignificant(html: String(decoding: html, as: UTF8.self))
        }
        return true
    }

    public static func isSignificant(html: String) -> Bool {
        let preview = HTMLPreview.preview(of: html, maxCharacters: 20_000)
        if preview.hasStructure { return true }
        var sizes = Set<Double>()
        var colors = Set<HTMLPreview.Color?>()
        var backgrounds = Set<HTMLPreview.Color?>()
        var monospace = Set<Bool>()
        for run in preview.runs where run.text.contains(where: { !$0.isWhitespace }) {
            let style = run.style
            if style.bold || style.italic || style.underline || style.strikethrough || style.link { return true }
            sizes.insert(style.size)
            colors.insert(style.color)
            backgrounds.insert(style.background)
            monospace.insert(style.monospace)
        }
        return sizes.count > 1 || colors.count > 1 || backgrounds.count > 1 || monospace.count > 1
    }

    /// A small RTF scan: groups, control words and text, without the font and colour tables or
    /// other destinations. Anything that does not look like RTF counts as formatted.
    public static func isSignificant(rtf data: Data) -> Bool {
        guard data.count <= maxScannedBytes else { return true }
        let bytes = [UInt8](data)
        guard bytes.starts(with: Array("{\\rtf".utf8)) else { return true }
        var state = RTFState()
        var stack: [RTFState] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                stack.append(state)
                index += 1
            case UInt8(ascii: "}"):
                if let outer = stack.popLast() { state = outer }
                index += 1
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { break }
                let next = bytes[index]
                if isLetter(next) {
                    var word = ""
                    while index < bytes.count, isLetter(bytes[index]) {
                        word.append(Character(Unicode.Scalar(bytes[index])))
                        index += 1
                    }
                    var parameter: Int?
                    var negative = false
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
                        negative = true
                        index += 1
                    }
                    var digits = 0
                    while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]), digits < 10 {
                        parameter = (parameter ?? 0) * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                        digits += 1
                        index += 1
                    }
                    if negative { parameter = parameter.map { -$0 } }
                    // One space ends a control word and is not text.
                    if index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
                    guard !state.skipping else { continue }
                    if word == "u" { state.noteText() }
                    if apply(word, parameter: parameter, to: &state) { return true }
                } else {
                    index += 1
                    switch next {
                    case UInt8(ascii: "*"): state.skipping = true
                    case UInt8(ascii: "'"):
                        // \'hh: one character.
                        index = min(index + 2, bytes.count)
                        if !state.skipping { state.noteText() }
                    case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "~"):
                        if !state.skipping { state.noteText() }
                    default: break
                    }
                }
            case UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: " "), UInt8(ascii: "\t"):
                index += 1
            default:
                if !state.skipping { state.noteText() }
                index += 1
            }
        }
        return state.used.fonts.count > 1 || state.used.sizes.count > 1
            || state.used.colors.count > 1 || state.used.backgrounds.count > 1
    }

    /// What a control word does to the scan; `true` when it is formatting on its own.
    private static func apply(_ word: String, parameter: Int?, to state: inout RTFState) -> Bool {
        let on = (parameter ?? 1) != 0
        switch word {
        case "fonttbl", "colortbl", "stylesheet", "info", "listtable", "listoverridetable", "rsidtbl", "generator",
             "themedata", "colorschememapping", "datastore", "latentstyles", "xmlnstbl", "pgdsctbl", "expandedcolortbl",
             "header", "footer", "headerl", "headerr", "footerl", "footerr", "fldinst":
            state.skipping = true
        case "b", "i", "ul", "uld", "uldb", "ulw", "ulwave", "ulth", "strike", "striked", "super", "sub", "scaps", "caps":
            return on
        case "field", "pict", "object", "shppict", "trowd", "listtext", "pntext", "ls", "NeXTGraphic", "attachment":
            return true
        case "f": state.font = parameter ?? 0
        case "fs": state.size = parameter ?? 24
        case "cf": state.color = parameter ?? 0
        case "cb", "highlight", "chcbpat": state.background = parameter ?? 0
        case "plain":
            state.size = 24
            state.color = 0
            state.background = 0
        default: break
        }
        return false
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    /// The character formatting in force, and what text has used so far (shared by every group).
    private struct RTFState {
        var font = 0
        var size = 24
        var color = 0
        var background = 0
        var skipping = false
        var used = Used()

        final class Used {
            var fonts = Set<Int>()
            var sizes = Set<Int>()
            var colors = Set<Int>()
            var backgrounds = Set<Int>()
        }

        func noteText() {
            used.fonts.insert(font)
            used.sizes.insert(size)
            used.colors.insert(color)
            used.backgrounds.insert(background)
        }
    }
}
