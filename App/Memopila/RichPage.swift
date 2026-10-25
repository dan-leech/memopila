import AppKit
import MemopilaCore
import SwiftUI

/// What formatted text is shown on (§8.5), in the record window and on its card alike:
/// - the background the copy names (its document background, or one on most of its text — a
///   styled web page, code from VS Code);
/// - a dark page for light text that names no background (code from a dark editor theme);
/// - else none: it follows the window, in inverted colours in Dark Mode (owner: a copy without a
///   background is expected in inverted colours, not as black text on a white page).
enum RichPage: Equatable {
    case explicit(NSColor)
    case dark
    case adaptive

    static var darkPageColor: NSColor { NSColor(white: 0.13, alpha: 1) }

    var color: NSColor? {
        switch self {
        case .explicit(let color): color
        case .dark: Self.darkPageColor
        case .adaptive: nil
        }
    }

    var isDark: Bool { color.map(Self.isDark) ?? false }

    static func of(_ text: NSAttributedString, documentBackground: NSColor?) -> RichPage {
        if let background = documentBackground?.usingColorSpace(.sRGB), background.alphaComponent > 0.5 {
            return .explicit(background)
        }
        let range = NSRange(location: 0, length: min(text.length, 100_000))
        guard range.length > 0 else { return .adaptive }
        var backgrounds: [Int: (color: NSColor, length: Int)] = [:]
        text.enumerateAttribute(.backgroundColor, in: range, options: []) { value, run, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { return }
            backgrounds[key(color), default: (color, 0)].length += run.length
        }
        if let top = backgrounds.values.max(by: { $0.length < $1.length }), top.length * 2 > range.length {
            return .explicit(top.color)
        }
        return isMostlyLight(text, in: range) ? .dark : .adaptive
    }

    static func isDark(_ color: NSColor) -> Bool {
        luminance(color) < 0.5
    }

    /// Dark Mode for a copy without a background: lightness inverted, hue kept — black reads as
    /// white, a dark blue link as light blue — as the record window's colour mapping does.
    static func inverted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // HSV to HSL, the lightness inverted, and back.
        let lightness = brightness * (1 - saturation / 2)
        let range = min(lightness, 1 - lightness)
        let slSaturation = range > 0 ? (brightness - lightness) / range : 0
        let inverted = 1 - lightness
        let newBrightness = inverted + slSaturation * min(inverted, 1 - inverted)
        let newSaturation = newBrightness > 0 ? 2 * (1 - inverted / newBrightness) : 0
        return NSColor(hue: hue, saturation: newSaturation, brightness: newBrightness, alpha: alpha)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    private static func key(_ color: NSColor) -> Int {
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }

    /// Most of the text has a light colour of its own.
    private static func isMostlyLight(_ text: NSAttributedString, in range: NSRange) -> Bool {
        var light = 0
        var dark = 0
        text.enumerateAttribute(.foregroundColor, in: range, options: []) { value, run, _ in
            // No colour of its own: black.
            guard let color = value as? NSColor else {
                dark += run.length
                return
            }
            if luminance(color) > 0.6 { light += run.length } else { dark += run.length }
        }
        return light > dark
    }

    /// AppKit's HTML importer paints unstyled (and some wrapped) links `#0000EE` / `#0000FF`
    /// instead of leaving them uncoloured or keeping a parent `font`/`span` colour.
    static func isImporterDefaultLinkBlue(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return red == 0 && green == 0 && (blue == 238 || blue == 255)
    }
}

/// The start of a record's formatted text for its card (§8.2), with the page it is shown on.
@MainActor
final class RichPreview {
    let text: NSAttributedString
    let page: RichPage
    private let scale: CGFloat
    private var cardTexts: [Bool: AttributedString] = [:]

    /// Enough for the lines a card shows.
    nonisolated static let characters = 600

    /// From `make`, off the main thread.
    init(start: NSAttributedString, page: RichPage) {
        text = start
        self.page = page
        // The size most of the text has becomes the card's 11.5 pt; headings stay larger.
        scale = 11.5 / Self.commonFontSize(of: start)
    }

    /// The page from the whole text, and its first characters without the blank lines copies often
    /// start with.
    nonisolated static func make(from text: NSAttributedString, documentBackground: NSColor?) -> (start: NSAttributedString, page: RichPage) {
        let page = RichPage.of(text, documentBackground: documentBackground)
        let string = text.string as NSString
        var location = 0
        while location < string.length, let scalar = Unicode.Scalar(string.character(at: location)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            location += 1
        }
        var end = min(string.length, location + characters)
        if end < string.length { end = string.rangeOfComposedCharacterSequence(at: end).location }
        guard end > location else { return (NSAttributedString(), page) }
        return (text.attributedSubstring(from: NSRange(location: location, length: end - location)), page)
    }

    /// As SwiftUI text: fonts scaled to the card, colours as the page says — the copy's own, in
    /// Dark Mode inverted when it names no background; links in the system's link colour.
    func cardText(dark: Bool) -> AttributedString {
        if let cached = cardTexts[dark] { return cached }
        var result = AttributedString()
        let mapsColors = page == .adaptive && dark
        let defaultColor: NSColor? = page == .adaptive ? nil : (page.isDark ? .white : .black)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
            var run = AttributedString((text.string as NSString).substring(with: range))
            if let font = attributes[.font] as? NSFont {
                let size = min(max(font.pointSize * scale, 8), 20)
                let sized = NSFont(descriptor: font.fontDescriptor, size: size) ?? .systemFont(ofSize: size)
                run.font = Font(sized as CTFont)
            } else {
                run.font = .system(size: 11.5)
            }
            let isLink = attributes[.link] != nil
            if let color = attributes[.foregroundColor] as? NSColor {
                run.foregroundColor = Color(nsColor: mapsColors ? RichPage.inverted(color) : color)
            } else if isLink {
                run.foregroundColor = Color(nsColor: .linkColor)
            } else if let defaultColor {
                run.foregroundColor = Color(nsColor: defaultColor)
            }
            if let background = attributes[.backgroundColor] as? NSColor {
                run.backgroundColor = Color(nsColor: mapsColors ? RichPage.inverted(background) : background)
            }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 || isLink { run.underlineStyle = .single }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { run.strikethroughStyle = .single }
            result += run
        }
        cardTexts[dark] = result
        return result
    }

    private static func commonFontSize(of text: NSAttributedString) -> CGFloat {
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            sizes[((value as? NSFont)?.pointSize ?? 12).rounded(), default: 0] += range.length
        }
        guard let common = sizes.max(by: { $0.value < $1.value })?.key, common > 0 else { return 12 }
        return common
    }
}
