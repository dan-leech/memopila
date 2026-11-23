import CoreGraphics
import MemopilaCore

/// Exact pixel colour from a preview `CGImage` (eyedropper, PLAN §8.5).
///
/// Always resolves to sRGB: a fast path reads bytes only for 8-bit premulLast sRGB;
/// otherwise one pixel is drawn into an sRGB premulLast buffer (no interpolation).
public enum ImageColorSample {
    /// Document / AppKit Y grows up; `CGImage` Y grows down.
    public static func color(in image: CGImage, documentX: CGFloat, documentY: CGFloat, documentSize: CGSize) -> ColorValues? {
        guard documentSize.width > 0, documentSize.height > 0 else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let x = min(width - 1, max(0, Int((documentX / documentSize.width * CGFloat(width)).rounded(.down))))
        let yFromBottom = min(height - 1, max(0, Int((documentY / documentSize.height * CGFloat(height)).rounded(.down))))
        let y = height - 1 - yFromBottom
        return color(in: image, x: x, y: y)
    }

    /// `x`/`y` in CGImage pixel coordinates (origin top-left). Fully transparent → `nil`.
    public static func color(in image: CGImage, x: Int, y: Int) -> ColorValues? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        if let direct = readPremultipliedSRGB(from: image, x: x, y: y) {
            return values(fromPremultiplied: direct)
        }
        return values(fromPremultiplied: drawPremultipliedSRGB(from: image, x: x, y: y))
    }

    private static func values(fromPremultiplied pixel: (r: Int, g: Int, b: Int, a: Int)?) -> ColorValues? {
        guard let pixel, pixel.a > 0 else { return nil }
        if pixel.a == 255 {
            return ColorValues(red: pixel.r, green: pixel.g, blue: pixel.b, alpha: 255)
        }
        let red = min(255, Int((Double(pixel.r) * 255 / Double(pixel.a)).rounded()))
        let green = min(255, Int((Double(pixel.g) * 255 / Double(pixel.a)).rounded()))
        let blue = min(255, Int((Double(pixel.b) * 255 / Double(pixel.a)).rounded()))
        return ColorValues(red: red, green: green, blue: blue, alpha: pixel.a)
    }

    /// Bytes only when already 8-bit **premultipliedLast** sRGB RGBA — otherwise `nil` (draw path).
    private static func readPremultipliedSRGB(from image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32 else { return nil }
        guard image.alphaInfo == .premultipliedLast else { return nil }
        guard let name = image.colorSpace?.name, name == CGColorSpace.sRGB else { return nil }
        let byteOrder = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        guard byteOrder == [] || byteOrder == .byteOrder32Big else { return nil }
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 3 < CFDataGetLength(data) else { return nil }
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    /// Draw one source pixel into a known sRGB premulLast buffer (handles P3 / straight alpha / odd layouts).
    private static func drawPremultipliedSRGB(from image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.setBlendMode(.copy)
        let height = image.height
        context.draw(
            image,
            in: CGRect(x: -CGFloat(x), y: CGFloat(y - (height - 1)), width: CGFloat(image.width), height: CGFloat(height))
        )
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), Int(pixel[3]))
    }
}
