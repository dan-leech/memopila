import Foundation

/// The pasteboard as seen by `SnapshotReader`. On macOS an adapter wraps `NSPasteboard.general`;
/// tests use an in-memory fake. Implementations copy data out immediately and never keep items.
public protocol PasteboardSource {
    var changeCount: Int { get }
    /// Declared types of every item, in pasteboard order.
    func itemTypes() -> [[PasteboardType]]
    /// One representation of one item; `nil` = the read failed (nil, error or a converted ObjC exception).
    func data(forItem index: Int, type: PasteboardType) -> Data?
    /// String value of one representation; `nil` = unreadable.
    func string(forItem index: Int, type: PasteboardType) -> String?
}

extension PasteboardSource {
    public func string(forItem index: Int, type: PasteboardType) -> String? {
        data(forItem: index, type: type).flatMap { String(validating: $0, as: UTF8.self) }
    }
}

/// Everything the reader needs besides the pasteboard (PLAN §3.2).
public struct CaptureContext: Sendable {
    public var profiles: AppProfiles
    public var formatPolicy: FormatPolicy
    public var frontmostBundleID: String?
    public var panelIsKey: Bool
    public var ownBundleID: String
    public var ignoreRemoteClipboard: Bool
    /// *Save anyway* (§3.2.3): size limit raised to the hard max, all declared types kept.
    public var saveAnyway: Bool
    /// Copied credentials (§3.10).
    public var secretPolicy: SecretPolicy
    /// Kinds the user left on in Settings.
    public var secretKinds: Set<SecretKind>

    public init(
        profiles: AppProfiles = AppProfiles(),
        formatPolicy: FormatPolicy = FormatPolicy(),
        frontmostBundleID: String? = nil,
        panelIsKey: Bool = false,
        ownBundleID: String,
        ignoreRemoteClipboard: Bool = false,
        saveAnyway: Bool = false,
        secretPolicy: SecretPolicy = .off,
        secretKinds: Set<SecretKind> = Set(SecretKind.allCases)
    ) {
        self.profiles = profiles
        self.formatPolicy = formatPolicy
        self.frontmostBundleID = frontmostBundleID
        self.panelIsKey = panelIsKey
        self.ownBundleID = ownBundleID
        self.ignoreRemoteClipboard = ignoreRemoteClipboard
        self.saveAnyway = saveAnyway
        self.secretPolicy = secretPolicy
        self.secretKinds = secretKinds
    }
}

public enum SkipReason: Sendable, Equatable {
    case privacyMarker(PasteboardType)
    case dontSave
    case strictIdentity
    case remoteClipboard
    case empty
    /// The text contains a credential and the policy is *Don't save* (§3.10).
    case secret(SecretKind)
}

public enum NotSavedReason: Sendable, Equatable {
    case noSupportedFormats
    case tooLarge(limitBytes: Int)
    case readFailed(PasteboardType)
}

/// What the red Current card can show about a change that was not saved (§3.2.3).
public struct UnsavedChange: Sendable, Equatable {
    public var identity: AppIdentity
    public var declaredTypes: [PasteboardType]
    /// Lower bound: bytes read before the attempt stopped.
    public var knownBytes: Int

    public init(identity: AppIdentity, declaredTypes: [PasteboardType], knownBytes: Int) {
        self.identity = identity
        self.declaredTypes = declaredTypes
        self.knownBytes = knownBytes
    }
}

/// An owned, immutable copy of one stable change, ready for `ClipboardStore.ingest`.
public struct OwnedSnapshot: Sendable, Equatable {
    public var changeCount: Int
    /// Frozen when the guard completed; retries reuse it (§3.2).
    public var observedAt: Date
    public var identity: AppIdentity
    public var settings: ResolvedAppSettings
    public var items: [CanonicalItem]
    public var contentHash: String
    public var payloadSizeBytes: Int
    public var displayType: DisplayType
    public var skippedTypes: [PasteboardType]
    public var sourceURL: String?
    /// A credential was found in the text (§3.10): the card masks it.
    public var sensitiveKind: SecretKind?

