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
        postCommandKey(producing: "v", fallback: CGKeyCode(kVK_ANSI_V))
    }

    /// Presses ⌘C in the frontmost app (layout convert). The keyUp carries **no** flags. Measured
    /// (scratch probe, 2026-11-26): the last posted event's flags stick in `flagsState(.hidSystemState)` *and*
    /// `keyState(kVK_Command)` for ≥1.5s, so a `.maskCommand` keyUp made our own pre-inject
    /// check see "⌘ held" → 400ms wait → "deliver failed" (HID ⌘ flipped true
    /// ~20ms after ⌘C with an all-clear state before it). A flagless event resets it within 5ms.
    @MainActor
    static func copy() {
        postCommandKey(producing: "c", fallback: CGKeyCode(kVK_ANSI_C), keyUpFlags: [])
    }

    /// ⌘V for layout convert (Monaco auto-surround/close would mangle typed `[ ' "`): keyUp
    /// carries no flags so our own ⌘ does not stick in `hidSystemState` (same as `copy()`).
    @MainActor
    static func pasteForLayoutConvert() {
        postCommandKey(producing: "v", fallback: CGKeyCode(kVK_ANSI_V), keyUpFlags: [])
    }

    /// Extends the selection left by `count` UTF-16 units (⇧← × N). Used when AX has no focused
    /// field (Electron/Cursor) so TIS clearing the highlight can be undone from the caret.
    @MainActor
    static func selectLeft(characters count: Int) {
        postArrow(key: CGKeyCode(kVK_LeftArrow), count: count, flags: .maskShift)
    }

    @MainActor
    static func selectRight(characters count: Int) {
        postArrow(key: CGKeyCode(kVK_RightArrow), count: count, flags: .maskShift)
    }

    /// Collapse an active selection to its end (→ without Shift).
    @MainActor
    static func collapseSelectionToEnd() {
        postArrow(key: CGKeyCode(kVK_RightArrow), count: 1, flags: [])
    }

    /// ⌫ once (terminal delivery: delete the typed mistype before retyping it).
    @MainActor
    static func deleteBackward() {
        postArrow(key: CGKeyCode(kVK_Delete), count: 1, flags: [])
    }

    /// Move the caret right without extending the selection.
    @MainActor
    static func moveRight(characters count: Int) {
        postArrow(key: CGKeyCode(kVK_RightArrow), count: count, flags: [])
    }

    /// Move the caret left without extending the selection.
    @MainActor
    static func moveLeft(characters count: Int) {
        postArrow(key: CGKeyCode(kVK_LeftArrow), count: count, flags: [])
    }

    /// Select from the caret to the start of the line (⌘⇧←). Used for word-at-caret in
    /// Electron/Cursor where ⌥⇧← is a subword (a cold start selected one letter).
    @MainActor
    static func selectToLineStart() {
        postArrow(
            key: CGKeyCode(kVK_LeftArrow),
            count: 1,
            flags: [.maskCommand, .maskShift],
            upFlags: []
        )
    }

    /// Session-combined source (Maccy / VaulType / bilingual-switcher). Every event carries
    /// explicit flags; the WindowServer does not merge the user's still-held ⌥⌘ into them
    /// (receiver proof, PLAN §3.9.1), so posting right on the hotkey's keyDown is safe.
    nonisolated(unsafe) private static let eventSource: CGEventSource? =
        CGEventSource(stateID: .combinedSessionState)
    private static let eventTap = CGEventTapLocation.cghidEventTap
    /// `CGEventKeyboardSetUnicodeString` hard limit per event.
    private static let unicodeChunkLimit = 20

    @MainActor
    private static func postArrow(key: CGKeyCode, count: Int, flags: CGEventFlags, upFlags: CGEventFlags? = nil) {
        guard isTrusted, count > 0 else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false)
            else { return }
            down.flags = flags
            up.flags = upFlags ?? flags
            down.post(tap: eventTap)
            up.post(tap: eventTap)
        }
    }

    /// Types `string` as Unicode key events. With a live selection this *replaces* it in Cocoa
    /// and Chromium/Electron — no clipboard paste (bilingual-switcher / RuSwitcher).
    /// Posts keyDown+keyUp per chunk; packs scalars so surrogate pairs are not split.
    @MainActor
    static func injectUnicode(_ string: String) async {
        guard isTrusted, !string.isEmpty else { return }
        let chunks = chunkUTF16(string, maxCodeUnits: unicodeChunkLimit)
        for (offset, chunk) in chunks.enumerated() {
            postUnicodeEvent(chunk, keyDown: true)
            postUnicodeEvent(chunk, keyDown: false)
            if offset + 1 < chunks.count {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    @MainActor
    private static func postUnicodeEvent(_ chunk: [UniChar], keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: keyDown) else {
            return
        }
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        event.post(tap: eventTap)
    }

    /// Surrogate-pair-safe UTF-16 chunking (bilingual-switcher).
    static func chunkUTF16(_ string: String, maxCodeUnits: Int) -> [[UniChar]] {
        guard maxCodeUnits > 0, !string.isEmpty else { return [] }
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maxCodeUnits)
        for scalar in string.unicodeScalars {
            let value = scalar.value
            let needed = value <= 0xFFFF ? 1 : 2
            guard needed <= maxCodeUnits else { continue }
            if current.count + needed > maxCodeUnits {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            if value <= 0xFFFF {
                current.append(UniChar(value))
            } else {
                let shifted = value - 0x10000
                current.append(UniChar(0xD800 + (shifted >> 10)))
                current.append(UniChar(0xDC00 + (shifted & 0x3FF)))
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// ⌘C/⌘V — Maccy model: letter down/up with `.maskCommand` only (no synthetic Cmd
    /// down/up). A Cmd-up chord while the user still holds ⌘ from ⌥⌘B desyncs Electron HID.
    @MainActor
    private static func postCommandKey(
        producing character: String,
        fallback: CGKeyCode,
        keyUpFlags: CGEventFlags = .maskCommand
    ) {
        guard isTrusted else { return }
        let keyCode = character.first.flatMap { self.keyCode(producing: $0) } ?? fallback
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: down) else {
                continue
            }
            event.flags = down ? .maskCommand : keyUpFlags
            event.post(tap: eventTap)
        }
    }

    /// Selected text in the focused element of `pid`, when Accessibility exposes it.
    static func selectedText(pid: pid_t) -> (text: String, range: CFRange)? {
        guard let element = focusedElement(pid: pid) else { return nil }
        return selectedText(on: element)
    }

    /// Same as `selectedText(pid:)` but on a known field — survives the language indicator
    /// stealing `AXFocusedUIElement`.
    static func selectedText(on element: AXUIElement) -> (text: String, range: CFRange)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedText" as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        var rangeValue: CFTypeRef?
        var range = CFRange(location: 0, length: (text as NSString).length)
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &rangeValue) == .success,
           let rangeValue {
            let axRange = rangeValue as! AXValue
            AXValueGetValue(axRange, .cfRange, &range)
        }
        return (text, range)
    }

    /// Slice of `AXValue` at a UTF-16 range — used when the language HUD collapsed the highlight
    /// but the session still knows which span to cycle.
    static func text(on element: AXUIElement, range: CFRange) -> String? {
        guard range.location >= 0, range.length > 0 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &value) == .success,
              let full = value as? String else { return nil }
        let ns = full as NSString
        let end = range.location + range.length
        guard end <= ns.length else { return nil }
        let slice = ns.substring(with: NSRange(location: range.location, length: range.length))
        return slice.isEmpty ? nil : slice
    }

    /// The field's `AXValue` (real even where the AX selection is fake — Telegram).
    static func value(on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// UTF-16 length of the field's `AXValue` (real even where the AX selection is fake — Telegram).
    static func valueLength(on element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &value) == .success,
              let full = value as? String else { return nil }
        return (full as NSString).length
    }

    @discardableResult
    static func setSelectedTextRange(pid: pid_t, range: CFRange) -> Bool {
        guard let element = focusedElement(pid: pid) else { return false }
        return setSelectedTextRange(element, range: range)
    }

    /// Prefer this after a replace: the system language indicator can steal focus, so
    /// re-querying `AXFocusedUIElement` fails while the original field still accepts range sets.
    @discardableResult
    static func setSelectedTextRange(on element: AXUIElement, range: CFRange) -> Bool {
        setSelectedTextRange(element, range: range)
    }

    /// Current `AXSelectedTextRange` (may be a collapsed caret).
    static func selectedTextRange(pid: pid_t) -> CFRange? {
        guard let element = focusedElement(pid: pid) else { return nil }
        return selectedTextRange(on: element)
    }

    static func selectedTextRange(on element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &rangeValue) == .success,
              let rangeValue else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    private static func setSelectedTextRange(_ element: AXUIElement, range: CFRange) -> Bool {
        setSelectedTextRangeDetailed(element, range: range).ok
    }

    /// AX set status + immediate readback, so callers can verify the range actually stuck.
    static func setSelectedTextRangeDetailed(
        on element: AXUIElement,
        range: CFRange
    ) -> (ok: Bool, axError: Int, readbackLoc: Int, readbackLen: Int) {
        setSelectedTextRangeDetailed(element, range: range)
    }

    private static func setSelectedTextRangeDetailed(
        _ element: AXUIElement,
        range: CFRange
    ) -> (ok: Bool, axError: Int, readbackLoc: Int, readbackLen: Int) {
        _ = AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue as CFBoolean)
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else {
            return (false, -1, -1, -1)
        }
        let status = AXUIElementSetAttributeValue(element, "AXSelectedTextRange" as CFString, axRange)
        let live = selectedTextRange(on: element)
        return (
            status == .success,
            Int(status.rawValue),
            live.map { Int($0.location) } ?? -1,
            live.map { Int($0.length) } ?? -1
        )
    }

    static func focusedElement(of pid: pid_t) -> AXUIElement? {
        focusedElement(pid: pid)
    }

    /// System-wide focused field — use when the target pid’s AX tree is mute.
    static func systemFocusedElement() -> AXUIElement? {
        focusedElementSystemWide()
    }

    /// Programmatic selection hit (Electron often has no `AXFocusedUIElement`).
    struct SelectionHit {
        var element: AXUIElement
        var text: String
        var range: CFRange
    }

    /// Walk the app AX tree for a non-empty `AXSelectedText` (optionally exact match).
    static func findSelectedText(pid: pid_t, matching: String? = nil) -> SelectionHit? {
        guard isTrusted else { return nil }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.35)
        var visited = 0
        // Time budget too: a node budget alone let Mail's compose (WebKit, slow AX) take 1.5 s on
        // every press.
        let deadline = ContinuousClock.now + .milliseconds(150)
        // Prefer windows — Electron app roots are huge and often mute before the editor.
        for window in windows(of: root) {
            if let hit = findSelectedText(in: window, matching: matching, depth: 0, visited: &visited, deadline: deadline) {
                return hit
            }
        }
        let hit = findSelectedText(in: root, matching: matching, depth: 0, visited: &visited, deadline: deadline)
        return hit
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static let axWalkBudget = 500

    private static func findSelectedText(
        in element: AXUIElement,
        matching: String?,
        depth: Int,
        visited: inout Int,
        deadline: ContinuousClock.Instant
    ) -> SelectionHit? {
        guard depth < 40, visited < axWalkBudget, ContinuousClock.now < deadline else { return nil }
        visited += 1
        if let ax = selectedText(on: element), !ax.text.isEmpty {
            if matching == nil || ax.text == matching {
                return SelectionHit(element: element, text: ax.text, range: ax.range)
            }
        }
        for child in children(of: element) {
            if let hit = findSelectedText(in: child, matching: matching, depth: depth + 1, visited: &visited, deadline: deadline) {
                return hit
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    /// Whether `element` still responds to accessibility (replace/TIS often leaves a dead ref).
    private static func isResponsive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &value)
        // `.noValue` still means the element is alive and simply has no range yet.
        return status == .success || status == .noValue
    }

    /// Prefer the session field while it still answers; only then fall back to live focus.
    /// Blindly preferring focus was wrong during the language HUD / unstable AX trees.
    static func resolveField(pid: pid_t?, preferred: AXUIElement?) -> AXUIElement? {
        if let preferred, isResponsive(preferred) { return preferred }
        if let pid, let focused = focusedElement(pid: pid) { return focused }
        return preferred
    }

    /// Screen rect of the selection (AppKit bottom-left coords), for anchoring the layout-convert toast.
    static func selectedTextBounds(pid: pid_t, range: CFRange?) -> CGRect? {
        selectedTextBounds(element: nil, pid: pid, range: range)
    }

    /// Prefer `element` when the language HUD stole focus from the field.
    static func selectedTextBounds(element: AXUIElement?, pid: pid_t?, range: CFRange?) -> CGRect? {
        let resolved = element ?? pid.flatMap { focusedElement(pid: $0) }
        guard let resolved else { return nil }
        if let range, let rect = bounds(for: range, in: resolved) {
            return screenRect(fromAX: rect)
        }
        // Some apps only answer for a collapsed caret range.
        if let range {
            var caret = CFRange(location: range.location, length: 0)
            if let rect = bounds(for: caret, in: resolved) {
                return screenRect(fromAX: rect)
            }
            caret.length = 1
            if let rect = bounds(for: caret, in: resolved) {
                return screenRect(fromAX: rect)
            }
        }
        // Fallback: whole field (less precise, still near the text).
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(resolved, "AXPosition" as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(resolved, "AXSize" as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return screenRect(fromAX: CGRect(origin: position, size: size))
    }

    private static func bounds(for range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return nil }
        var boundsValue: CFTypeRef?
        // Parameterized attribute name by value: the imported global is not concurrency-safe.
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForRangeParameterizedAttribute" as CFString,
            axRange,
            &boundsValue
        ) == .success, let boundsValue else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        // Zero-size caret is still a valid anchor point.
        if rect.width.isNaN || rect.height.isNaN { return nil }
        return rect
    }

    /// AX may report top-left (Quartz) or already AppKit bottom-left — pick the rect that hits a screen.
    private static func screenRect(fromAX axRect: CGRect) -> CGRect {
        let screens = NSScreen.screens.map(\.frame)
        if screens.contains(where: { $0.intersects(axRect.insetBy(dx: -1, dy: -1)) }) {
            return axRect
        }
        guard let primary = NSScreen.screens.first else { return axRect }
        let flipped = CGRect(
            x: axRect.origin.x,
            y: primary.frame.maxY - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
        if screens.contains(where: { $0.intersects(flipped.insetBy(dx: -1, dy: -1)) }) {
            return flipped
        }
        return axRect
    }

    /// Replaces the current selection via Accessibility and re-selects the replaced range.
    /// Prefers `preferred` (session field) when focus was stolen by the language indicator.
    /// Identity is success — no clipboard fallback.
    static func setSelectedText(
        pid: pid_t,
        text: String,
        previous: String,
        select range: CFRange?,
        preferred: AXUIElement? = nil
    ) -> AXUIElement? {
        let focused = focusedElement(pid: pid)
        if let preferred {
            // Nil focus → language HUD stole it; use the field we read.
            // Focus on another element → still write to `preferred` only (never into the new field).
            // Unstable AX refs can fail CFEqual for the same field; trying `preferred` first recovers.
            if focused == nil || CFEqual(focused, preferred) {
                return setSelectedText(on: focused ?? preferred, text: text, previous: previous, select: range)
            }
            return setSelectedText(on: preferred, text: text, previous: previous, select: range)
        }
        guard let focused else { return nil }
        return setSelectedText(on: focused, text: text, previous: previous, select: range)
    }

    static func setSelectedText(
        on element: AXUIElement,
        text: String,
        previous: String,
        select range: CFRange?
    ) -> AXUIElement? {
        let previousLength = (previous as NSString).length
        let nextLength = (text as NSString).length
        // HUD / TIS often collapse the highlight between read and replace. `AXSelectedText` then
        // inserts at the caret instead of replacing — re-select the known span first.
        if let range {
            let prior = CFRange(location: range.location, length: previousLength)
            _ = setSelectedTextRange(element, range: prior)
        }
        let selected = range.map { CFRange(location: $0.location, length: nextLength) }
        if text == previous {
            if let selected { _ = setSelectedTextRange(element, range: selected) }
            return element
        }
        guard AXUIElementSetAttributeValue(element, "AXSelectedText" as CFString, text as CFString) == .success else {
            return nil
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedText" as CFString, &value) == .success {
            let now = value as? String ?? ""
            // Only treat as ignored when the old selection is still selected. Collapsed/empty
            // readback after a successful set is normal in many apps — do not ⌘V again.
            if now == previous, previous != text { return nil }
        }
        if let selected { _ = setSelectedTextRange(element, range: selected) }
        return element
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard isTrusted else { return nil }
        if let element = focusedElement(inApplicationPID: pid) { return element }
        // Per-app AXFocusedUIElement is often mute (Chrome/Electron, wrong helper pid) while
        // system-wide still returns the live field that ⌘C/⌘V hit.
        return focusedElementSystemWide()
    }

    /// Per-app `AXFocusedUIElement` probe — used to mark Electron/Chrome trees mute without a walk.
    static func focusedElementProbe(pid: pid_t?) -> (appOK: Bool, appError: Int) {
        guard isTrusted else { return (false, -2) }
        guard let pid else { return (false, -1) }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            application, "AXFocusedUIElement" as CFString, &focused
        )
        let appOK = status == .success
            && focused != nil
            && CFGetTypeID(focused!) == AXUIElementGetTypeID()
        return (appOK, Int(status.rawValue))
    }

    private static func focusedElement(inApplicationPID pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXFocusedUIElement" as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func focusedElementSystemWide() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), "AXFocusedUIElement" as CFString, &focused
        ) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    /// The key that types `character` in the current Latin layout: ⌘V is on another key with
    /// Dvorak or AZERTY-like layouts. With a non-Latin layout (Russian) apps read shortcuts through
    /// the Latin layout that goes with it, which is the one asked for here. Also used for the
    /// armed-session ⌘V observer (§3.11 / P25).
    @MainActor
    static func keyCode(producing character: Character) -> CGKeyCode? {
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
