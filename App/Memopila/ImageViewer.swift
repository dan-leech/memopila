import AppKit
import CoreGraphics
import MemopilaCore
import MemopilaServices
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
    let cgImage: CGImage?
    let zoom: ImageZoom
    var isPicking: Bool = false
    var onHover: ((ColorValues?) -> Void)?
    var onPicked: ((ColorValues) -> Void)?

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
        let imageView = PickingImageView()
        imageView.image = image
        imageView.cgImage = cgImage
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = NSRect(origin: .zero, size: Self.pixelSize(of: image))
        scrollView.documentView = imageView
        zoom.scrollView = scrollView
        context.coordinator.observe(scrollView, zoom: zoom)
        context.coordinator.bind(imageView, parent: self)
        // Fit once the scroll view has its size.
        Task { @MainActor in zoom.fit() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? PickingImageView else { return }
        context.coordinator.bind(imageView, parent: self)
        if imageView.image !== image {
            imageView.image = image
            imageView.cgImage = cgImage
            imageView.frame = NSRect(origin: .zero, size: Self.pixelSize(of: image))
            zoom.fit()
        } else {
            imageView.cgImage = cgImage
        }
        imageView.isPicking = isPicking
        imageView.window?.invalidateCursorRects(for: imageView)
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

        @MainActor
        fileprivate func bind(_ imageView: PickingImageView, parent: ZoomableImage) {
            imageView.isPicking = parent.isPicking
            imageView.cgImage = parent.cgImage
            imageView.onHover = parent.onHover
            imageView.onPicked = parent.onPicked
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Image document that can sample pixels while the eyedropper is armed.
private final class PickingImageView: NSImageView {
    var cgImage: CGImage?
    var isPicking = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            if !isPicking {
                onHover?(nil)
                downPoint = nil
            }
        }
    }
    var onHover: ((ColorValues?) -> Void)?
    var onPicked: ((ColorValues) -> Void)?

    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    private static let dragThreshold: CGFloat = 4

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        if isPicking {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            super.resetCursorRects()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isPicking else { return super.mouseMoved(with: event) }
        onHover?(sample(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isPicking, event.type == .leftMouseDown else { return super.mouseDown(with: event) }
        // Consume the click so it does not start a drag-pan; scroll wheel / pinch still work.
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPicking else { return super.mouseDragged(with: event) }
        // Ignore drag while picking: a drag past the threshold cancels the pin on mouseUp.
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard isPicking, event.type == .leftMouseUp, let start = downPoint else {
            return super.mouseUp(with: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        // Click without drag → pin; a drag was a cancelled pan attempt, not a sample.
        guard hypot(point.x - start.x, point.y - start.y) < Self.dragThreshold else { return }
        if let color = sample(at: point) {
            onPicked?(color)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isPicking else { return }
        super.rightMouseDown(with: event)
    }

    private func sample(at point: NSPoint) -> ColorValues? {
        guard let cgImage, bounds.width > 0, bounds.height > 0 else { return nil }
        return ImageColorSample.color(
            in: cgImage,
            documentX: point.x,
            documentY: point.y,
            documentSize: bounds.size
        )
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