    public init(
        changeCount: Int,
        observedAt: Date,
        identity: AppIdentity,
        settings: ResolvedAppSettings,
        items: [CanonicalItem],
        contentHash: String,
        payloadSizeBytes: Int,
        displayType: DisplayType,
        skippedTypes: [PasteboardType],
        sourceURL: String?,
        sensitiveKind: SecretKind? = nil
    ) {
        self.changeCount = changeCount
        self.observedAt = observedAt
        self.identity = identity
        self.settings = settings
        self.items = items
        self.contentHash = contentHash
        self.payloadSizeBytes = payloadSizeBytes
        self.displayType = displayType
        self.skippedTypes = skippedTypes
        self.sourceURL = sourceURL
        self.sensitiveKind = sensitiveKind
    }
}

public enum SnapshotReadOutcome: Sendable, Equatable {
    /// `changeCount` moved during the attempt: discard, do not mark handled.
    case unstable
    case skipped(changeCount: Int, reason: SkipReason)
    case notSaved(changeCount: Int, reason: NotSavedReason, change: UnsavedChange)
    case captured(OwnedSnapshot)

    /// Whether the monitor marks the change handled (outcome table, §3.2).
    public var marksHandled: Bool {
        if case .unstable = self { return false }
        return true
    }

    public var changeCount: Int? {
        switch self {
        case .unstable: nil
        case .skipped(let changeCount, _), .notSaved(let changeCount, _, _): changeCount
        case .captured(let snapshot): snapshot.changeCount
        }
    }
}

/// One `changeCount`-guarded read of the pasteboard (PLAN §3.2 "Pasteboard stability during read").
/// Markers, identity, per-app settings and format decisions all happen inside the guard,
/// from declared types only, before any payload is read.
public struct SnapshotReader: Sendable {
    public var context: CaptureContext
    public var now: @Sendable () -> Date

    public init(context: CaptureContext, now: @escaping @Sendable () -> Date = { Date() }) {
        self.context = context
        self.now = now
    }

    public func read(_ pasteboard: some PasteboardSource) -> SnapshotReadOutcome {
        let initialCount = pasteboard.changeCount
        let itemTypes = pasteboard.itemTypes()

        func finish(_ outcome: (Int) -> SnapshotReadOutcome) -> SnapshotReadOutcome {
            pasteboard.changeCount == initialCount ? outcome(initialCount) : .unstable
        }

        if let hit = PrivacyMarker.firstHit(in: itemTypes) {
            return finish { .skipped(changeCount: $0, reason: .privacyMarker(hit.type)) }
        }
        if context.ignoreRemoteClipboard, itemTypes.contains(where: { $0.contains(.remoteClipboard) }) {
            return finish { .skipped(changeCount: $0, reason: .remoteClipboard) }
        }

        let marker = SourceMarker.resolve(itemTypes.indices.map { (index) -> ItemSourceValue in
            guard itemTypes[index].contains(.source) else { return .notDeclared }
            return pasteboard.string(forItem: index, type: .source).map(ItemSourceValue.value) ?? .unreadable
        })
        let identity = AppIdentity.resolve(
            marker: marker,
            frontmostBundleID: context.frontmostBundleID,
            panelIsKey: context.panelIsKey,
            ownBundleID: context.ownBundleID
        )

        var settings: ResolvedAppSettings
        switch context.profiles.admission(for: identity) {
        case .skipDontSave:
            return finish { .skipped(changeCount: $0, reason: .dontSave) }
        case .skipStrict:
            return finish { .skipped(changeCount: $0, reason: .strictIdentity) }
        case .capture(let resolved):
            settings = resolved
        }

        let declaredTypes = Self.contentTypes(itemTypes)
        guard !declaredTypes.isEmpty else {
            return finish { .skipped(changeCount: $0, reason: .empty) }
        }

        let plan = context.formatPolicy.plan(
            itemTypes: itemTypes,
            app: identity.bundleID,
            profileSizeLimitMiB: settings.sizeLimitMiB,
            keepAllDeclaredTypes: context.saveAnyway
        )
        let limit = context.saveAnyway ? FormatPolicy.hardMaxBytes : plan.maxBytes
        func unsaved(_ knownBytes: Int) -> UnsavedChange {
            UnsavedChange(identity: identity, declaredTypes: declaredTypes, knownBytes: knownBytes)
        }
        guard !plan.items.isEmpty else {
            return finish { .notSaved(changeCount: $0, reason: .noSupportedFormats, change: unsaved(0)) }
        }

        var items: [CanonicalItem] = []
        var acceptedBytes = 0
        for plannedItem in plan.items {
            var representations: [CanonicalRepresentation] = []
            for slot in plannedItem.slots {
                guard let representation = Self.read(slot, item: plannedItem.sourceIndex, from: pasteboard) else {
                    return finish { .notSaved(changeCount: $0, reason: .readFailed(slot.type), change: unsaved(acceptedBytes)) }
                }
                acceptedBytes += representation.byteCount
                guard acceptedBytes <= limit else {
                    return finish { .notSaved(changeCount: $0, reason: .tooLarge(limitBytes: limit), change: unsaved(acceptedBytes)) }
                }
                representations.append(representation)
            }
            items.append(CanonicalItem(representations))
        }

        let sourceURL = settings.recordSourcePage ? Self.sourceURL(itemTypes: itemTypes, items: items, pasteboard: pasteboard) : nil

        var sensitiveKind: SecretKind?
        if context.secretPolicy != .off, let text = TextDecoding.plainText(of: items), let kind = SecretDetector.detect(text, kinds: context.secretKinds) {
            switch context.secretPolicy {
            case .off:
                break
            case .dontSave:
                return finish { .skipped(changeCount: $0, reason: .secret(kind)) }
            case .deleteAfter(let minutes):
                // The shorter of the app's own retention and the secret retention wins.
                settings.captureMode = .deleteAfter(minutes: min(minutes, settings.retentionMinutes ?? minutes))
            }
            sensitiveKind = kind
        }

        return finish { changeCount in
            .captured(OwnedSnapshot(
                changeCount: changeCount,
                observedAt: now(),
                identity: identity,
                settings: settings,
                items: items,
                contentHash: MCS1.contentHash(of: items),
                payloadSizeBytes: acceptedBytes,
                displayType: DisplayType.classify(items),
                skippedTypes: plan.skippedTypes,
                sourceURL: sourceURL,
                sensitiveKind: sensitiveKind
            ))
        }
    }

