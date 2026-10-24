import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility is used only to paste a chosen item (§3.4) and, once granted, for source window
/// titles (§5.2). Memopila prompts for it only when the user asks (banner, Settings).
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
            External.open(url)
        }
    }

    /// Presses ⌘V in the frontmost app, as clipboard managers commonly do. The flags are set
    /// explicitly, so ⇧ still held from ⇧↩ does not turn it into Paste and Match Style.
    @MainActor
    static func paste() {
        guard isTrusted else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// The key that types `character` in the current Latin layout: ⌘V is on another key with
    /// Dvorak or AZERTY-like layouts. With a non-Latin layout (Russian) apps read shortcuts through
    /// the Latin layout that goes with it, which is the one asked for here.
    @MainActor
    private static func keyCode(producing character: Character) -> CGKeyCode? {
        guard let target = character.unicodeScalars.first?.value,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              // `kTISPropertyUnicodeKeyLayoutData`, by value: the imported global is not concurrency-safe.
              let pointer = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            let maxLength = 4
            for code in 0..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: maxLength)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, maxLength, &length, &characters
                )
                if status == noErr, length == 1, UInt32(characters[0]) == target { return CGKeyCode(code) }
            }
            return nil
        }
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
        let element = unsafeDowncast(window, to: AXUIElement.self)
        // The window answers separately: without its own timeout a hung app held capture ~6 s.
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard AXUIElementCopyAttributeValue(element, "AXTitle" as CFString, &title) == .success,
              let title = title as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }
}
