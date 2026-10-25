import Testing
@testable import MemopilaCore

@Suite("HTML isolation (§9)")
struct HTMLIsolationTests {
    @Test func should_blank_img_src_and_link_stylesheet_href() {
        let html = #"<img src="https://evil.example/x.png"><link rel="stylesheet" href="https://evil.example/a.css"><p>Hi</p>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"src="about:blank""#))
        #expect(out.contains(#"href="about:blank""#))
        #expect(out.contains("<p>Hi</p>"))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_preserve_anchor_https_href() {
        let html = #"<a href="https://example.com/healthz">/healthz</a>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"href="https://example.com/healthz""#))
    }

    @Test func should_preserve_relative_anchor_href() {
        let html = #"<a href="/healthz">/healthz</a>"#
        #expect(HTMLIsolation.strippingRemoteLoads(html) == html)
    }

    @Test func should_blank_base_href() {
        let html = #"<base href="https://tracker.example/"><img src="/pixel.png">"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"href="about:blank""#))
        #expect(!out.contains("tracker.example"))
    }

    @Test func should_blank_link_stylesheet_href() {
        let html = #"<link rel="stylesheet" href="https://evil.example/a.css">"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"href="about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_blank_remote_css_url() {
        let html = #" <span style="background: url('https://evil.example/bg.png')">x</span>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains("url('about:blank')"))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_blank_at_import_quoted() {
        let html = #"@import "https://evil.example/x.css"; .a{color:red}"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"@import "about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_blank_srcset() {
        let html = #"<img srcset="https://evil.example/a.png 1x, https://evil.example/b.png 2x">"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"srcset="about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_blank_unquoted_src() {
        let html = #"<img src=https://evil.example/x.png>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains("src=about:blank"))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_keep_data_urls() {
        let html = #"<img src="data:image/png;base64,aaa">"#
        #expect(HTMLIsolation.strippingRemoteLoads(html) == html)
    }
}
