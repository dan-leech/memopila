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

    typealias Materials = (
        ids: [String],
        names: [String: String],
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>]
    )

    private struct LayoutSnapshot: Sendable {
        let id: String
        let name: String
        let data: Data
    }

    private static var cachedLayouts: [Layout]?
    private static var cachedMaterials: Materials?
    private static var materialsTask: Task<Materials, Never>?
    private static var materialsTaskGeneration: Int?
    /// Bumped on invalidate so an in-flight build cannot publish stale maps after a layout change.
    private static var materialsGeneration = 0
    private static var observing = false

    /// Keyboard layouts only (no IMEs), in Input Sources order.
    static func keyboardLayouts() -> [Layout] {
        ensureObserving()
        if let cachedLayouts { return cachedLayouts }
        let layouts = fetchLayouts()
        cachedLayouts = layouts
        return layouts
    }

    static func invalidateCache() {
        cachedLayouts = nil
        cachedMaterials = nil
        materialsGeneration += 1
        // Leave `materialsTask` running: cancelling `Task<Materials, Never>` is unsafe, and the
        // finished result is discarded when `materialsGeneration` no longer matches.
    }

    private static func fetchLayouts() -> [Layout] {
        let filter = [
            kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsEnabled!: kCFBooleanTrue!,
        ] as CFDictionary
        if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            let layouts = list.compactMap(makeLayout)
            if !layouts.isEmpty { return layouts }
        }
        if let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] {
            return list.compactMap(makeLayout)
        }
        return []
    }

    private static func makeLayout(_ source: TISInputSource) -> Layout? {
        guard isKeyboardLayout(source),
              let id = stringProperty(source, "TISPropertyInputSourceID") else { return nil }
        let name = carbonStringProperty(source, kTISPropertyLocalizedName) ?? id
        return Layout(id: id, name: name, source: source)
    }

    static func currentLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, "TISPropertyInputSourceID")
    }

    /// The layout "Select the previous input source" (⌃Space) would switch to: the first entry of
    /// HIToolbox's MRU `AppleInputSourceHistory` that is an enabled keyboard layout other than
    /// `current`. A mistype happens between these two (user, 2026-11-26: “only between two
    /// neighbouring layouts”). Entries carry the layout *name* (“Spanish - ISO”) — matched to the
    /// TIS id suffix (`com.apple.keylayout.Spanish-ISO`).
    static func previousLayoutID(current: String?) -> String? {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let history = CFPreferencesCopyAppValue("AppleInputSourceHistory" as CFString, domain)
            as? [[String: Any]] else { return nil }
        let ids = keyboardLayouts().map(\.id)
        for entry in history {
            guard entry["InputSourceKind"] as? String == "Keyboard Layout",
                  let name = entry["KeyboardLayout Name"] as? String else { continue }
            let compact = name.replacingOccurrences(of: " ", with: "")
            guard let id = ids.first(where: { $0.hasSuffix("." + compact) }) else { continue }
            if id != current { return id }
        }
        return nil
    }

    /// First language the layout is for (`ru`, `en`, `es` …) — picks the spelling dictionary
    /// for layout convert's caret span.
    static func primaryLanguage(id: String) -> String? {
        guard let layout = keyboardLayouts().first(where: { $0.id == id }),
              let key = kTISPropertyInputSourceLanguages,
              let raw = TISGetInputSourceProperty(layout.source, key) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        return languages?.first
    }

    @discardableResult
    static func select(id: String) -> Bool {
        if currentLayoutID() == id { return true }
        let layouts = keyboardLayouts()
        guard let layout = layouts.first(where: { $0.id == id }) else { return false }
        return TISSelectInputSource(layout.source) == noErr
    }

    /// Kick off map building off the main actor (first ⌥⌘B must not hitch on UCKeyTranslate).
    static func warmMaterials() {
        ensureObserving()
        if cachedMaterials != nil { return }
        _ = materialsBuildTask()
    }

    /// Pairwise maps and charsets — one UCKeyTranslate pass per layout×modifier, then cached.
    static func cycleMaterials() async -> Materials {
        ensureObserving()
        if let cachedMaterials { return cachedMaterials }
        while true {
            let generation = materialsGeneration
            let materials = await materialsBuildTask().value
            if let cachedMaterials { return cachedMaterials }
            // Build finished for this generation but was not cached (should be rare) — use it.
            if materialsGeneration == generation { return materials }
            // Enabled layouts changed mid-build; loop for a fresh snapshot.
        }
    }

    private static func materialsBuildTask() -> Task<Materials, Never> {
        if let materialsTask, materialsTaskGeneration == materialsGeneration {
            return materialsTask
        }
        let generation = materialsGeneration
        let snapshots = layoutSnapshots()
        let detached = Task.detached(priority: .userInitiated) {
            Self.buildMaterials(from: snapshots)
        }
        let wrapper = Task { @MainActor in
            let materials = await detached.value
            if materialsGeneration == generation {
                cachedMaterials = materials
            }
            // Only clear if we are still the active build for this generation (a newer build may
            // have replaced `materialsTask` after invalidate).
            if materialsTaskGeneration == generation {
                materialsTask = nil
                materialsTaskGeneration = nil
            }
            return materials
        }
        materialsTask = wrapper
        materialsTaskGeneration = generation
        return wrapper
    }

    private static func layoutSnapshots() -> [LayoutSnapshot] {
        keyboardLayouts().compactMap { layout in
            guard let data = layoutData(layout.source) else { return nil }
            return LayoutSnapshot(id: layout.id, name: layout.name, data: data)
        }
    }

    // MARK: - Private

    private static func ensureObserving() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { invalidateCache() }
        }
    }

    private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        stringProperty(source, "TISPropertyInputSourceType") == "TISTypeKeyboardLayout"
    }

    private static func stringProperty(_ source: TISInputSource, _ key: String) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key as CFString) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func carbonStringProperty(_ source: TISInputSource, _ key: CFString?) -> String? {
        guard let key, let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// Heavy work: safe off the main actor (pure `UCKeyTranslate` over copied layout data).
    nonisolated private static func buildMaterials(from snapshots: [LayoutSnapshot]) -> Materials {
        let ids = snapshots.map(\.id)
        var names: [String: String] = [:]
        var plain: [String: [UInt16: Character]] = [:]
        var shifted: [String: [UInt16: Character]] = [:]
        for snap in snapshots {
            names[snap.id] = snap.name
            plain[snap.id] = forwardMap(data: snap.data, modifiers: 0)
            shifted[snap.id] = forwardMap(data: snap.data, modifiers: shiftKey)
        }

        var charsets: [String: Set<Character>] = [:]
        for id in ids {
            var set: Set<Character> = []
            if let values = plain[id]?.values { set.formUnion(values) }
            if let values = shifted[id]?.values { set.formUnion(values) }
            charsets[id] = set
        }

        var maps: [String: [String: [Character: Character]]] = [:]
        for from in snapshots {
            var toMaps: [String: [Character: Character]] = [:]
            for to in snapshots where to.id != from.id {
                toMaps[to.id] = characterMap(
                    plainFrom: plain[from.id] ?? [:],
                    plainTo: plain[to.id] ?? [:],
                    shiftFrom: shifted[from.id] ?? [:],
                    shiftTo: shifted[to.id] ?? [:]
                )
            }
            maps[from.id] = toMaps
        }
        return (ids, names, maps, charsets)
    }

    nonisolated private static func characterMap(
        plainFrom: [UInt16: Character],
        plainTo: [UInt16: Character],
        shiftFrom: [UInt16: Character],
        shiftTo: [UInt16: Character]
    ) -> [Character: Character] {
        var map: [Character: Character] = [:]
        // Prefer main-block keys over keypad: both may produce '.' / ',' but mistypes come from
        // the letter block. Sorted keycode alone already helps; keypad-last makes it explicit.
        func ingest(_ from: [UInt16: Character], _ to: [UInt16: Character]) {
            for (code, fromChar) in from.sorted(by: Self.keyCodePreference) {
                guard let toChar = to[code], fromChar != toChar else { continue }
                if map[fromChar] == nil { map[fromChar] = toChar }
            }
        }
        ingest(plainFrom, plainTo)
        ingest(shiftFrom, shiftTo)
        return map
    }

    /// ANSI keypad keycodes (0x41…0x5C) lose to the main block when both produce the same char.
    nonisolated private static func keyCodePreference(_ lhs: Dictionary<UInt16, Character>.Element,
                                                      _ rhs: Dictionary<UInt16, Character>.Element) -> Bool {
        let leftPad = Self.isKeypad(lhs.key)
        let rightPad = Self.isKeypad(rhs.key)
        if leftPad != rightPad { return !leftPad && rightPad }
        return lhs.key < rhs.key
    }

    nonisolated private static func isKeypad(_ code: UInt16) -> Bool {
        (UInt16(0x41)...UInt16(0x5C)).contains(code)
    }

    /// keyCode → character. `modifiers` is a Carbon Event Manager mask (`0` or `shiftKey`);
    /// `UCKeyTranslate` wants that mask **shifted right by 8**.
    nonisolated private static func forwardMap(data: Data, modifiers: Int) -> [UInt16: Character] {
        data.withUnsafeBytes { raw -> [UInt16: Character] in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return [:] }
            var result: [UInt16: Character] = [:]
            let modBits = UInt32(modifiers) >> 8
            let keyboardType = UInt32(LMGetKbdType())
            for code in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    base, code, UInt16(kUCKeyActionDisplay), modBits, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 4, &length, &characters
                )
                guard status == noErr, length == 1,
                      let scalar = UnicodeScalar(characters[0]),
                      !CharacterSet.controlCharacters.contains(scalar) else { continue }
                result[code] = Character(scalar)
            }
            return result
        }
    }
}
