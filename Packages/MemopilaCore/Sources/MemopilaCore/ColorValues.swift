import Foundation

/// Which CSS string accompanies a colour UTI on the pasteboard (PLAN §8.5).
public enum ColorPasteFormat: String, Sendable, Equatable, CaseIterable, Identifiable {
    case hex
    case rgb
    case hsl

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        }
    }

    public func string(from values: ColorValues) -> String {
        switch self {
        case .hex: values.hex
        case .rgb: values.rgb
        case .hsl: values.hsl
        }
    }

    /// From a stored plain-text paste string (`#…`, `rgb(…)`, `hsl(…)`).
    public static func matching(_ text: String) -> ColorPasteFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rgba(") || lower.hasPrefix("rgb(") { return .rgb }
        if lower.hasPrefix("hsla(") || lower.hasPrefix("hsl(") { return .hsl }
        if trimmed.hasPrefix("#") || ColorValues(hex: trimmed) != nil { return .hex }
        return nil
    }
}

/// A stored colour (`#RRGGBB` or `#RRGGBBAA`) as HEX, RGB and HSL, written the way CSS does, for
/// the record window (PLAN §8.5).
public struct ColorValues: Sendable, Equatable {
    public let red: Int
    public let green: Int
    public let blue: Int
    /// 0…255; 255 = opaque.
    public let alpha: Int

    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        red = Int((value >> (hasAlpha ? 24 : 16)) & 0xFF)
        green = Int((value >> (hasAlpha ? 16 : 8)) & 0xFF)
        blue = Int((value >> (hasAlpha ? 8 : 0)) & 0xFF)
        alpha = hasAlpha ? Int(value & 0xFF) : 255
    }

    /// Channels 0…255; values outside that range are rejected.
    public init?(red: Int, green: Int, blue: Int, alpha: Int = 255) {
        let channels = [red, green, blue, alpha]
        guard channels.allSatisfy({ (0...255).contains($0) }) else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A lone CSS colour string: `#RRGGBB[AA]`, `rgb(…)`, `rgba(…)`, `hsl(…)`, `hsla(…)`.
    /// Used to promote a text-only paste into a Color card (like a lone URL → URL card).
    public init?(css: String) {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }
        if trimmed.hasPrefix("#"), let color = ColorValues(hex: trimmed) {
            self = color
            return
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rgba(") || lower.hasPrefix("rgb("), let color = Self.parseRGB(trimmed) {
            self = color
            return
        }
        if lower.hasPrefix("hsla(") || lower.hasPrefix("hsl("), let color = Self.parseHSL(trimmed) {
            self = color
            return
        }
        return nil
    }

    /// `rgb(30, 144, 255)` / `rgba(30, 144, 255, 0.5)` — integers 0…255, alpha 0…1.
    private static func parseRGB(_ text: String) -> ColorValues? {
        guard let body = cssFunctionBody(text, names: ["rgba", "rgb"]) else { return nil }
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4,
              let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { return nil }
        let alpha: Int
        if parts.count == 4 {
            guard let a = Double(parts[3]), (0...1).contains(a) else { return nil }
            alpha = Int((a * 255).rounded())
        } else {
            alpha = 255
        }
        return ColorValues(red: r, green: g, blue: b, alpha: alpha)
    }

    /// `hsl(210, 100%, 56%)` / `hsla(…, 0.5)` — H in degrees, S/L in %, alpha 0…1.
    private static func parseHSL(_ text: String) -> ColorValues? {
        guard let body = cssFunctionBody(text, names: ["hsla", "hsl"]) else { return nil }
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4,
              let h = Double(parts[0]),
              let s = cssPercent(parts[1]),
              let l = cssPercent(parts[2]) else { return nil }
        let alpha: Int
        if parts.count == 4 {
            guard let a = Double(parts[3]), (0...1).contains(a) else { return nil }
            alpha = Int((a * 255).rounded())
        } else {
            alpha = 255
        }
        let (r, g, b) = hslToRGB(h: h, s: s, l: l)
        return ColorValues(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func cssFunctionBody(_ text: String, names: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for name in names where lower.hasPrefix(name + "(") && trimmed.hasSuffix(")") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: name.count + 1)
            let end = trimmed.index(before: trimmed.endIndex)
            return String(trimmed[start..<end])
        }
        return nil
    }

    private static func cssPercent(_ text: String) -> Double? {
        guard text.hasSuffix("%"), let value = Double(text.dropLast()), (0...100).contains(value) else { return nil }
        return value / 100
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Int, Int, Int) {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let r = channel(p, q, hue + 1 / 3)
        let g = channel(p, q, hue)
        let b = channel(p, q, hue - 1 / 3)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private var isOpaque: Bool { alpha == 255 }

    /// `#1E90FF`, or `#1E90FF80` with transparency.
    public var hex: String {
        let channels = isOpaque ? [red, green, blue] : [red, green, blue, alpha]
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }

    /// `rgb(30, 144, 255)`, or `rgba(30, 144, 255, 0.5)`.
    public var rgb: String {
        isOpaque ? "rgb(\(red), \(green), \(blue))" : "rgba(\(red), \(green), \(blue), \(alphaText))"
    }

    /// `hsl(210, 100%, 56%)`, or `hsla(…, 0.5)`.
    public var hsl: String {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2
        var hue = 0.0
        var saturation = 0.0
        let delta = maximum - minimum
        if delta > 0 {
            saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
            switch maximum {
            case r: hue = (g - b) / delta + (g < b ? 6 : 0)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue *= 60
        }
        let h = Int(hue.rounded()) % 360
        let s = Int((saturation * 100).rounded())
        let l = Int((lightness * 100).rounded())
        return isOpaque ? "hsl(\(h), \(s)%, \(l)%)" : "hsla(\(h), \(s)%, \(l)%, \(alphaText))"
    }

    /// Up to two decimals, without trailing zeros: 0.5, 0.25, 1.
    private var alphaText: String {
        var text = String(format: "%.2f", Double(alpha) / 255)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
