import Foundation
import MemopilaCore

/// Text recognition progress of an image record (§3.8).
public enum RecognitionState: String, Sendable, Codable {
    case pending
    case done
    case noText
    case failed
    case off
}

/// Grid entry: a history record or a paste stack (§3.11). Selection/drag use this ID, never a bare UUID (P15).
public enum HistoryEntry: Sendable, Identifiable, Equatable {
    case record(HistoryCard)
    case stack(StackCard)

    public enum ID: Hashable, Sendable {
        case record(UUID)
        case stack(UUID)
    }

    public var id: ID {
        switch self {
        case .record(let card): .record(card.id)
        case .stack(let card): .stack(card.id)
        }
    }

    public var sortDate: Date {
        switch self {
        case .record(let card): card.lastCopiedAt
        case .stack(let card): card.lastUsedAt
        }
    }

    public var useCount: Int {
        switch self {
        case .record(let card): card.useCount
        case .stack(let card): card.useCount
        }
    }
}

/// History arrange mode (§8.2): newest activity vs Choose frequency.
public enum HistorySortMode: String, Sendable, Hashable, CaseIterable {
    case recent
    case mostUsed
}

/// Paste-stack card DTO (§3.11 / §7.1).
public struct StackCard: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let isFavorite: Bool
    public let loops: Bool
    public let dealMode: StackDealMode
    public let createdAt: Date
    public let lastUsedAt: Date
    public let useCount: Int
    /// UI-order member record ids.
    public let memberIDs: [UUID]
    /// First UI-order member — stack card face always shows this (deal cursor is badge-only; Choose resets it).
    public let previewRecordID: UUID?
    public let memberCount: Int
    public let collectionIDs: Set<UUID>
    /// Preview member's sensitive kind, if any — mask the stack card.
    public let sensitiveKind: String?
    public let preview: String

    public init(
        id: UUID,
        title: String,
        isFavorite: Bool,
        loops: Bool,
        dealMode: StackDealMode,
        createdAt: Date,
        lastUsedAt: Date,
        useCount: Int = 0,
        memberIDs: [UUID],
        previewRecordID: UUID?,
        memberCount: Int,
        collectionIDs: Set<UUID> = [],
        sensitiveKind: String? = nil,
        preview: String = ""
    ) {
        self.id = id
        self.title = title
        self.isFavorite = isFavorite
        self.loops = loops
        self.dealMode = dealMode
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.memberIDs = memberIDs
        self.previewRecordID = previewRecordID
        self.memberCount = memberCount
        self.collectionIDs = collectionIDs
        self.sensitiveKind = sensitiveKind
        self.preview = preview
    }

    /// Optimistic grid patch — same fields, flipped favorite flag.
    public func withFavorite(_ isFavorite: Bool) -> StackCard {
        StackCard(
            id: id,
            title: title,
            isFavorite: isFavorite,
            loops: loops,
            dealMode: dealMode,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            memberIDs: memberIDs,
            previewRecordID: previewRecordID,
            memberCount: memberCount,
            collectionIDs: collectionIDs,
            sensitiveKind: sensitiveKind,
            preview: preview
        )
    }

    /// Optimistic playlist order patch after drag / Move in Stack (face = first UI member).
    public func withMemberIDs(
        _ memberIDs: [UUID],
        preview: String? = nil,
        sensitiveKind: String? = nil
    ) -> StackCard {
        let first = memberIDs.first
        let sameFirst = first == previewRecordID
        return StackCard(
            id: id,
            title: title,
            isFavorite: isFavorite,
            loops: loops,
            dealMode: dealMode,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            memberIDs: memberIDs,
            previewRecordID: first,
            memberCount: memberIDs.count,
            collectionIDs: collectionIDs,
            sensitiveKind: sensitiveKind ?? (sameFirst ? self.sensitiveKind : nil),
            preview: preview ?? (sameFirst ? self.preview : "")
        )
    }

    /// Optimistic Deal / Loop chrome patch (toolbar reads `scopedStack` from `allStacks`).
    public func withDeal(mode: StackDealMode, loops: Bool) -> StackCard {
        StackCard(
            id: id,
            title: title,
            isFavorite: isFavorite,
            loops: loops,
            dealMode: mode,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            memberIDs: memberIDs,
            previewRecordID: previewRecordID,
            memberCount: memberCount,
            collectionIDs: collectionIDs,
            sensitiveKind: sensitiveKind,
            preview: preview
        )
    }
}

