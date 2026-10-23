/// The single bundle-identifier validator used everywhere (PLAN §5).
public enum BundleIdentifier {
    /// Reverse-DNS: UTF-8 length 1…255, at least two non-empty components of ASCII letters,
    /// digits and hyphens, no component starting or ending with a hyphen. Rejects whitespace,
    /// control characters and the empty "unknown" marker value.
    public static func isValid(_ candidate: String) -> Bool {
        guard (1...255).contains(candidate.utf8.count) else { return false }
        let components = candidate.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy(isValidComponent)
    }

    private static func isValidComponent(_ component: Substring.UTF8View) -> Bool {
        guard let first = component.first, let last = component.last else { return false }
        let hyphen = UInt8(ascii: "-")
        guard first != hyphen, last != hyphen else { return false }
        return component.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 hyphen:
                return true
            default:
                return false
            }
        }
    }
}

/// What one pasteboard item says about `org.nspasteboard.source`.
public enum ItemSourceValue: Sendable, Equatable {
    case notDeclared
    /// The type is declared but reading it returned nil or a non-string.
    case unreadable
    case value(String)
}

/// The resolved `org.nspasteboard.source` marker of a whole change (PLAN §5, per-item algorithm).
public enum SourceMarker: Sendable, Equatable {
    case absent
    case valid(String)
    /// Present but empty, invalid, unreadable or conflicting.
    case unknown

    public static func resolve(_ items: [ItemSourceValue]) -> SourceMarker {
        var resolved: String?
        for item in items {
            switch item {
            case .notDeclared:
                continue
            case .unreadable:
                return .unknown
            case .value(let value):
                guard BundleIdentifier.isValid(value) else { return .unknown }
                if let resolved, resolved != value { return .unknown }
                resolved = value
            }
        }
        return resolved.map(SourceMarker.valid) ?? .absent
    }
}

/// The app a change is attributed to (PLAN §5). Not authenticated: a convenience, not a security boundary.
public struct AppIdentity: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case marker
        case frontmost
        case unknown
    }

    public let bundleID: String?
    public let source: Source

    public init(bundleID: String?, source: Source) {
        self.bundleID = bundleID
        self.source = source
    }

    public static let unknown = AppIdentity(bundleID: nil, source: .unknown)

    /// - Parameters:
    ///   - frontmostBundleID: frontmost application when the change was detected.
    ///   - panelIsKey: Memopila's own panel is key, so its own copies are attributed to Memopila.
    public static func resolve(
        marker: SourceMarker,
        frontmostBundleID: String?,
        panelIsKey: Bool,
        ownBundleID: String
    ) -> AppIdentity {
        switch marker {
        case .valid(let bundleID):
            return AppIdentity(bundleID: bundleID, source: .marker)
        case .unknown:
            return .unknown
        case .absent:
            let candidate = panelIsKey ? ownBundleID : frontmostBundleID
            guard let candidate, BundleIdentifier.isValid(candidate) else { return .unknown }
            return AppIdentity(bundleID: candidate, source: .frontmost)
        }
    }
}
