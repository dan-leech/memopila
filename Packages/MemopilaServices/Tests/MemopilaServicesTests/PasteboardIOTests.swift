import AppKit
import MemopilaCore
import Testing
@testable import MemopilaServices

enum TestImages {
    static func png(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

@Suite("Pasteboard adapters (§3.2, §3.4)", .serialized)
struct PasteboardIOTests {
    @Test func restoreReplacesContentAndWritesTheSourceOnce() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("A", forType: .string)

        let items = [
            CanonicalItem([.bytes(.utf8PlainText, Data("B".utf8))]),
            CanonicalItem([.bytes(.utf8PlainText, Data("C".utf8))]),
        ]
        let result = PasteboardWriter.write(items, sourceBundleID: "com.example.app", to: pasteboard)
        guard case .written(let owned) = result else { Issue.record("\(result)"); return }
        #expect(owned == pasteboard.changeCount)
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(pasteboard.pasteboardItems?.first?.string(forType: .string) == "B")
        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) == "com.example.app")
    }

    @Test func fileListsExpandToOneURLEachWithTextOnTheFirst() {
        let items = [CanonicalItem([.bytes(.utf8PlainText, Data("names".utf8)), .files(.fileURL, ["/tmp/a b.txt", "/tmp/c.txt"])])]
        let pasteboardItems = PasteboardWriter.makeItems(items, sourceBundleID: nil)
        #expect(pasteboardItems.count == 2)
        #expect(pasteboardItems[0].string(forType: .fileURL) == "file:///tmp/a%20b.txt")
        #expect(pasteboardItems[0].string(forType: .string) == "names")
        #expect(pasteboardItems[1].string(forType: .fileURL) == "file:///tmp/c.txt")
        #expect(pasteboardItems[0].string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) == "")
    }

    @Test func readerOnANamedPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setString("com.example.app", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        pasteboard.writeObjects([item])

        let outcome = SnapshotReader(context: CaptureContext(ownBundleID: "io.github.dan-leech.Memopila")).read(GeneralPasteboardSource(pasteboard))
        guard case .captured(let snapshot) = outcome else { Issue.record("\(outcome)"); return }
        #expect(snapshot.identity == AppIdentity(bundleID: "com.example.app", source: .marker))
        #expect(TextDecoding.plainText(of: snapshot.items) == "hello")
    }

    @Test func enrichmentForImagesAndColors() throws {
        let png = try #require(TestImages.png(width: 1200, height: 600))
        let enrichment = IngestEnrichment.make(for: [CanonicalItem([.bytes(.png, png)])], sourceAppName: nil)
        #expect(enrichment.pixelWidth == 1200 && enrichment.pixelHeight == 600)
        let thumbnail = try #require(enrichment.thumbnail)
        let image = try #require(NSBitmapImageRep(data: thumbnail))
        #expect(max(image.pixelsWide, image.pixelsHigh) <= Thumbnailer.maxPixelSize)

        let colorData = try #require(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1).pasteboardPropertyList(forType: .color) as? Data)
        #expect(ColorHex.string(fromPasteboardColor: colorData) == "#FF8000")
    }

    @Test func richTextFallbacksForSearch() {
        let rtf = Data(#"{\rtf1\ansi Hello {\b bold}}"#.utf8)
        #expect(RichText.plainText(of: [CanonicalItem([.bytes(.rtf, rtf)])])?.contains("Hello bold") == true)
        #expect(RichText.plainText(of: [CanonicalItem([.bytes(.html, Data("<p>a &amp; <b>b</b></p>".utf8))])]) == "a & b")
    }
}
