import AppKit
import Foundation
import MemopilaCore
import Testing
import WebKit

/// Proves Isolation + archive sanitize stop WebKit/`loadFromHTML` from fetching (§9).
/// A local HTTP server records hits; URLs point at it so DNS/CDN are not involved.
/// Skipped on GitHub Actions: WebKit/`loadFromHTML` is unreliable on hosted macOS runners
/// (Services job exits 1; Core `HTMLIsolationTests` still cover stripping). Run locally.
@Suite(
    "HTML isolation network sentinel (§9)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "WebKit sentinel is local-only")
)
@MainActor
struct HTMLIsolationNetworkTests {
    @Test func should_record_hit_when_fetching_without_isolation() async throws {
        let server = try await LocalHitServer.start()
        defer { server.stop() }
        let url = URL(string: "\(server.baseURL)/probe")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
        #expect(server.hits >= 1)
    }

    @Test func should_not_fetch_remote_img_after_isolation_loadFromHTML() async throws {
        let server = try await LocalHitServer.start()
        defer { server.stop() }
        // Confirm the sentinel is reachable, then clear the counter.
        _ = try await URLSession.shared.data(from: URL(string: "\(server.baseURL)/warmup")!)
        #expect(server.hits >= 1)
        server.resetHits()

        let html = #"<html><body><img src="\#(server.baseURL)/pixel.png"><a href="https://example.com/ok">ok</a></body></html>"#
        let cleaned = HTMLIsolation.strippingRemoteLoads(html)
        #expect(cleaned.contains(#"src="about:blank""#))
        #expect(cleaned.contains(#"href="https://example.com/ok""#))

        _ = await loadFromHTML(cleaned)
        try await Task.sleep(for: .milliseconds(800))
        #expect(server.hits == 0, "loadFromHTML must not contact the sentinel after Isolation")
    }

    @Test func should_not_fetch_when_loading_sanitized_web_archive() async throws {
        let server = try await LocalHitServer.start()
        defer { server.stop() }
        _ = try await URLSession.shared.data(from: URL(string: "\(server.baseURL)/warmup")!)
        server.resetHits()

        let html = #"""
        <html><body>
        <img src="\#(server.baseURL)/tracker.png">
        <img src="/missing-relative.png">
        <a href="\#(server.baseURL)/page">stay</a>
        </body></html>
        """#
        let archive = try fixtureArchive(mainHTML: html, url: "\(server.baseURL)/page")
        let sanitized = try #require(WebArchiveHTML.strippingRemoteLoads(inWebArchive: archive))
        let out = try #require(WebArchiveHTML.mainHTML(from: sanitized))
        #expect(out.contains(#"src="about:blank""#))
        #expect(!out.contains("tracker.png"))
        #expect(!out.contains("missing-relative"))

        // Same path as the editor: prefer sanitized archive load, then HTML fallback.
        if !loadWebArchive(sanitized) {
            _ = await loadFromHTML(out)
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(server.hits == 0, "sanitized web archive must not contact the sentinel")
    }

    @Test func should_not_fetch_css_url_or_import_after_isolation() async throws {
        let server = try await LocalHitServer.start()
        defer { server.stop() }
        _ = try await URLSession.shared.data(from: URL(string: "\(server.baseURL)/warmup")!)
        server.resetHits()

        let html = """
        <html><head><style>
        @import "\(server.baseURL)/x.css";
        body{background:url(\(server.baseURL)/bg.png)}
        </style></head><body>x</body></html>
        """
        let cleaned = HTMLIsolation.strippingRemoteLoads(html)
        #expect(cleaned.contains(#"@import "about:blank""#))
        #expect(cleaned.contains("url(about:blank)"))
        #expect(!cleaned.contains("/x.css"))
        #expect(!cleaned.contains("/bg.png"))
        _ = await loadFromHTML(cleaned)
        try await Task.sleep(for: .milliseconds(800))
        #expect(server.hits == 0)
    }

    /// `NSAttributedString` is not Sendable; wrap the callback payload like the app does.
    private struct Transfer<Value>: @unchecked Sendable {
        var value: Value
    }

    private func loadFromHTML(_ html: String) async -> NSAttributedString? {
        let data = Data(html.utf8)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Transfer<NSAttributedString?>, Never>) in
            NSAttributedString.loadFromHTML(
                data: data,
                options: [
                    .characterEncoding: String.Encoding.utf8.rawValue,
                    .timeout: 3,
                ]
            ) { text, _, _ in
                continuation.resume(returning: Transfer(value: text))
            }
        }
        return result.value
    }

    @discardableResult
    private func loadWebArchive(_ data: Data) -> Bool {
        var attributes: NSDictionary?
        let text = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.webArchive, .timeout: 2],
            documentAttributes: &attributes
        )
        return (text?.length ?? 0) > 0
    }

    private func fixtureArchive(mainHTML: String, url: String) throws -> Data {
        let root: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(mainHTML.utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceURL": url,
                "WebResourceFrameName": "",
                "WebResourceTextEncodingName": "UTF-8",
            ] as [String: Any],
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
}
