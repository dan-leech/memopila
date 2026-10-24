import Foundation
import MemopilaCore
import MemopilaServices
import Observation
import ServiceManagement

/// User settings in `UserDefaults` (PLAN §7.2 `AppSettings`, `AppProfile`, `FormatRule`).
/// History lives in SwiftData; configuration is small and stays here.
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    /// Retention-relevant settings changed (§6: a lower cap applies immediately).
    @ObservationIgnored var onRetentionChange: (() -> Void)?
    @ObservationIgnored var onRecognitionChange: ((_ bundleID: String?) -> Void)?

    var shortcut: HotKeyCenter.Shortcut { didSet { store(shortcut, Key.shortcut) } }
    var pauseShortcut: HotKeyCenter.Shortcut? { didSet { store(pauseShortcut, Key.pauseShortcut) } }
    var skipShortcut: HotKeyCenter.Shortcut? { didSet { store(skipShortcut, Key.skipShortcut) } }
    var identityMode: IdentityMode { didSet { defaults.set(identityMode.rawValue, forKey: Key.identityMode) } }
    var maxItemMiB: Int { didSet { defaults.set(maxItemMiB, forKey: Key.maxItemMiB) } }
    var maxCount: Int {
        didSet {
            defaults.set(maxCount, forKey: Key.maxCount)
            if maxCount < oldValue { onRetentionChange?() }
        }
    }
    var maxAgeDays: Int {
        didSet {
            defaults.set(maxAgeDays, forKey: Key.maxAgeDays)
            if maxAgeDays < oldValue { onRetentionChange?() }
        }
    }
    var ignoreRemoteClipboard: Bool { didSet { defaults.set(ignoreRemoteClipboard, forKey: Key.ignoreRemoteClipboard) } }
    var pasteAfterRestore: Bool { didSet { defaults.set(pasteAfterRestore, forKey: Key.pasteAfterRestore) } }
    var recognizeText: Bool {
        didSet {
            defaults.set(recognizeText, forKey: Key.recognizeText)
            if recognizeText, !oldValue { onRecognitionChange?(nil) }
        }
    }
    var recognitionLanguages: [String] { didSet { defaults.set(recognitionLanguages, forKey: Key.recognitionLanguages) } }
    var appProfiles: [AppProfile] { didSet { store(appProfiles, Key.appProfiles) } }
    var formatRules: [FormatRule] { didSet { store(formatRules, Key.formatRules) } }
    /// Copied credentials (§3.10): masked and deleted after 8 hours by default.
    var secretPolicy: SecretPolicy { didSet { store(secretPolicy, Key.secretPolicy) } }
    var disabledSecretKinds: Set<SecretKind> { didSet { store(Array(disabledSecretKinds), Key.disabledSecretKinds) } }
    var silentDefaultVerifiedOSBuild: String? { didSet { defaults.set(silentDefaultVerifiedOSBuild, forKey: Key.silentDefaultVerifiedOSBuild) } }
    var pausedUntil: Date? { didSet { defaults.set(pausedUntil, forKey: Key.pausedUntil) } }
    var pausedIndefinitely: Bool { didSet { defaults.set(pausedIndefinitely, forKey: Key.pausedIndefinitely) } }
    var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: Key.showSidebar) } }
    /// Panel frame per display (§8.1), keyed by `PanelController.displayKey`.
    var panelFrames: [String: String] { didSet { defaults.set(panelFrames, forKey: Key.panelFrames) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = Self.load(HotKeyCenter.Shortcut.self, Key.shortcut, defaults) ?? .defaultShortcut
        pauseShortcut = Self.load(HotKeyCenter.Shortcut.self, Key.pauseShortcut, defaults)
        skipShortcut = Self.load(HotKeyCenter.Shortcut.self, Key.skipShortcut, defaults)
        identityMode = defaults.string(forKey: Key.identityMode).flatMap(IdentityMode.init(rawValue:)) ?? .standard
        maxItemMiB = (defaults.object(forKey: Key.maxItemMiB) as? Int ?? 32).clamped(to: Self.itemMiBRange)
        maxCount = (defaults.object(forKey: Key.maxCount) as? Int ?? RetentionPlanner.defaultMaxCount)
            .clamped(to: RetentionPlanner.maxCountRange)
        maxAgeDays = (defaults.object(forKey: Key.maxAgeDays) as? Int ?? 30).clamped(to: Self.maxAgeRange)

        ignoreRemoteClipboard = defaults.bool(forKey: Key.ignoreRemoteClipboard)
        pasteAfterRestore = defaults.bool(forKey: Key.pasteAfterRestore)
        recognizeText = defaults.object(forKey: Key.recognizeText) as? Bool ?? true
        recognitionLanguages = defaults.stringArray(forKey: Key.recognitionLanguages) ?? []
        appProfiles = Self.load([AppProfile].self, Key.appProfiles, defaults) ?? []
        formatRules = Self.load([FormatRule].self, Key.formatRules, defaults) ?? []
        secretPolicy = Self.load(SecretPolicy.self, Key.secretPolicy, defaults) ?? .default
        disabledSecretKinds = Set(Self.load([SecretKind].self, Key.disabledSecretKinds, defaults) ?? [])
        silentDefaultVerifiedOSBuild = defaults.string(forKey: Key.silentDefaultVerifiedOSBuild)
        pausedUntil = defaults.object(forKey: Key.pausedUntil) as? Date
        pausedIndefinitely = defaults.bool(forKey: Key.pausedIndefinitely)
        showSidebar = defaults.object(forKey: Key.showSidebar) as? Bool ?? true
        panelFrames = defaults.dictionary(forKey: Key.panelFrames) as? [String: String] ?? [:]
    }

    static let maxAgeRange = 1...3_650
    static let itemMiBRange = 4...256

    // MARK: Derived

    var maxItemBytes: Int { maxItemMiB * FormatPolicy.mebibyte }

    var secretKinds: Set<SecretKind> { Set(SecretKind.allCases).subtracting(disabledSecretKinds) }

    var profiles: AppProfiles {
        AppProfiles(defaults: ResolvedAppSettings(recognizeText: recognizeText), identityMode: identityMode, profiles: appProfiles)
    }

    var formatPolicy: FormatPolicy {
        FormatPolicy(rules: formatRules, defaultMaxBytes: maxItemBytes)
    }

    var retentionLimits: RetentionLimits {
        RetentionLimits(maxCount: maxCount, maxAge: TimeInterval(maxAgeDays) * 86_400)
    }

    var effectiveRecognitionLanguages: [String] {
        recognitionLanguages.isEmpty ? TextRecognizer.defaultLanguages() : recognitionLanguages
    }

    func settings(for bundleID: String) -> ResolvedAppSettings {
        appProfiles.first { $0.bundleID == bundleID }?.settings ?? ResolvedAppSettings(recognizeText: recognizeText)
    }

    func updateProfile(_ bundleID: String, _ change: (inout ResolvedAppSettings) -> Void) {
        let before = settings(for: bundleID)
        var settings = before
        change(&settings)
        if let index = appProfiles.firstIndex(where: { $0.bundleID == bundleID }) {
            appProfiles[index].settings = settings
        } else {
            appProfiles.append(AppProfile(bundleID: bundleID, settings: settings))
        }
        if settings.recognizeText, !before.recognizeText { onRecognitionChange?(bundleID) }
    }

    func hasProfile(_ bundleID: String) -> Bool {
        appProfiles.contains { $0.bundleID == bundleID }
    }

    /// Adds a rule unless an identical one exists; a rule for the same app and type is replaced.
    func addRule(_ rule: FormatRule) {
        formatRules.removeAll { $0.appBundleID == rule.appBundleID && $0.typePattern == rule.typePattern && $0.isPrefix == rule.isPrefix }
        formatRules.append(rule)
    }

    // MARK: Undo for quick actions (§5.1)

    struct Snapshot {
        fileprivate let appProfiles: [AppProfile]
        fileprivate let formatRules: [FormatRule]
    }

    var snapshot: Snapshot { Snapshot(appProfiles: appProfiles, formatRules: formatRules) }

    func restore(_ snapshot: Snapshot) {
        appProfiles = snapshot.appProfiles
        formatRules = snapshot.formatRules
    }

    // MARK: Login item (§8.7)

    var launchAtLogin: Bool {
        get {
            _ = launchAtLoginRevision
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            launchAtLoginRevision += 1
        }
    }

    private(set) var launchAtLoginError: String?
    private var launchAtLoginRevision = 0

    func removeProfile(_ bundleID: String) {
        appProfiles.removeAll { $0.bundleID == bundleID }
        formatRules.removeAll { $0.appBundleID == bundleID }
    }

    func rules(for bundleID: String?) -> [FormatRule] {
        formatRules.filter { $0.appBundleID == bundleID }
    }

    // MARK: Storage

    private enum Key {
        static let shortcut = "hotKeyShortcut"
        static let pauseShortcut = "pauseShortcut"
        static let skipShortcut = "skipShortcut"
        static let identityMode = "identityMode"
        static let maxItemMiB = "maxSinglePayloadMiB"
        static let maxCount = "maxCount"
        static let maxAgeDays = "maxAgeDays"
        static let ignoreRemoteClipboard = "ignoreRemoteClipboard"
        static let pasteAfterRestore = "pasteAfterRestore"
        static let recognizeText = "recognizeText"
        static let recognitionLanguages = "recognitionLanguages"
        static let appProfiles = "appProfiles"
        static let formatRules = "formatRules"
        static let secretPolicy = "secretPolicy"
        static let disabledSecretKinds = "disabledSecretKinds"
        static let silentDefaultVerifiedOSBuild = "silentDefaultVerifiedOSBuild"
        static let pausedUntil = "pausedUntil"
        static let pausedIndefinitely = "pausedIndefinitely"
        static let showSidebar = "showSidebar"
        static let panelFrames = "panelFrames"
    }

    private func store<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
