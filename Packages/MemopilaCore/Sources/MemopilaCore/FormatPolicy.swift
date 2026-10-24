/// A user format rule (PLAN §3.2.2). At least one of `appBundleID` / `typePattern` must be set.
public struct FormatRule: Sendable, Equatable, Codable {
    public enum Action: String, Sendable, Equatable, Codable {
        case keep
        case skip
    }

    /// `nil` = any app.
    public var appBundleID: String?
    /// Exact type or prefix (`isPrefix`); `nil` = any type of the app.
    public var typePattern: String?
    public var isPrefix: Bool
    public var action: Action
    public var maxSizeMiB: Int?

    public init(appBundleID: String? = nil, typePattern: String? = nil, isPrefix: Bool = false, action: Action, maxSizeMiB: Int? = nil) {
        self.appBundleID = appBundleID
        self.typePattern = typePattern
        self.isPrefix = isPrefix
        self.action = action
        self.maxSizeMiB = maxSizeMiB
    }

    /// app + type > app only > type only. `nil` for a rule that constrains nothing, or whose type
    /// pattern is empty (a half-edited rule must not turn into "every type"), is ignored.
    var precedenceLevel: Int? {
        if typePattern?.isEmpty == true { return nil }
        return switch (appBundleID != nil, typePattern != nil) {
        case (true, true): 3
        case (true, false): 2
        case (false, true): 1
        case (false, false): nil
        }
    }

    func matches(app: String?) -> Bool {
        appBundleID == nil || appBundleID == app
    }

    func matches(type: PasteboardType) -> Bool {
        guard let typePattern else { return true }
        return isPrefix ? type.rawValue.hasPrefix(typePattern) : type.rawValue == typePattern
    }
}

/// One slot of an item's canonical representation order (PLAN §3.3).
public enum PlannedSlot: Sendable, Equatable {
    case bytes(PasteboardType)
    /// One coalesced file list; reads whichever file representations are declared and not skipped.
    case files(effectiveType: PasteboardType, readFileURL: Bool, readFilenames: Bool)

    public var type: PasteboardType {
        switch self {
        case .bytes(let type): type
        case .files(let effectiveType, _, _): effectiveType
        }
    }
}

public struct PlannedItem: Sendable, Equatable {
    /// Index of the item on the pasteboard.
    public var sourceIndex: Int
    public var slots: [PlannedSlot]
}

/// Which representations to read for one change, decided from declared types only.
public struct SnapshotPlan: Sendable, Equatable {
    /// Retained items (at least one slot), in pasteboard order.
    public var items: [PlannedItem]
    /// Types the user may care about that will not be stored: unsupported or skipped by a rule.
    /// Redundant rasters and images next to file references are not listed.
    public var skippedTypes: [PasteboardType]
    /// Effective size limit for this snapshot in bytes.
    public var maxBytes: Int
}

/// Default policy + user rules (PLAN §3.2.2).
public struct FormatPolicy: Sendable, Equatable {
    public static let mebibyte = 1 << 20
    public static let hardMaxBytes = 256 * mebibyte
    public static let defaultMaxBytes = 32 * mebibyte

    public var rules: [FormatRule]
    /// Global `maxSinglePayloadBytes` setting.
    public var defaultMaxBytes: Int

    public init(rules: [FormatRule] = [], defaultMaxBytes: Int = FormatPolicy.defaultMaxBytes) {
        self.rules = rules
        self.defaultMaxBytes = defaultMaxBytes
    }

    /// - Parameters:
    ///   - keepAllDeclaredTypes: *Save anyway* for a change with no supported formats (§3.2.3).
    public func plan(
        itemTypes: [[PasteboardType]],
        app: String?,
        profileSizeLimitMiB: Int? = nil,
        keepAllDeclaredTypes: Bool = false
    ) -> SnapshotPlan {
        var items: [PlannedItem] = []
        var skipped: [PasteboardType] = []

        for (index, declared) in itemTypes.enumerated() {
            let types = unique(declared).filter { !$0.isMetadataOnly }
            var keep: Set<PasteboardType> = []
            var explicitlyKept: Set<PasteboardType> = []

            for type in types {
                if keepAllDeclaredTypes {
                    keep.insert(type)
                    continue
                }
                switch decisiveRule(app: app, type: type)?.action {
                case .keep:
                    keep.insert(type)
                    explicitlyKept.insert(type)
                case .skip:
                    skipped.append(type)
                case nil:
                    if type.isAllowlisted { keep.insert(type) } else { skipped.append(type) }
                }
            }

            let hasFileSlot = types.contains { $0.isFileReference && keep.contains($0) }
            if hasFileSlot {
                // Images next to file references are previews of the files, not payload (§3.3).
                keep = keep.filter { !$0.isRasterImage }
            } else if !keepAllDeclaredTypes {
                keep = dropRedundantRasters(keep, explicitlyKept: explicitlyKept)
            }

            var slots: [PlannedSlot] = []
            var fileSlotEmitted = false
            for type in types where keep.contains(type) {
                if type.isFileReference {
                    guard !fileSlotEmitted else { continue }
                    fileSlotEmitted = true
                    let readFileURL = keep.contains(.fileURL)
                    slots.append(.files(
                        effectiveType: readFileURL ? .fileURL : .filenames,
                        readFileURL: readFileURL,
                        readFilenames: keep.contains(.filenames)
                    ))
                } else {
                    slots.append(.bytes(type))
                }
            }
            if !slots.isEmpty { items.append(PlannedItem(sourceIndex: index, slots: slots)) }
        }

        return SnapshotPlan(
            items: items,
            skippedTypes: unique(skipped),
            maxBytes: maxBytes(itemTypes: itemTypes, app: app, profileSizeLimitMiB: profileSizeLimitMiB)
        )
    }

    /// Highest precedence level wins; within a level, list order.
    func decisiveRule(app: String?, type: PasteboardType) -> FormatRule? {
        var best: (level: Int, rule: FormatRule)?
        for rule in rules {
            guard let level = rule.precedenceLevel, rule.matches(app: app), rule.matches(type: type) else { continue }
            if best == nil || level > best!.level { best = (level, rule) }
        }
        return best?.rule
    }

    /// Keep the first raster by preference; explicitly kept rasters always stay.
    private func dropRedundantRasters(_ keep: Set<PasteboardType>, explicitlyKept: Set<PasteboardType>) -> Set<PasteboardType> {
        guard let chosen = PasteboardType.rasterImagePreference.first(where: keep.contains) else { return keep }
        return keep.filter { !$0.isRasterImage || $0 == chosen || explicitlyKept.contains($0) }
    }

    /// The largest matching per-app or rule limit wins; otherwise the global setting. Never above the hard max.
    private func maxBytes(itemTypes: [[PasteboardType]], app: String?, profileSizeLimitMiB: Int?) -> Int {
        let declared = Set(itemTypes.joined())
        var limits: [Int] = []
        if let profileSizeLimitMiB { limits.append(profileSizeLimitMiB) }
        for rule in rules {
            guard let size = rule.maxSizeMiB, rule.precedenceLevel != nil, rule.matches(app: app) else { continue }
            if rule.typePattern == nil || declared.contains(where: rule.matches(type:)) { limits.append(size) }
        }
        guard let largest = limits.max() else { return min(defaultMaxBytes, Self.hardMaxBytes) }
        return min(max(largest, 0) * Self.mebibyte, Self.hardMaxBytes)
    }

    private func unique(_ types: [PasteboardType]) -> [PasteboardType] {
        var seen: Set<PasteboardType> = []
        return types.filter { seen.insert($0).inserted }
    }
}
