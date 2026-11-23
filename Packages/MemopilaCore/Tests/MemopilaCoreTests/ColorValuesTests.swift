import Testing
@testable import MemopilaCore

@Suite("Colour values (§8.5)")
struct ColorValuesTests {
    @Test func opaqueColour() throws {
        let color = try #require(ColorValues(hex: "#1e90ff"))
        #expect(color.hex == "#1E90FF")
        #expect(color.rgb == "rgb(30, 144, 255)")
        #expect(color.hsl == "hsl(210, 100%, 56%)")
    }

    @Test func greysHaveNoHueOrSaturation() throws {
        #expect(ColorValues(hex: "FFFFFF")?.hsl == "hsl(0, 0%, 100%)")
        #expect(ColorValues(hex: "#808080")?.hsl == "hsl(0, 0%, 50%)")
    }

    @Test func transparencyIsKept() throws {
        let color = try #require(ColorValues(hex: "#00000080"))
        #expect(color.hex == "#00000080")
        #expect(color.rgb == "rgba(0, 0, 0, 0.5)")
        #expect(color.hsl == "hsla(0, 0%, 0%, 0.5)")
    }

    @Test func invalidHexIsRejected() {
        #expect(ColorValues(hex: "#12345") == nil)
        #expect(ColorValues(hex: "#GGGGGG") == nil)
    }

    @Test func rgbInitRoundTripsThroughHex() throws {
        let color = try #require(ColorValues(red: 30, green: 144, blue: 255))
        #expect(color.hex == "#1E90FF")
        #expect(ColorValues(hex: color.hex) == color)
    }

    @Test func rgbInitKeepsAlpha() throws {
        let color = try #require(ColorValues(red: 0, green: 0, blue: 0, alpha: 128))
        #expect(color.hex == "#00000080")
    }

    @Test func rgbInitRejectsOutOfRangeChannels() {
        #expect(ColorValues(red: -1, green: 0, blue: 0) == nil)
        #expect(ColorValues(red: 0, green: 0, blue: 256) == nil)
    }

    @Test func pasteFormatMatchesStoredText() {
        #expect(ColorPasteFormat.matching("#1E90FF") == .hex)
        #expect(ColorPasteFormat.matching("rgb(30, 144, 255)") == .rgb)
        #expect(ColorPasteFormat.matching("rgba(0, 0, 0, 0.5)") == .rgb)
        #expect(ColorPasteFormat.matching("hsl(210, 100%, 56%)") == .hsl)
        #expect(ColorPasteFormat.matching("  hsla(0, 0%, 0%, 0.5) ") == .hsl)
        #expect(ColorPasteFormat.matching("") == nil)
        #expect(ColorPasteFormat.matching("not a colour") == nil)
    }

    @Test func cssInitParsesLoneColourStrings() throws {
        let hex = try #require(ColorValues(css: "  #F0BF00 "))
        #expect(hex.hex == "#F0BF00")
        #expect(ColorValues(css: "F0BF00") == nil, "bare hex without # is not a CSS colour")
        #expect(ColorValues(css: "see #F0BF00") == nil)
        let rgb = try #require(ColorValues(css: "rgb(240, 191, 0)"))
        #expect(rgb.hex == "#F0BF00")
        let blue = try #require(ColorValues(hex: "#1E90FF"))
        let fromHsl = try #require(ColorValues(css: blue.hsl))
        // HSL↔RGB rounding may shift a channel by 1.
        #expect(abs(fromHsl.red - blue.red) <= 1)
        #expect(abs(fromHsl.green - blue.green) <= 1)
        #expect(abs(fromHsl.blue - blue.blue) <= 1)
    }
}
