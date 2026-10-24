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
}
