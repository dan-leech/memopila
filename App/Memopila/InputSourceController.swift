import AppKit
import Carbon.HIToolbox
import MemopilaCore

/// Enabled keyboard layouts and keycode maps between them (layout convert).
@MainActor
enum InputSourceController {
    struct Layout: Equatable, Identifiable {
        let id: String
        let name: String
        fileprivate let source: TISInputSource

        var localizedName: String { name }
    }

    /// Keyboard layouts only (no IMEs), in Input Sources order.
    static func keyboardLayouts() -> [Layout] {
        let filter: [CFString: Any] = [
            "TISPropertyInputSourceCategory" as CFString: "TISCategoryKeyboardInputSource" as CFString,
            "TISPropertyInputSourceIsEnabled" as CFString: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source -> Layout? in
            guard isKeyboardLayout(source),
                  let id = stringProperty(source, "TISPropertyInputSourceID"),
                  let name = stringProperty(source, "TISPropertyLocalizedName") else { return nil }
            return Layout(id: id, name: name, source: source)
        }
    }

    static func currentLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, "TISPropertyInputSourceID")
    }

    static func currentLayoutName() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, "TISPropertyLocalizedName")
    }

    @discardableResult
    static func select(id: String) -> Bool {
        let layouts = keyboardLayouts()
        guard let layout = layouts.first(where: { $0.id == id }) else { return false }
        return TISSelectInputSource(layout.source) == noErr
    }

    /// Characters this layout can produce (plain + Shift), for best-fit.
    static func charset(for layout: Layout) -> Set<Character> {
        var set = Set<Character>()
        for (_, ch) in forwardMap(layout: layout, modifiers: 0) { set.insert(ch) }
        for (_, ch) in forwardMap(layout: layout, modifiers: shiftKey) { set.insert(ch) }
        return set
    }

    /// Map characters produced by `from` to characters on the same keys in `to`.
    static func characterMap(from: Layout, to: Layout) -> [Character: Character] {
        if from.id == to.id { return [:] }
        var map: [Character: Character] = [:]
        for modifiers in [0, shiftKey] {
            let source = forwardMap(layout: from, modifiers: modifiers)
            let target = forwardMap(layout: to, modifiers: modifiers)
            for (code, fromChar) in source {
                guard let toChar = target[code], fromChar != toChar else { continue }
                // Prefer unshifted when both claim the same source character.
                if modifiers == 0 || map[fromChar] == nil {
                    map[fromChar] = toChar
                }
            }
        }
        return map
    }

    /// All pairwise maps and charsets for `LayoutConverter.cycle`.
    static func cycleMaterials() -> (
        ids: [String],
        names: [String: String],
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>]
    ) {
        let layouts = keyboardLayouts()
        let ids = layouts.map(\.id)
        var names: [String: String] = [:]
        var charsets: [String: Set<Character>] = [:]
        var maps: [String: [String: [Character: Character]]] = [:]
        for layout in layouts {
            names[layout.id] = layout.name
            charsets[layout.id] = charset(for: layout)
        }
        for from in layouts {
            var toMaps: [String: [Character: Character]] = [:]
            for to in layouts where to.id != from.id {
                toMaps[to.id] = characterMap(from: from, to: to)
            }
            maps[from.id] = toMaps
        }
        return (ids, names, maps, charsets)
    }

    // MARK: - Private

    private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        // `TISPropertyInputSourceType` == `TISTypeKeyboardLayout` for real layouts (not IMEs).
        stringProperty(source, "TISPropertyInputSourceType") == "TISTypeKeyboardLayout"
    }

    private static func stringProperty(_ source: TISInputSource, _ key: String) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key as CFString) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// keyCode → character for one modifier mask (Carbon `shiftKey` or 0).
    private static func forwardMap(layout: Layout, modifiers: Int) -> [UInt16: Character] {
        guard let data = layoutData(layout.source) else { return [:] }
        return data.withUnsafeBytes { raw -> [UInt16: Character] in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return [:] }
            var result: [UInt16: Character] = [:]
            let modBits = UInt32(modifiers)
            for code in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    base, code, UInt16(kUCKeyActionDisplay), modBits, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 4, &length, &characters
                )
                guard status == noErr, length == 1,
                      let scalar = UnicodeScalar(characters[0]),
                      !CharacterSet.controlCharacters.contains(scalar) else { continue }
                let character = Character(scalar)
                // Prefer lower key codes when two codes type the same character.
                if result[code] == nil { result[code] = character }
            }
            return result
        }
    }
}
