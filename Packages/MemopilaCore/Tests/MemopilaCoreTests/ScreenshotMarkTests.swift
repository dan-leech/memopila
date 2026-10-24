import Foundation
import Testing
@testable import MemopilaCore

@Suite("Screenshot mark (§5)")
struct ScreenshotMarkTests {
    private static let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/">\
        <exif:PixelXDimension>1440</exif:PixelXDimension><exif:UserComment>Screenshot</exif:UserComment>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """

    private static func png(_ chunks: Data) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunks
    }

    @Test func screenshotXMPIsFound() {
        #expect(ScreenshotMark.isScreenshot(png: Self.png(Data("iTXtXML:com.adobe.xmp".utf8) + Data(Self.xmp.utf8))))
    }

    @Test func otherImagesAreNot() {
        #expect(!ScreenshotMark.isScreenshot(png: Self.png(Data("IHDR....IDAT".utf8))))
        #expect(!ScreenshotMark.isScreenshot(png: Self.png(Data("<exif:UserComment>Holiday</exif:UserComment>".utf8))))
    }

    @Test func onlyTheStartIsSearched() {
        let late = Self.png(Data(count: 70_000) + Data(Self.xmp.utf8))
        #expect(!ScreenshotMark.isScreenshot(png: late))
    }
}