    private static func read(_ slot: PlannedSlot, item: Int, from pasteboard: some PasteboardSource) -> CanonicalRepresentation? {
        withAutoreleasePool { () -> CanonicalRepresentation? in
            switch slot {
            case .bytes(let type):
                return pasteboard.data(forItem: item, type: type).map { CanonicalRepresentation.bytes(type, $0) }
            case .files(let effectiveType, let readFileURL, let readFilenames):
                var fileURLPaths: [String]?
                var filenamesPaths: [String]?
                if readFileURL {
                    guard let data = pasteboard.data(forItem: item, type: .fileURL),
                          let paths = FilePathNormalizer.paths(fromFileURLData: data) else { return nil }
                    fileURLPaths = paths
                }
                if readFilenames {
                    guard let data = pasteboard.data(forItem: item, type: .filenames),
                          let paths = FilePathNormalizer.paths(fromFilenamesPropertyList: data) else { return nil }
                    filenamesPaths = paths
                }
                return FilePathNormalizer
                    .coalesce(fileURLPaths: fileURLPaths, filenamesPaths: filenamesPaths)
                    .map { CanonicalRepresentation.files(effectiveType, $0) }
            }
        }
    }

    /// Chromium metadata first, then a stored web archive (§5.2). Metadata reads are outside the size budget.
    private static func sourceURL(itemTypes: [[PasteboardType]], items: [CanonicalItem], pasteboard: some PasteboardSource) -> String? {
        for (index, types) in itemTypes.enumerated() where types.contains(.chromiumSourceURL) {
            if let data = pasteboard.data(forItem: index, type: .chromiumSourceURL),
               let url = SourcePage.url(fromChromiumSourceURL: data) {
                return url
            }
        }
        for representation in items.lazy.flatMap(\.representations)
        where representation.type == .webArchive || representation.type == .legacyWebArchive {
            if let data = representation.bytes, let url = SourcePage.url(fromWebArchive: data) { return url }
        }
        return nil
    }

    /// Declared non-metadata types across all items, first occurrence order.
    private static func contentTypes(_ itemTypes: [[PasteboardType]]) -> [PasteboardType] {
        var seen: Set<PasteboardType> = []
        return itemTypes.joined().filter { !$0.isMetadataOnly && seen.insert($0).inserted }
    }
}

/// Drains temporaries from each pasteboard read right away on Darwin (§7.3).
@inline(__always)
func withAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}
