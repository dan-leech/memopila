import Foundation
import Testing
@testable import MemopilaCore

@Suite("Text decoding (§7.4)")
struct TextDecodingTests {
    @Test func utf8Decoding() {
        #expect(TextDecoding.decode(utf8("héllo"), as: .utf8PlainText) == "héllo")
        #expect(TextDecoding.decode(Data([0xFF, 0xFE, 0xFD]), as: .utf8PlainText) == nil)
    }

    @Test func utf16WithoutBOMIsLittleEndian() {
        #expect(TextDecoding.decode(Data([0x68, 0x00, 0x69, 0x00]), as: .utf16PlainText) == "hi")
    }

    @Test func utf16HonorsBOM() {
        #expect(TextDecoding.decode(Data([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69]), as: .utf16PlainText) == "hi")
        #expect(TextDecoding.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]), as: .utf16PlainText) == "hi")
    }

    @Test func invalidUTF16HasNoIndex() {
        #expect(TextDecoding.decode(Data([0x00, 0xD8]), as: .utf16PlainText) == nil, "lone high surrogate")
        #expect(TextDecoding.decode(Data([0x68]), as: .utf16PlainText) == nil, "odd byte count")
    }

    @Test func capsCountUnicodeScalars() {
        #expect(TextDecoding.prefix("añb😀c", maxScalars: 4) == "añb😀")
        #expect(TextDecoding.prefix("ab", maxScalars: 300) == "ab")
    }

    @Test func singleWebURL() {
        #expect(TextDecoding.isSingleWebURL(" https://example.com/a?b=1 \n"))
        #expect(!TextDecoding.isSingleWebURL("see https://example.com"))
        #expect(!TextDecoding.isSingleWebURL("file:///tmp/a"))
        #expect(!TextDecoding.isSingleWebURL("docs/PLAN.md"))
    }
}

@Suite("Display type (§3.2)")
struct DisplayTypeTests {
    @Test func classes() {
        #expect(DisplayType.classify([CanonicalItem([.bytes(.utf8PlainText, utf8("docs/PLAN.md"))])]) == .text)
        #expect(DisplayType.classify([CanonicalItem([.bytes(.utf8PlainText, utf8("http://127.0.0.1:8088/page103"))])]) == .url)
        #expect(DisplayType.classify([CanonicalItem([.bytes(.rtf, Data()), .bytes(.utf8PlainText, utf8("a"))])]) == .richText)
        #expect(DisplayType.classify([CanonicalItem([.bytes(.png, Data())])]) == .image)
        #expect(DisplayType.classify([CanonicalItem([.bytes(.pdf, Data()), .bytes(.png, Data())])]) == .image)
        #expect(DisplayType.classify([CanonicalItem([.bytes(.color, Data())])]) == .color)
        #expect(DisplayType.classify([CanonicalItem([.files(.fileURL, ["/a"]), .bytes(.utf8PlainText, utf8("a"))])]) == .file)
        #expect(DisplayType.classify([CanonicalItem([.bytes(.png, Data())]), CanonicalItem([.bytes(.utf8PlainText, utf8("a"))])]) == .mixed)
    }
}

@Suite("Text actions (§3.9)")
struct TextActionTests {
    @Test func trimAndCase() {
        #expect(TextAction.trimWhitespace.apply(to: "  a b \n") == "a b")
        #expect(TextAction.uppercase.apply(to: "Привет, world") == "ПРИВЕТ, WORLD")
        #expect(TextAction.lowercase.apply(to: "ABC Ä") == "abc ä")
        #expect(TextAction.titleCase.apply(to: "hello big world") == "Hello Big World")
    }

    @Test func removeLineBreaks() {
        #expect(TextAction.removeLineBreaks.apply(to: "a\n  b\r\n\nc") == "a b c")
        #expect(TextAction.removeLineBreaks.apply(to: "single line") == nil)
    }

    @Test func sortAndDeduplicateKeepTrailingLineBreak() {
        #expect(TextAction.sortLines.apply(to: "b\na10\na2\n") == "a2\na10\nb\n")
        #expect(TextAction.removeDuplicateLines.apply(to: "x\ny\nx") == "x\ny")
        #expect(TextAction.sortLines.apply(to: "one") == nil)
    }

    @Test func formatJSONPreservesKeyOrderAndNumbers() {
        let pretty = TextAction.formatJSON.apply(to: #"{"z":1.50,"a":[1,{"k":"v, \"q\""}],"e":{},"l":[]}"#)
        #expect(pretty == """
        {
          "z": 1.50,
          "a": [
            1,
            {
              "k": "v, \\"q\\""
            }
          ],
          "e": {},
          "l": []
        }
        """)
    }

    @Test func formatJSONWithACombiningMarkAfterAQuote() {
        // A quote and a combining mark are one Character: strings and brackets swapped and the
        // depth went below zero (a crash).
        let json = "[\"\u{301}\", \"x]]\"]"
        #expect(TextAction.formatJSON.apply(to: json) == "[\n  \"\u{301}\",\n  \"x]]\"\n]")
        #expect(TextAction.minifyJSON.apply(to: json) == "[\"\u{301}\",\"x]]\"]")
    }

    @Test func minifyJSON() {
        #expect(TextAction.minifyJSON.apply(to: "{\n  \"a\" : [ 1, 2 ],\n  \"b\": \"x y\"\n}") == #"{"a":[1,2],"b":"x y"}"#)
    }

    @Test func invalidJSONIsUnavailable() {
        #expect(!TextAction.formatJSON.isAvailable(for: "{a:1}"))
        #expect(!TextAction.minifyJSON.isAvailable(for: "hello"))
    }

    @Test func urlEncoding() {
        #expect(TextAction.urlEncode.apply(to: "a b/c?d=é") == "a%20b%2Fc%3Fd%3D%C3%A9")
        #expect(TextAction.urlDecode.apply(to: "a%20b%2Fc") == "a b/c")
        #expect(TextAction.urlDecode.apply(to: "no escapes") == nil)
        #expect(TextAction.urlDecode.apply(to: "bad %ZZ") == nil)
    }

    @Test func base64() {
        #expect(TextAction.base64Encode.apply(to: "hi ü") == "aGkgw7w=")
        #expect(TextAction.base64Decode.apply(to: "aGkgw7w=\n") == "hi ü")
        #expect(TextAction.base64Decode.apply(to: "not base64!") == nil)
        #expect(TextAction.base64Decode.apply(to: "//79") == nil, "decodes to bytes that are not UTF-8")
    }
}

@Suite("Source page (§5.2)")
struct SourcePageTests {
    @Test func validation() {
        #expect(SourcePage.validatedURL(" https://example.com/x ") == "https://example.com/x")
        #expect(SourcePage.validatedURL("file:///tmp/a.html") == "file:///tmp/a.html")
        #expect(SourcePage.validatedURL("javascript:alert(1)") == nil)
        #expect(SourcePage.validatedURL("https://example.com/" + String(repeating: "a", count: 2048)) == nil)
    }

    @Test func webArchiveMainResourceURL() throws {
        let archive: [String: Any] = ["WebMainResource": ["WebResourceURL": "https://example.com/article", "WebResourceData": Data()]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        #expect(SourcePage.url(fromWebArchive: data) == "https://example.com/article")
        #expect(SourcePage.url(fromWebArchive: utf8("junk")) == nil)
    }

    @Test func host() {
        #expect(SourcePage.host(of: "https://www.example.com/a") == "www.example.com")
        #expect(SourcePage.host(of: "file:///tmp/a") == nil)
    }
}