/// What a card shows; no payload bytes, no thumbnail data (§7.1 read models).
public struct HistoryCard: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let displayType: DisplayType
    public let preview: String
    public let customTitle: String?
    public let textLength: Int?
    public let lineCount: Int?
    /// `SecretKind` raw value: show the card masked (§3.10).
    public let sensitiveKind: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let filePaths: [String]
    public let colorHex: String?
    public let payloadSizeBytes: Int
    public let firstCopiedAt: Date
    public let lastCopiedAt: Date
    public let copyCount: Int
    public let useCount: Int
    public let isFavorite: Bool
    public let sourceAppBundleID: String?
    public let sourceAppName: String?
    public let sourceURL: String?
    public let isEdited: Bool
    public let expiresAt: Date?
    public let hasRecognizedText: Bool
    public let storedTypes: [String]
    public let skippedTypes: [String]
    public let hasThumbnail: Bool
    public let codeLanguage: String?

    /// Plain text can be produced for Copy as plain text and text actions.
    public var hasText: Bool { textLength != nil }

    public init(
        id: UUID,
        displayType: DisplayType,
        preview: String,
        customTitle: String?,
        textLength: Int?,
        lineCount: Int?,
        sensitiveKind: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        filePaths: [String],
        colorHex: String?,
        payloadSizeBytes: Int,
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        copyCount: Int,
        useCount: Int = 0,
        isFavorite: Bool,
        sourceAppBundleID: String?,
        sourceAppName: String?,
        sourceURL: String?,
        isEdited: Bool,
        expiresAt: Date?,
        hasRecognizedText: Bool,
        storedTypes: [String],
        skippedTypes: [String],
        hasThumbnail: Bool,
        codeLanguage: String?
    ) {
        self.id = id
        self.displayType = displayType
        self.preview = preview
        self.customTitle = customTitle
        self.textLength = textLength
        self.lineCount = lineCount
        self.sensitiveKind = sensitiveKind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.filePaths = filePaths
        self.colorHex = colorHex
        self.payloadSizeBytes = payloadSizeBytes
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.useCount = useCount
        self.isFavorite = isFavorite
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.sourceURL = sourceURL
        self.isEdited = isEdited
        self.expiresAt = expiresAt
        self.hasRecognizedText = hasRecognizedText
        self.storedTypes = storedTypes
        self.skippedTypes = skippedTypes
        self.hasThumbnail = hasThumbnail
        self.codeLanguage = codeLanguage
    }

    /// Optimistic grid patch. Favor-on clears `expiresAt` (store does the same, §6).
    public func withFavorite(_ isFavorite: Bool) -> HistoryCard {
        HistoryCard(
            id: id,
            displayType: displayType,
            preview: preview,
            customTitle: customTitle,
            textLength: textLength,
            lineCount: lineCount,
            sensitiveKind: sensitiveKind,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            filePaths: filePaths,
            colorHex: colorHex,
            payloadSizeBytes: payloadSizeBytes,
            firstCopiedAt: firstCopiedAt,
            lastCopiedAt: lastCopiedAt,
            copyCount: copyCount,
            useCount: useCount,
            isFavorite: isFavorite,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            sourceURL: sourceURL,
            isEdited: isEdited,
            expiresAt: isFavorite ? nil : expiresAt,
            hasRecognizedText: hasRecognizedText,
            storedTypes: storedTypes,
            skippedTypes: skippedTypes,
            hasThumbnail: hasThumbnail,
            codeLanguage: codeLanguage
        )
    }
}

