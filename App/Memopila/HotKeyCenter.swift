import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon `RegisterEventHotKey`: no Accessibility, no global key monitor (PLAN §2).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Shortcut: Equatable, Codable, Sendable {
        var keyCode: UInt32
        var carbonModifiers: UInt32

        /// ⌥⌘V, the same default as Pasta.
        static let defaultShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | optionKey))

        init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }

        @MainActor
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers = 0
            if flags.contains(.command) { modifiers |= cmdKey }
            if flags.contains(.option) { modifiers |= optionKey }
            if flags.contains(.control) { modifiers |= controlKey }
            if flags.contains(.shift) { modifiers |= shiftKey }
            // A global shortcut needs ⌘ or ⌃; ⌥/⇧-only combinations type characters, and ⌘ alone
            // would take ⌘W, ⌘Q, ⌘C… away from every app's menu (review finding).
            guard flags.contains(.command) || flags.contains(.control) else { return nil }
            guard flags.intersection([.command, .option, .control, .shift]) != .command else { return nil }
            self.init(keyCode: UInt32(event.keyCode), carbonModifiers: UInt32(modifiers))
        }

        var displayString: String {
            var result = ""
            if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
            if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
            if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
            if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
            return result + Self.keyName(keyCode)
        }

        private static func keyName(_ keyCode: UInt32) -> String {
            let names: [Int: String] = [
                kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
                kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
                kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
                kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
                kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
                kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
                kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
                kVK_ANSI_9: "9", kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋",
                kVK_ANSI_Grave: "`", kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
            ]
            return names[Int(keyCode)] ?? "key \(keyCode)"
        }
    }

    enum RegistrationError: Error {
        case alreadyTaken
        case failed(OSStatus)

        func message(for shortcut: Shortcut) -> String {
            switch self {
            case .alreadyTaken:
                String(localized: "\(shortcut.displayString) is in use by another app (for example Pasta). Choose another shortcut or quit that app.")
            case .failed(let status):
                String(localized: "Could not register \(shortcut.displayString) (error \(Int(status))).")
            }
        }
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4D4D_504C // "MMPL"

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Result<UInt32, RegistrationError> {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            // Exclusive: when another app (Pasta) holds the same keys, registering fails and says so
            // instead of both apps reacting to every press (review finding).
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            return .failure(status == OSStatus(eventHotKeyExistsErr) ? .alreadyTaken : .failed(status))
        }
        references[id] = reference
        actions[id] = action
        return .success(id)
    }

    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        actions[id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}
