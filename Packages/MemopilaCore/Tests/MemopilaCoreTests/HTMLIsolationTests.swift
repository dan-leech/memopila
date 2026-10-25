import Testing
@testable import MemopilaCore

@Suite("HTML isolation (§9)")
struct HTMLIsolationTests {
    @Test func remoteImagesAndStylesheetsAreBlanked() {
        let html = #"<img src="https://evil.example/x.png"><link rel="stylesheet" href="https://evil.example/a.css"><p>Hi</p>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"src="about:blank""#))
        #expect(out.contains(#"href="about:blank""#))
        #expect(out.contains("<p>Hi</p>"))
        #expect(!out.contains("evil.example"))
    }

    @Test func relativeAnchorHrefsAreKept() {
        let html = #"<a href="/healthz">/healthz</a>"#
        #expect(HTMLIsolation.strippingRemoteLoads(html) == html)
    }

    @Test func remoteCSSURLsAreBlanked() {
        let html = #" <span style="background: url('https://evil.example/bg.png')">x</span>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains("url('about:blank')"))
        #expect(!out.contains("evil.example"))
    }

    @Test func dataURLsStay() {
        let html = #"<img src="data:image/png;base64,aaa">"#
        #expect(HTMLIsolation.strippingRemoteLoads(html) == html)
    }
}
