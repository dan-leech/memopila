import AppKit
import Observation
import SwiftUI

/// Zoom state of the image in the record window (§8.5): Fit, Actual Size, ⌘+ / ⌘− / ⌘0, pinch.
@MainActor
@Observable
final class ImageZoom {
    /// Shown in the toolbar; follows pinches and scroll-zooms too.
    private(set) var percent = 100
    private(set) var isFitted = true
    @ObservationIgnored fileprivate weak var scrollView: NSScrollView?

    func fit() {
        guard let scrollView, let image = scrollView.documentView else { return }
        let available = scrollView.contentSize
        let size = image.frame.size
        guard size.width > 0, size.height > 0 else { return }
        // Never larger than actual pixels: a small image is not blown up to fill the window.
        let scale = min(available.width / size.width, available.height / size.height, actualScale)
        scrollView.magnification = max(scale, scrollView.minMagnification)
        isFitted = true
        update()
    }

    /// One image pixel per screen pixel.
    func actualSize() {
        scrollView?.magnification = actualScale
        isFitted = false
        update()
    }

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(scrollView.magnification * factor, centeredAt: center)
        isFitted = false
        update()
    }

    fileprivate func update() {
        guard let scrollView else { return }
        let value = Int((scrollView.magnification / actualScale * 100).rounded())
        if value != percent { percent = value }
    }

    fileprivate func userZoomed() {
        isFitted = false
        update()
    }

    /// The image view's size is in pixels; on a Retina screen a pixel is half a point.
    private var actualScale: CGFloat {
        1 / (scrollView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }
}

/// The image at any zoom, scrollable, centered while smaller than the window, on the background
/// Preview and Quick Look use. No checkerboard under transparency: a window screenshot's wide
/// transparent shadow margin showed as a strange patterned frame (first-run feedback).
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let zoom: ImageZoom

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Drawn, so the area around a small image is cleared while zooming instead of smearing.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = NSRect(origin: .zero, size: Self.pixelSize(of: image))
        scrollView.documentView = imageView
        zoom.scrollView = scrollView
        context.coordinator.observe(scrollView, zoom: zoom)
        // Fit once the scroll view has its size.
        Task { @MainActor in zoom.fit() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView, imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: Self.pixelSize(of: image))
        zoom.fit()
    }

    private static func pixelSize(of image: NSImage) -> NSSize {
        if let representation = image.representations.first, representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []

        @MainActor
        func observe(_ scrollView: NSScrollView, zoom: ImageZoom) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak zoom] _ in
                MainActor.assumeIsolated { zoom?.userZoomed() }
            })
            // A fitted image follows the window's size.
            scrollView.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak zoom] _ in
                MainActor.assumeIsolated {
                    if zoom?.isFitted == true { zoom?.fit() }
                }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Keeps a document smaller than the visible area in the middle instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}
