import Quartz
import SwiftUI

/// A file's contents through Quick Look, as Finder shows them (PLAN §8.5). The preview exists only
/// while the view does and is closed with it, so it costs nothing once the window moves on.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = (QLPreviewView(frame: .zero, style: .normal) as QLPreviewView?) ?? QLPreviewView(frame: .zero)
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
