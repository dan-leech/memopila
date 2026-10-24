import Foundation

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
