import Testing
@testable import MemopilaCore

@Suite("HTML card preview (§8.2)")
struct HTMLPreviewTests {
    @Test func inlineStylesAndTags() {
        let preview = HTMLPreview.preview(of: #"<meta charset='utf-8'><span style="color: rgb(255, 0, 0); font-weight: 700">Red</span> and <i>italic</i> <a href="https://example.com">link</a>"#)
        #expect(preview.text == "Red and italic link")
        let red = preview.runs.first { $0.text == "Red" }
        #expect(red?.style.bold == true)
        #expect(red?.style.color == HTMLPreview.Color(red: 1, green: 0, blue: 0))
        #expect(preview.runs.first { $0.text == "italic" }?.style.italic == true)
        #expect(preview.runs.first { $0.text == "link" }?.style.link == true)
    }

    @Test func whitespaceCollapsesAndBlocksBreakLines() {
        let preview = HTMLPreview.preview(of: "<p>  One\n   two  </p><p>Three</p><ul><li>a</li><li>b</li></ul>line<br>next")
        #expect(preview.text == "One two\nThree\n• a\n• b\nline\nnext")
    }

    @Test func entitiesAreDecoded() {
        #expect(HTMLPreview.preview(of: "AT&amp;T &lt;tag&gt; &#8212; &#x41; &nbsp;x &bogus; R&D").text == "AT&T <tag> — A \u{00A0}x &bogus; R&D")
    }

    @Test func scriptsStylesAndCommentsAreSkipped() {
        let html = "<html><head><title>T</title><style>p { color: red }</style></head><body><!-- note --><script>var a = '<b>';</script><p>Text</p></body></html>"
        #expect(HTMLPreview.preview(of: html).text == "Text")
    }

    @Test func codeFromAnEditorKeepsItsPageAndIndentation() {
        // As VS Code copies it: the background on the outer block, white-space: pre.
        let html = #"<div style="color: #cccccc;background-color: #1f1f1f;font-family: Menlo, Monaco, 'Courier New', monospace;font-size: 12px;white-space: pre;"><div><span style="color: #569cd6;">let</span><span style="color: #cccccc;"> x = </span><span style="color: #b5cea8;">1</span></div><div><span>    return x</span></div></div>"#
        let preview = HTMLPreview.preview(of: html)
        #expect(preview.text == "let x = 1\n    return x")
        #expect(preview.runs.allSatisfy { $0.style.background == HTMLPreview.Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255) })
        #expect(preview.runs.allSatisfy { $0.style.monospace && $0.style.size == 12 })
    }

    @Test func bodyBackgroundIsThePage() {
        let preview = HTMLPreview.preview(of: ##"<body bgcolor="#000000"><p>Hi</p></body>"##)
        #expect(preview.pageBackground == HTMLPreview.Color(red: 0, green: 0, blue: 0))
        #expect(HTMLPreview.preview(of: "<p>Hi</p>").pageBackground == nil)
    }

    @Test func headingsAreLargerAndBold() {
        let heading = HTMLPreview.preview(of: "<h1>Title</h1>").runs.first
        #expect(heading?.style.size == 32)
        #expect(heading?.style.bold == true)
    }

    @Test func outputStopsAtTheLimit() {
        let html = "<p>" + String(repeating: "word ", count: 1_000) + "</p>"
        // "word " ten times and "wo".
        #expect(HTMLPreview.preview(of: html, maxCharacters: 52).text.count == 52)
    }

    @Test func malformedMarkupNeverHangs() {
        #expect(HTMLPreview.preview(of: "a < b <a =\"x\">c</a> <").text == "a < b c <")
        #expect(HTMLPreview.preview(of: "<div style=\"unterminated").text == "")
        #expect(HTMLPreview.preview(of: "<!-- open comment").text == "")
    }

    @Test func colors() {
        #expect(HTMLPreview.color("#fff") == HTMLPreview.Color(red: 1, green: 1, blue: 1))
        #expect(HTMLPreview.color("#00000080")?.alpha == 128.0 / 255)
        #expect(HTMLPreview.color("rgba(0, 0, 255, 0.5)") == HTMLPreview.Color(red: 0, green: 0, blue: 1, alpha: 0.5))
        #expect(HTMLPreview.color("rgb(0 128 0 / 100%)")?.green == 128.0 / 255)
        #expect(HTMLPreview.color("transparent") == nil)
        #expect(HTMLPreview.color("rgba(0, 0, 0, 0)") == nil)
        #expect(HTMLPreview.color("Navy") == HTMLPreview.Color(red: 0, green: 0, blue: 0.5))
    }
}