/// Details loaded on demand for the preview (§8.5).
public struct RecordDetails: Sendable, Equatable {
    public let card: HistoryCard
    public let text: String?
    public let recognizedText: String?
    /// Where text recognition stands for an image or PDF (§3.8): pending, done, no text, failed or off.
    public let recognitionState: RecognitionState
    public let storedTypes: [String]
    public let sourceWindowTitle: String?
    public let collectionIDs: Set<UUID>
    /// The page title a browser put next to a copied link (`public.url-name`).
    public let linkTitle: String?
}

/// Sidebar scopes (§8.2) and stack drill-down (§3.11).
public enum HistoryScope: Sendable, Hashable {
    case all
    case favorites
    case app(String)
    case type(DisplayType)
    case collection(UUID)
    /// Members of a paste stack in UI/`StackMember.position` order (not `lastCopiedAt`).
    case stack(UUID)

    /// Favorites / Collections: ordered pinboards (slot positions), not History recency.
    public var isPinboard: Bool {
        switch self {
        case .favorites, .collection: true
        default: false
        }
    }
}

public struct HistoryQuery: Sendable, Hashable {
    public var scope: HistoryScope
    public var search: String
    /// The filter bar's kind (§8.2): records of these display types; empty = every type.
    public var kinds: Set<DisplayType>
    /// The filter bar's period: records copied since this date; `nil` = any time.
    public var since: Date?
    /// History arrange (§8.2). Pinboards / stack drill-down ignore this.
    public var sort: HistorySortMode

    public init(
        scope: HistoryScope = .all,
        search: String = "",
        kinds: Set<DisplayType> = [],
        since: Date? = nil,
        sort: HistorySortMode = .recent
    ) {
        self.scope = scope
        self.search = search
        self.kinds = kinds
        self.since = since
        self.sort = sort
    }

    var words: [String] {
        search.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

public struct AppSummary: Sendable, Identifiable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String?
    public let count: Int
    public let lastCopiedAt: Date
}

/// Settings → History (§8.7): metadata only, no payload bytes are read.
public struct HistoryUsage: Sendable, Equatable {
    public let count: Int
    public let favorites: Int
    /// Σ `payloadSizeBytes`: the logical quota of §6, not the size on disk.
    public let payloadBytes: Int
}

public struct CollectionSummary: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let count: Int
}

/// Retention settings for one store call (§6).
public struct RetentionLimits: Sendable, Equatable {
    public var maxCount: Int
    public var maxAge: TimeInterval
    public var maxStorageBytes: Int

    public init(
        maxCount: Int = RetentionPlanner.defaultMaxCount,
        maxAge: TimeInterval = RetentionPlanner.defaultMaxAge,
        maxStorageBytes: Int = RetentionPlanner.defaultMaxStorageBytes
    ) {
        self.maxCount = maxCount
        self.maxAge = maxAge
        self.maxStorageBytes = maxStorageBytes
    }
}

/// Store results the monitor reconciles on (§3.5).
public enum IngestResult: Sendable, Equatable {
    case committed(UUID)
    case merged(UUID)
    case rejected(String)
    case failed(String)
    /// Raced with Clear / Delete / Edit (§3.2 rule 5).
    case dropped
}

public enum EditResult: Sendable, Equatable {
    case updated
    /// The new text equals another record; the edited record was merged into it (§3.6).
    case merged(into: UUID)
    case rejected(String)
}

public enum ClearScope: Sendable {
    case nonFavorites
    case all
}

public enum StoreError: Error, Sendable, Equatable {
    case notFound
    case unreadable(String)
}

/// Payload ready for Restore, already verified (§3.5).
/// Formatted text saved from the record window (§3.6): RTF, or flat RTFD when it holds
/// attachments, plus HTML for apps that read only HTML (browsers, web apps).
public struct RichContent: Sendable, Equatable {
    public let type: PasteboardType
    public let data: Data
    public let html: Data?

    public init(type: PasteboardType, data: Data, html: Data?) {
        self.type = type
        self.data = data
        self.html = html
    }
}

public struct RestorePayload: Sendable {
    public let items: [CanonicalItem]
    public let sourceBundleID: String?
    public let text: String?
}
