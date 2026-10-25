import Foundation
import Testing
@testable import MemopilaCore

@Suite("Web archive HTML (§3.6, §9)")
struct WebArchiveHTMLTests {
    @Test func should_extract_main_html_from_archive() throws {
        let html = #"<html><body><p>Hello</p><img src="https://evil.example/x.png"></body></html>"#
        let data = try fixtureArchive(mainHTML: html, url: "https://example.com/page")
        #expect(WebArchiveHTML.mainHTML(from: data) == html)
        #expect(WebArchiveHTML.mainResourceURL(from: data) == "https://example.com/page")
    }

    @Test func should_strip_remote_loads_inside_archive_html() throws {
        let html = #"<html><body><a href="https://example.com/ok">ok</a><img src="https://evil.example/x.png"></body></html>"#
        let data = try fixtureArchive(mainHTML: html, url: "https://example.com/page")
        let cleaned = try #require(WebArchiveHTML.strippingRemoteLoads(inWebArchive: data))
        let out = try #require(WebArchiveHTML.mainHTML(from: cleaned))
        #expect(out.contains(#"href="https://example.com/ok""#))
        #expect(out.contains(#"src="about:blank""#))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_keep_archive_local_absolute_and_relative_subresources() throws {
        let html = #"""
        <html><body>
        <img src="https://example.com/kept.png">
        <img src="/kept.png">
        <img src="/missing.png">
        <a href="https://example.com/page">stay</a>
        </body></html>
        """#
        let data = try fixtureArchive(
            mainHTML: html,
            url: "https://example.com/page",
            subresources: [(mime: "image/png", url: "https://example.com/kept.png", text: "PNG")]
        )
        let cleaned = try #require(WebArchiveHTML.strippingRemoteLoads(inWebArchive: data))
        let out = try #require(WebArchiveHTML.mainHTML(from: cleaned))
        #expect(out.contains(#"src="https://example.com/kept.png""#))
        #expect(out.contains(#"src="/kept.png""#), "relative that resolves to a local WebResourceURL is kept")
        #expect(out.contains(#"src="about:blank""#))
        #expect(!out.contains("/missing.png"))
        #expect(out.contains(#"href="https://example.com/page""#))
    }

    @Test func should_strip_remote_loads_in_css_subresource() throws {
        let css = #"@import "https://evil.example/x.css"; body{background:url(https://evil.example/bg.png)}"#
        let data = try fixtureArchive(
            mainHTML: "<html><body>x</body></html>",
            url: "https://example.com/",
            subresources: [(mime: "text/css; charset=utf-8", url: "https://example.com/a.css", text: css)]
        )
        let cleaned = try #require(WebArchiveHTML.strippingRemoteLoads(inWebArchive: data))
        let root = try #require(try PropertyListSerialization.propertyList(from: cleaned, format: nil) as? [String: Any])
        let subs = try #require(root["WebSubresources"] as? [[String: Any]])
        let cssData = try #require(subs.first?["WebResourceData"] as? Data)
        let out = String(decoding: cssData, as: UTF8.self)
        #expect(out.contains(#"@import "about:blank""#))
        #expect(out.contains("url(about:blank)"))
        #expect(!out.contains("evil.example"))
    }

    @Test func should_keep_css_url_pointing_at_local_subresource() throws {
        let css = #"body{background:url(https://example.com/bg.png)}"#
        let data = try fixtureArchive(
            mainHTML: "<html><body>x</body></html>",
            url: "https://example.com/",
            subresources: [
                (mime: "text/css", url: "https://example.com/a.css", text: css),
                (mime: "image/png", url: "https://example.com/bg.png", text: "PNG"),
            ]
        )
        let cleaned = try #require(WebArchiveHTML.strippingRemoteLoads(inWebArchive: data))
        let root = try #require(try PropertyListSerialization.propertyList(from: cleaned, format: nil) as? [String: Any])
        let subs = try #require(root["WebSubresources"] as? [[String: Any]])
        let cssRow = try #require(subs.first { ($0["WebResourceURL"] as? String) == "https://example.com/a.css" })
        let out = String(decoding: try #require(cssRow["WebResourceData"] as? Data), as: UTF8.self)
        #expect(out.contains("url(https://example.com/bg.png)"))
    }

    @Test func should_return_nil_for_invalid_plist() {
        #expect(WebArchiveHTML.mainHTML(from: Data("not a plist".utf8)) == nil)
        #expect(WebArchiveHTML.strippingRemoteLoads(inWebArchive: Data("not a plist".utf8)) == nil)
    }

    private func fixtureArchive(
        mainHTML: String,
        url: String,
        subresources: [(mime: String, url: String, text: String)] = []
    ) throws -> Data {
        var root: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(mainHTML.utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceURL": url,
                "WebResourceFrameName": "",
                "WebResourceTextEncodingName": "UTF-8",
            ] as [String: Any],
        ]
        if !subresources.isEmpty {
            root["WebSubresources"] = subresources.map { sub in
                [
                    "WebResourceData": Data(sub.text.utf8),
                    "WebResourceMIMEType": sub.mime,
                    "WebResourceURL": sub.url,
                    "WebResourceTextEncodingName": "UTF-8",
                ] as [String: Any]
            }
        }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
}
