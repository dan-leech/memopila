import Foundation

/// Record metadata touched by a dedup hit (PLAN §4).
public struct RecordMetadata: Sendable, Equatable {
    public var firstCopiedAt: Date
    public var lastCopiedAt: Date
    public var copyCount: Int
    public var isFavorite: Bool
    public var lastSourceAppBundleID: String?
    public var lastSourceAppName: String?
    public var sourceURL: String?
    public var sourceWindowTitle: String?
    public var expiresAt: Date?

    public init(
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        copyCount: Int,
        isFavorite: Bool = false,
        lastSourceAppBundleID: String? = nil,
        lastSourceAppName: String? = nil,
        sourceURL: String? = nil,
        sourceWindowTitle: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.isFavorite = isFavorite
        self.lastSourceAppBundleID = lastSourceAppBundleID
        self.lastSourceAppName = lastSourceAppName
        self.sourceURL = sourceURL
        self.sourceWindowTitle = sourceWindowTitle
        self.expiresAt = expiresAt
    }
}

/// One observation of content, with its frozen `observedAt` (never the retry wall-clock).
public struct CaptureObservation: Sendable, Equatable {
    public var observedAt: Date
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var sourceURL: String?
    public var sourceWindowTitle: String?
    /// *Delete after* retention of the source app, if any.
    public var retentionMinutes: Int?

    public init(
        observedAt: Date,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        sourceURL: String? = nil,
        sourceWindowTitle: String? = nil,
        retentionMinutes: Int? = nil
    ) {
        self.observedAt = observedAt
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.sourceURL = sourceURL
        self.sourceWindowTitle = sourceWindowTitle
        self.retentionMinutes = retentionMinutes
    }

    var expiresAt: Date? {
        retentionMinutes.map { observedAt.addingTimeInterval(TimeInterval($0) * 60) }
    }
}

public enum DedupMerge {
    public static func newRecord(from observation: CaptureObservation) -> RecordMetadata {
        RecordMetadata(
            firstCopiedAt: observation.observedAt,
            lastCopiedAt: observation.observedAt,
            copyCount: 1,
            lastSourceAppBundleID: observation.sourceAppBundleID,
            lastSourceAppName: observation.sourceAppName,
            sourceURL: observation.sourceURL,
            sourceWindowTitle: observation.sourceWindowTitle,
            expiresAt: observation.expiresAt
        )
    }

    /// Timestamps by min/max; attribution, source page and expiry only from the newest observation,
    /// so a late retry of an older observation cannot overwrite newer data. Favorites never expire.
    public static func merge(_ existing: RecordMetadata, with observation: CaptureObservation) -> RecordMetadata {
        var merged = existing
        merged.firstCopiedAt = min(existing.firstCopiedAt, observation.observedAt)
        merged.lastCopiedAt = max(existing.lastCopiedAt, observation.observedAt)
        merged.copyCount = existing.copyCount + 1
        // An observation of unknown origin (the content at launch, a remote clipboard) says nothing
        // about who copied it: a known source, its page and its expiry stay (review finding: it
        // cleared *Delete after* and the app filter).
        let replacesSource = observation.sourceAppBundleID != nil || existing.lastSourceAppBundleID == nil
        if observation.observedAt >= existing.lastCopiedAt, replacesSource {
            merged.lastSourceAppBundleID = observation.sourceAppBundleID
            merged.lastSourceAppName = observation.sourceAppName
            merged.sourceURL = observation.sourceURL
            merged.sourceWindowTitle = observation.sourceWindowTitle
            merged.expiresAt = existing.isFavorite ? nil : observation.expiresAt
        }
        return merged
    }

    /// Edit collided with another record (§3.6): merge the edited record into the survivor.
    public static func mergeEdited(_ edited: RecordMetadata, into survivor: RecordMetadata) -> RecordMetadata {
        var merged = survivor
        merged.firstCopiedAt = min(survivor.firstCopiedAt, edited.firstCopiedAt)
        merged.lastCopiedAt = max(survivor.lastCopiedAt, edited.lastCopiedAt)
        merged.copyCount = survivor.copyCount + edited.copyCount
        merged.isFavorite = survivor.isFavorite || edited.isFavorite
        if merged.isFavorite { merged.expiresAt = nil }
        return merged
    }
}
