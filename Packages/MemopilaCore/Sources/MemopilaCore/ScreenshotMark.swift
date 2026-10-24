import Foundation

/// macOS writes a screenshot as a PNG whose XMP packet says `exif:UserComment` = "Screenshot"
/// (PLAN §5): a mark of the capture itself, whichever app was in front when it was taken.
public enum ScreenshotMark {
    private static let mark = Data("UserComment>Screenshot<".utf8)

    /// Only the start of the PNG is searched: its metadata chunks come before the image data.
    public static func isScreenshot(png data: Data) -> Bool {
        data.prefix(64 * 1024).range(of: mark) != nil
    }
}
