import Foundation

/// Small settings kept in `UserDefaults` until the SwiftData store lands (PLAN §7.2 `AppSettings`).
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let shortcut = "hotKeyShortcut"
        static let pausedUntil = "pausedUntil"
        static let pausedIndefinitely = "pausedIndefinitely"
        static let silentDefaultVerifiedOSBuild = "silentDefaultVerifiedOSBuild"
        static let maxSinglePayloadMiB = "maxSinglePayloadMiB"
    }

    static var shortcut: HotKeyCenter.Shortcut? {
        get { defaults.data(forKey: Key.shortcut).flatMap { try? JSONDecoder().decode(HotKeyCenter.Shortcut.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.shortcut) }
    }

    static var pausedUntil: Date? {
        get { defaults.object(forKey: Key.pausedUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.pausedUntil) }
    }

    static var pausedIndefinitely: Bool {
        get { defaults.bool(forKey: Key.pausedIndefinitely) }
        set { defaults.set(newValue, forKey: Key.pausedIndefinitely) }
    }

    /// OS build on which a content read under `.default` raised no alert (§3.1).
    static var silentDefaultVerifiedOSBuild: String? {
        get { defaults.string(forKey: Key.silentDefaultVerifiedOSBuild) }
        set { defaults.set(newValue, forKey: Key.silentDefaultVerifiedOSBuild) }
    }

    static var maxSinglePayloadMiB: Int {
        get { defaults.object(forKey: Key.maxSinglePayloadMiB) as? Int ?? 32 }
        set { defaults.set(min(max(newValue, 4), 256), forKey: Key.maxSinglePayloadMiB) }
    }
}
