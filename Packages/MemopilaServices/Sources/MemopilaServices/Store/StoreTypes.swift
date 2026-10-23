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
}

/// Details loaded on demand for the preview (§8.5).
public struct RecordDetails: Sendable, Equatable {
    public let card: HistoryCard
    public let text: String?
    public let recognizedText: String?
    public let storedTypes: [String]
    public let sourceWindowTitle: String?
    public let collectionIDs: Set<UUID>
}

/// Sidebar scopes (§8.2).
public enum HistoryScope: Sendable, Hashable {
    case all
    case favorites
    case app(String)
    case type(DisplayType)
    case collection(UUID)
}

public struct HistoryQuery: Sendable, Hashable {
    public var scope: HistoryScope
    public var search: String

    public init(scope: HistoryScope = .all, search: String = "") {
        self.scope = scope
        self.search = search
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
public struct RestorePayload: Sendable {
    public let items: [CanonicalItem]
    public let sourceBundleID: String?
    public let text: String?
}
