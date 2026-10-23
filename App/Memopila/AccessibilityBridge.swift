import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility is used only for *Paste after restore* (§3.4) and, once granted, for source
/// window titles (§5.2). Memopila never prompts for it on its own.
enum AccessibilityBridge {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Memopila to Privacy & Security → Accessibility.
    @MainActor
    static func requestTrust() {
        // The key of `kAXTrustedCheckOptionPrompt`; the global itself is not concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts ⌘V to the app that was frontmost before the panel opened.
    @MainActor
    static func paste(to app: NSRunningApplication?) {
        guard isTrusted, let app, !app.isTerminated else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.postToPid(app.processIdentifier)
        up?.postToPid(app.processIdentifier)
    }

    /// Title of the app's focused window, with a short timeout so a hung app cannot stall capture.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXFocusedWindow" as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        // The type check above makes this cast safe.
        let element = unsafeBitCast(window, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(element, "AXTitle" as CFString, &title) == .success,
              let title = title as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }
}
