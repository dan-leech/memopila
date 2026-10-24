import Quartz
import SwiftUI

/// A file's contents through Quick Look, as Finder shows them (PLAN §8.5). The preview exists only
/// while the view does and is closed with it, so it costs nothing once the window moves on.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // The initializer may fail; the container then stays empty.
        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.autostarts = true
            preview.previewItem = url as NSURL
            preview.frame = container.bounds
            preview.autoresizingMask = [.width, .height]
            container.addSubview(preview)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let preview = container.subviews.first as? QLPreviewView else { return }
        if (preview.previewItem as? NSURL) as URL? != url {
            preview.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        (container.subviews.first as? QLPreviewView)?.close()
    }
}
