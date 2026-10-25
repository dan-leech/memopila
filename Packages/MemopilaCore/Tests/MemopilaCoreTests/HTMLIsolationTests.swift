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

    @Test func should_blank_base_href_and_relative_img() {
        let html = #"<base href="https://tracker.example/"><img src="/pixel.png">"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"href="about:blank""#))
        #expect(out.contains(#"src="about:blank""#))
        #expect(!out.contains("tracker.example"))
        #expect(!out.contains("/pixel.png"))
    }

    @Test func should_blank_path_relative_subresource() {
        let html = #"<img src="/healthz.png"><link rel="stylesheet" href="../a.css">"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"src="about:blank""#))
        #expect(out.contains(#"href="about:blank""#))
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

    @Test func should_blank_body_background_and_object_data() {
        let html = #"<body background="https://evil.example/bg.gif"><object data="https://evil.example/x.swf"></object>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"background="about:blank""#))
        #expect(out.contains(#"data="about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_blank_svg_image_and_use_href() {
        let html = #"<svg><image href="https://evil.example/a.png"></image><use href="https://evil.example/icon.svg#i"></use></svg>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"href="about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_blank_svg_xlink_href() {
        let html = #"<svg><image xlink:href="https://evil.example/a.png"></image></svg>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"xlink:href="about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_neutralize_meta_http_equiv_refresh() {
        let html = #"<meta http-equiv="refresh" content="0;url=https://evil.example/"><p>Hi</p>"#
        let out = HTMLIsolation.strippingRemoteLoads(html)
        #expect(out.contains(#"content="0""#))
        #expect(!out.contains("evil.example"))
        #expect(out.contains("<p>Hi</p>"))
    }

    @Test func should_keep_data_urls() {
        let html = #"<img src="data:image/png;base64,aaa">"#
        #expect(HTMLIsolation.strippingRemoteLoads(html) == html)
    }

    @Test func should_keep_url_when_keeping_allows() {
        let html = #"<img src="https://example.com/local.png"><img src="https://evil.example/x.png">"#
        let out = HTMLIsolation.strippingRemoteLoads(html, keeping: { $0 == "https://example.com/local.png" })
        #expect(out.contains(#"src="https://example.com/local.png""#))
        #expect(out.contains(#"src="about:blank""#))
        #expect(!out.contains("evil.example"))
    }
}
