import AppKit
import CoreGraphics
import MemopilaCore
import Testing
@testable import MemopilaServices

@Suite("Image colour sample (§8.5 eyedropper)")
struct ImageColorSampleTests {
    @Test func opaquePixel() throws {
        let image = try #require(Self.image(width: 2, height: 2) { context, height in
            // Top-left origin for fills (y grows down).
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(Self.srgb(1, 0, 0))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.setFillColor(Self.srgb(0, 1, 0))
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        })
        let color = try #require(ImageColorSample.color(in: image, x: 0, y: 0))
        #expect(color.hex == "#FF0000")
        #expect(ImageColorSample.color(in: image, x: 1, y: 0)?.hex == "#00FF00")
    }

    @Test func outOfBoundsIsNil() throws {
        let image = try #require(Self.image(width: 1, height: 1) { context, height in
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(Self.srgb(0, 0, 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        })
        #expect(ImageColorSample.color(in: image, x: -1, y: 0) == nil)
        #expect(ImageColorSample.color(in: image, x: 0, y: 1) == nil)
    }

    @Test func fullyTransparentIsRejected() throws {
        let image = try #require(Self.image(width: 1, height: 1) { context, _ in
            context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        })
        #expect(ImageColorSample.color(in: image, x: 0, y: 0) == nil)
    }

    @Test func documentCoordinatesFlipY() throws {
        let image = try #require(Self.image(width: 2, height: 2) { context, height in
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(Self.srgb(1, 0, 0))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 1)) // top row
            context.setFillColor(Self.srgb(0, 0, 1))
            context.fill(CGRect(x: 0, y: 1, width: 2, height: 1)) // bottom row
        })
        // Document Y=0 is bottom → blue.
        let bottom = try #require(ImageColorSample.color(
            in: image, documentX: 0.5, documentY: 0.5, documentSize: CGSize(width: 2, height: 2)
        ))
        #expect(bottom.hex == "#0000FF")
        let top = try #require(ImageColorSample.color(
            in: image, documentX: 0.5, documentY: 1.5, documentSize: CGSize(width: 2, height: 2)
        ))
        #expect(top.hex == "#FF0000")
    }

    @Test func colorItemsIncludeColourAndHexForPaste() throws {
        let values = try #require(ColorValues(red: 255, green: 128, blue: 0, alpha: 255))
        let items = PasteboardWriter.colorItems(values)
        #expect(items.count == 1)
        #expect(DisplayType.classify(items) == .color)
        #expect(items[0].representations.map(\.type) == [.color, .utf8PlainText])
        let data = try #require(items[0].representations.first?.bytes)
        #expect(ColorHex.string(fromPasteboardColor: data) == "#FF8000")
        #expect(String(data: items[0].representations[1].bytes ?? Data(), encoding: .utf8) == "#FF8000")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(PasteboardWriter.write(items, sourceBundleID: nil, to: pasteboard) != .failed)
        #expect(pasteboard.string(forType: .string) == "#FF8000")
    }

    @Test func colorItemsUseChosenTextFormat() throws {
        let values = try #require(ColorValues(red: 255, green: 128, blue: 0, alpha: 255))
        for format in ColorPasteFormat.allCases {
            let items = PasteboardWriter.colorItems(values, textFormat: format)
            #expect(DisplayType.classify(items) == .color)
            #expect(items[0].representations.map(\.type) == [.color, .utf8PlainText])
            #expect(String(data: items[0].representations[1].bytes ?? Data(), encoding: .utf8) == format.string(from: values))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            #expect(PasteboardWriter.write(items, sourceBundleID: nil, to: pasteboard) != .failed)
            #expect(pasteboard.string(forType: .string) == format.string(from: values))
            #expect(pasteboard.data(forType: .color) != nil)
        }
    }

    @Test func colourOnlyPayloadSynthesizesHexOnWrite() throws {
        let colorData = try #require(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).pasteboardPropertyList(forType: .color) as? Data)
        let items = [CanonicalItem([.bytes(.color, colorData)])]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(PasteboardWriter.write(items, sourceBundleID: nil, to: pasteboard) != .failed)
        #expect(pasteboard.string(forType: .string) == "#00FF00")
    }

    @Test func identityReadsCanonicalHexAndPasteFormatFromPayload() throws {
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let rgb = PasteboardWriter.colorItems(values, textFormat: .rgb)
        let identity = try #require(ColorPayload.identity(of: rgb))
        #expect(identity.hex == "#AABBCC")
        #expect(identity.format == .rgb)
        #expect(ColorPayload.pastePlainText(of: rgb) == "rgb(170, 187, 204)")
        #expect(ColorPayload.identity(of: [CanonicalItem([.bytes(.utf8PlainText, Data("hi".utf8))])]) == nil)
    }

    @Test func ensuringPasteTextAlignsStoreHashWithWrite() throws {
        let colorData = try #require(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).pasteboardPropertyList(forType: .color) as? Data)
        let colourOnly = [CanonicalItem([.bytes(.color, colorData)])]
        let normalized = ColorPayload.ensuringPasteText(colourOnly)
        #expect(normalized[0].representations.map(\.type) == [.color, .utf8PlainText])
        #expect(String(data: normalized[0].representations[1].bytes ?? Data(), encoding: .utf8) == "#00FF00")
        #expect(ColorPayload.ensuringPasteText(normalized) == normalized)
        let withRGB = ColorPayload.replacingPasteText(in: normalized, text: "rgb(0, 255, 0)")
        #expect(String(data: withRGB[0].representations[1].bytes ?? Data(), encoding: .utf8) == "rgb(0, 255, 0)")
        #expect(withRGB == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#00FF00")), textFormat: .rgb))
        #expect(ColorPayload.identity(of: withRGB)?.format == .rgb)
    }

    @Test func loneHexTextPromotesToColorCard() throws {
        let text = [CanonicalItem([.bytes(.utf8PlainText, Data("#F0BF00".utf8))])]
        let promoted = ColorPayload.promotingLoneCSSColor(text)
        #expect(DisplayType.classify(promoted) == .color)
        #expect(promoted[0].representations.map(\.type) == [.color, .utf8PlainText])
        #expect(String(data: promoted[0].representations[1].bytes ?? Data(), encoding: .utf8) == "#F0BF00")
        #expect(ColorPayload.normalized(text) == promoted)
        #expect(ColorPayload.promotingLoneCSSColor([CanonicalItem([.bytes(.utf8PlainText, Data("not a colour".utf8))])]) .map(\.representations.first?.type) == [.utf8PlainText])
    }

    @Test func colorPickerAndHexTextShareCanonicalHash() throws {
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let fromText = ColorPayload.normalized([CanonicalItem([.bytes(.utf8PlainText, Data("#f0bf00".utf8))])])
        // System Color Picker / colour wells use sRGB archives; calibrated RGB is a different space
        // (same 0…1 numbers ≠ same HEX after conversion).
        let picker = try #require(
            NSColor(srgbRed: 240 / 255, green: 191 / 255, blue: 0, alpha: 1)
                .pasteboardPropertyList(forType: .color) as? Data
        )
        let fromPicker = ColorPayload.normalized([CanonicalItem([.bytes(.color, picker)])])
        let expected = PasteboardWriter.colorItems(values)
        #expect(MCS1.contentHash(of: fromText) == MCS1.contentHash(of: fromPicker))
        #expect(MCS1.contentHash(of: fromText) == MCS1.contentHash(of: expected))
        #expect(fromText == fromPicker)
        #expect(fromText == expected)
    }

    @Test func normalizedIsIdempotentForEveryPasteFormat() throws {
        let values = try #require(ColorValues(red: 30, green: 144, blue: 255, alpha: 128))
        for format in ColorPasteFormat.allCases {
            let items = PasteboardWriter.colorItems(values, textFormat: format)
            let once = ColorPayload.normalized(items)
            #expect(once == items, "colorItems(\(format)) must already be canonical")
            #expect(ColorPayload.normalized(once) == once)
            #expect(String(data: once[0].representations[1].bytes ?? Data(), encoding: .utf8) == format.string(from: values))
        }
    }

    @Test func normalizedKeepsHSLFormatWhenChannelsDrift() throws {
        // HSL↔RGB is lossy: requiring ColorValues equality used to rewrite these to HEX.
        let values = try #require(ColorValues(red: 0, green: 0, blue: 17))
        let hsl = values.hsl
        #expect(ColorValues(css: hsl) != values, "precondition: this RGB must drift through HSL")
        let items = PasteboardWriter.colorItems(values, textFormat: .hsl)
        let normalized = ColorPayload.normalized(items)
        #expect(normalized == items)
        #expect(String(data: normalized[0].representations[1].bytes ?? Data(), encoding: .utf8) == hsl)
    }

    @Test func normalizedKeepsHSLWhenPasteTextIsUTF16Only() throws {
        let values = try #require(ColorValues(red: 0, green: 0, blue: 17))
        let colorData = try #require(
            NSColor(srgbRed: 0, green: 0, blue: CGFloat(17) / 255, alpha: 1)
                .pasteboardPropertyList(forType: .color) as? Data
        )
        var bytes = Data()
        for unit in values.hsl.utf16 {
            var le = unit.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        let legacy = [CanonicalItem([
            .bytes(.color, colorData),
            .bytes(.utf16PlainText, bytes),
        ])]
        let normalized = ColorPayload.normalized(legacy)
        #expect(normalized == PasteboardWriter.colorItems(values, textFormat: .hsl))
    }

    @Test func chooseFormatPrefersPayloadWhenPickerStillAtOpenSeed() {
        #expect(ColorPayload.chooseFormat(picker: .hex, openTimePreview: "", payloadPlainText: "rgb(1, 2, 3)") == .rgb)
        #expect(ColorPayload.chooseFormat(picker: .hex, openTimePreview: "", payloadPlainText: "hsl(0, 0%, 0%)") == .hsl)
        #expect(ColorPayload.chooseFormat(picker: .hsl, openTimePreview: "", payloadPlainText: "rgb(1, 2, 3)") == .hsl, "user changed picker")
        #expect(ColorPayload.chooseFormat(picker: .rgb, openTimePreview: "rgb(1, 2, 3)", payloadPlainText: "rgb(1, 2, 3)") == .rgb)
        #expect(ColorPayload.chooseFormat(picker: .hex, openTimePreview: "#AA", payloadPlainText: nil) == .hex)
    }

    @Test func displayValuesPrefersPasteStringOverStaleHexCache() throws {
        let fromPaste = try #require(ColorPayload.displayValues(
            preview: "rgb(170, 187, 204)",
            colorHex: "#FF0000"
        ))
        #expect(fromPaste.hex == "#AABBCC")
        let fromCache = try #require(ColorPayload.displayValues(preview: "", colorHex: "#112233"))
        #expect(fromCache.hex == "#112233")
        #expect(ColorPayload.displayValues(preview: "not a colour", colorHex: nil) == nil)
    }

    /// As Cocoa writes RTF: tables first, then the body (same fixture as FormattingSignificanceTests).
    private static func cocoaRTF(_ body: String) -> Data {
        Data(("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n"
            + "{\\colortbl;\\red255\\green255\\blue255;\\red0\\green0\\blue0;}\n"
            + "\\pard\\tx560\\pardirnatural\\partightenfactor0\n\n" + body + "}").utf8)
    }

    @Test func promotingLoneCSSColorPromotesInsignificantRichChrome() throws {
        let items = [CanonicalItem([
            .bytes(.rtf, Self.cocoaRTF("\\f0\\fs24 \\cf0 #F0BF00")),
            .bytes(.utf8PlainText, Data("#F0BF00".utf8)),
        ])]
        #expect(!FormattingSignificance.isSignificant(items[0]))
        let promoted = ColorPayload.promotingLoneCSSColor(items)
        #expect(promoted == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#F0BF00"))))
        #expect(ColorPayload.normalized(items) == promoted)
    }

    @Test func promotingLoneCSSColorDoesNotStripSignificantRichText() throws {
        let items = [CanonicalItem([
            .bytes(.rtf, Self.cocoaRTF("\\f0\\fs24 \\cf0 plain {\\b #F0BF00} plain")),
            .bytes(.utf8PlainText, Data("#F0BF00".utf8)),
        ])]
        #expect(FormattingSignificance.isSignificant(items[0]))
        #expect(ColorPayload.promotingLoneCSSColor(items) == items)
        #expect(ColorPayload.normalized(items) == items)
    }

    @Test func promotingLoneCSSColorReadsHTMLOnlyChrome() throws {
        // No utf8 plain — only insignificant HTML carrying a lone CSS string.
        let html = #"<meta charset='utf-8'><span style="color: rgb(32, 33, 36); font-family: arial, sans-serif; font-size: 14px;">#F0BF00</span>"#
        let items = [CanonicalItem([.bytes(.html, Data(html.utf8))])]
        #expect(!FormattingSignificance.isSignificant(items[0]))
        #expect(TextDecoding.plainText(of: items) == nil)
        let promoted = ColorPayload.promotingLoneCSSColor(items)
        #expect(promoted == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#F0BF00"))))
    }

    @Test func documentCoordinatesClampToEdge() throws {
        let image = try #require(Self.image(width: 2, height: 1) { context, height in
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(Self.srgb(1, 0, 0))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.setFillColor(Self.srgb(0, 0, 1))
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        })
        let edge = try #require(ImageColorSample.color(
            in: image, documentX: 2, documentY: 0.5, documentSize: CGSize(width: 2, height: 1)
        ))
        #expect(edge.hex == "#0000FF")
    }

    @Test func translucentPremultipliedUnpremultiplies() throws {
        let image = try #require(Self.image(width: 1, height: 1) { context, _ in
            // Premul: RGB = 128, alpha = 128 → straight #FF000080 after unpremultiply.
            context.setFillColor(Self.srgb(1, 0, 0, 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        })
        let color = try #require(ImageColorSample.color(in: image, x: 0, y: 0))
        #expect(color.hex == "#FF000080")
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
    }

    private static func image(width: Int, height: Int, draw: (CGContext, Int) -> Void) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        draw(context, height)
        return context.makeImage()
    }
}
