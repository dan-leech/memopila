/// Per-app capture mode (PLAN §5.1).
public enum CaptureMode: Sendable, Equatable, Codable {
    case save
    case dontSave
    case deleteAfter(minutes: Int)
}

/// Standard attributes by marker or frontmost app; Strict is fail-closed (PLAN §5).
public enum IdentityMode: String, Sendable, Equatable, Codable {
    case standard
    case strict
}

/// Settings that apply to one change after resolving its app.
public struct ResolvedAppSettings: Sendable, Equatable, Codable {
    public var captureMode: CaptureMode
    public var sizeLimitMiB: Int?
    public var recognizeText: Bool
    public var recordSourcePage: Bool

    public init(captureMode: CaptureMode = .save, sizeLimitMiB: Int? = nil, recognizeText: Bool = true, recordSourcePage: Bool = true) {
        self.captureMode = captureMode
        self.sizeLimitMiB = sizeLimitMiB
        self.recognizeText = recognizeText
        self.recordSourcePage = recordSourcePage
    }

    /// Retention for *Delete after*, if any.
    public var retentionMinutes: Int? {
        if case .deleteAfter(let minutes) = captureMode { return minutes }
        return nil
    }
}

public struct AppProfile: Sendable, Equatable, Codable, Identifiable {
    public var id: String { bundleID }

    public var bundleID: String
    public var settings: ResolvedAppSettings

    public init(bundleID: String, settings: ResolvedAppSettings) {
        self.bundleID = bundleID
        self.settings = settings
    }
}

public enum Admission: Sendable, Equatable {
    case capture(ResolvedAppSettings)
    case skipDontSave
    /// Strict mode: an app is set to *Don't save* and this change has no valid marker.
    case skipStrict
}

/// All per-app settings plus the *Any app* defaults.
public struct AppProfiles: Sendable, Equatable {
    public var defaults: ResolvedAppSettings
    public var identityMode: IdentityMode
    public private(set) var profiles: [String: AppProfile]

    public init(defaults: ResolvedAppSettings = ResolvedAppSettings(), identityMode: IdentityMode = .standard, profiles: [AppProfile] = []) {
        self.defaults = defaults
        self.identityMode = identityMode
        self.profiles = Dictionary(profiles.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, last in last })
    }

    public mutating func set(_ profile: AppProfile) { profiles[profile.bundleID] = profile }
    public mutating func remove(bundleID: String) { profiles[bundleID] = nil }

    public func settings(for identity: AppIdentity) -> ResolvedAppSettings {
        guard let bundleID = identity.bundleID, let profile = profiles[bundleID] else { return defaults }
        return profile.settings
    }

    public func admission(for identity: AppIdentity) -> Admission {
        let settings = settings(for: identity)
        if settings.captureMode == .dontSave { return .skipDontSave }
        if identityMode == .strict, identity.source != .marker, hasDontSaveApps { return .skipStrict }
        return .capture(settings)
    }

    public var hasDontSaveApps: Bool {
        profiles.values.contains { $0.settings.captureMode == .dontSave }
    }
}
