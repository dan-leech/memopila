import Quartz
import SwiftUI

/// A file's contents through Quick Look, as Finder shows them (PLAN §8.5). The preview exists only
/// while the view does and is closed with it, so it costs nothing once the window moves on.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    /// A closed preview must never get another item: Quick Look asserts on it.
    final class Coordinator {
        var isClosed = false
        /// The file shown; compared instead of `previewItem`, which a failed load may clear.
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // The initializer may fail; the container then stays empty.
        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            // Closed here with the view, not by the window: the record window is kept and reused,
            // and a preview the window had closed crashed when SwiftUI updated it (first-run bug).
            preview.shouldCloseWithWindow = false
            preview.autostarts = true
            preview.previewItem = url as NSURL
            context.coordinator.url = url
            preview.frame = container.bounds
            preview.autoresizingMask = [.width, .height]
            container.addSubview(preview)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard !context.coordinator.isClosed, context.coordinator.url != url,
              let preview = container.subviews.first as? QLPreviewView else { return }
        context.coordinator.url = url
        preview.previewItem = url as NSURL
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.isClosed = true
        (container.subviews.first as? QLPreviewView)?.close()
    }
}
