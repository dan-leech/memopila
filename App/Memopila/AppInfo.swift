import AppKit
import MemopilaCore

/// App names and icons for source bundle IDs, cached for the process lifetime.
@MainActor
enum AppInfo {
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage?] = [:]

    static func name(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = names[bundleID] { return cached }
        let name = url(for: bundleID).map { url in
            let bundle = Bundle(url: url)
            return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        // Screenshot.app's icon reads poorly next to real app icons; use a capture symbol instead.
        let icon: NSImage?
        if bundleID == AppIdentity.screenshotApp {
            let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
            symbol?.size = NSSize(width: 32, height: 32)
            symbol?.isTemplate = true
            icon = symbol
        } else {
            icon = url(for: bundleID).map { url in
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 32, height: 32)
                return icon
            }
        }
        icons[bundleID] = icon
        return icon
    }

    /// Installed name, else the name saved with the record, else the bundle ID.
    static func displayName(for bundleID: String?, fallback: String? = nil) -> String {
        name(for: bundleID) ?? fallback ?? bundleID ?? String(localized: "Unknown app")
    }

    private static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

/// Moves a non-`Sendable` value whose ownership is handed over completely (e.g. a freshly made image).
struct Transfer<Value>: @unchecked Sendable {
    let value: Value
}
