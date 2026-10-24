import Foundation
import Testing
@testable import MemopilaCore

@Suite("Formatting that says something (§3.2)")
struct FormattingSignificanceTests {
    /// As Cocoa writes RTF: tables first, then the body.
    private static func rtf(_ body: String) -> Data {
        Data(("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;\\f1\\fnil\\fcharset0 Menlo-Regular;}\n"
            + "{\\colortbl;\\red255\\green255\\blue255;\\red242\\green242\\blue242;\\red0\\green0\\blue0;}\n"
            + "{\\*\\expandedcolortbl;;\\cssrgb\\c95686\\c95686\\c95686;\\csgray\\c0;}\n"
            + "\\pard\\tx560\\tx1120\\pardirnatural\\partightenfactor0\n\n" + body + "}").utf8)
    }

    @Test func oneFontInOneColourIsPlain() {
        #expect(!FormattingSignificance.isSignificant(rtf: Self.rtf("\\f0\\fs24 \\cf0 Hello, world.\\\n Second line.")))
        // Terminal: one font, one colour, one background.
        #expect(!FormattingSignificance.isSignificant(rtf: Self.rtf("\\f1\\fs22 \\cf2 \\cb3 \\CocoaLigature0 ls -la ~/Desktop")))
        // Switched off explicitly.
        #expect(!FormattingSignificance.isSignificant(rtf: Self.rtf("\\f0\\b0\\i0\\fs24 \\cf0 \\ul0 text")))
    }

    @Test func styledRTFIsFormatted() {
        #expect(FormattingSignificance.isSignificant(rtf: Self.rtf("\\f0\\fs24 \\cf0 plain {\\b bold} plain")))
        #expect(FormattingSignificance.isSignificant(rtf: Self.rtf("\\f0\\fs24 \\cf2 let \\cf3 x")))
        #expect(FormattingSignificance.isSignificant(rtf: Self.rtf("\\f0\\fs24 Title\\\n\\fs18 body")))
        #expect(FormattingSignificance.isSignificant(rtf: Self.rtf("\\f0 sans \\f1 mono")))
        #expect(FormattingSignificance.isSignificant(rtf: Self.rtf(#"{\field{\*\fldinst{HYPERLINK "https://example.com"}}{\fldrslt link}}"#)))
    }

    @Test func notRTFCountsAsFormatted() {
        #expect(FormattingSignificance.isSignificant(rtf: Data()))
        #expect(FormattingSignificance.isSignificant(rtf: Data("plain".utf8)))
    }

    @Test func html() {
        // As Chrome copies one sentence: a single styled span.
        let sentence = #"<meta charset='utf-8'><span style="color: rgb(32, 33, 36); font-family: arial, sans-serif; font-size: 14px; font-weight: 400; background-color: rgb(255, 255, 255);">One plain sentence.</span>"#
        #expect(!FormattingSignificance.isSignificant(html: sentence))
        #expect(FormattingSignificance.isSignificant(html: "<p>Some <b>bold</b> text</p>"))
        #expect(FormattingSignificance.isSignificant(html: #"<p>See <a href="https://example.com">this</a></p>"#))
        #expect(FormattingSignificance.isSignificant(html: "<ul><li>one</li><li>two</li></ul>"))
        #expect(FormattingSignificance.isSignificant(html: #"<span style="color: #569cd6">let</span><span style="color: #cccccc"> x</span>"#))
        #expect(FormattingSignificance.isSignificant(html: "<h1>Title</h1><p>Body</p>"))
    }

    @Test func classification() {
        func item(_ rich: (PasteboardType, Data)?, plain: String? = "text") -> [CanonicalItem] {
            var representations: [CanonicalRepresentation] = []
            if let rich { representations.append(.bytes(rich.0, rich.1)) }
            if let plain { representations.append(.bytes(.utf8PlainText, Data(plain.utf8))) }
            return [CanonicalItem(representations)]
        }
        #expect(DisplayType.classify(item((.rtf, Self.rtf("\\f0\\fs24 \\cf0 text")))) == .text)
        #expect(DisplayType.classify(item((.rtf, Self.rtf("\\f0\\fs24 {\\b text}")))) == .richText)
        #expect(DisplayType.classify(item((.html, Data("<span>https://example.com</span>".utf8)), plain: "https://example.com")) == .url)
        // Without plain text the formatting is all there is to show.
        #expect(DisplayType.classify(item((.rtf, Self.rtf("\\f0\\fs24 \\cf0 text")), plain: nil)) == .richText)
    }
}
