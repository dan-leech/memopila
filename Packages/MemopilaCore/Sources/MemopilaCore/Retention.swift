import Foundation

/// Record metadata the retention planner needs (PLAN §6). Loaded without payload bytes.
public struct RetentionCandidate: Sendable, Equatable {
    public var id: UUID
    public var isFavorite: Bool
    /// Favorite or member of any paste stack (§3.11 / §6 pin).
    public var isPinned: Bool
    public var lastCopiedAt: Date
    public var payloadSizeBytes: Int
    public var expiresAt: Date?

    public init(
        id: UUID,
        isFavorite: Bool,
        lastCopiedAt: Date,
        payloadSizeBytes: Int,
        expiresAt: Date? = nil,
        isPinned: Bool? = nil
    ) {
        self.id = id
        self.isFavorite = isFavorite
        self.isPinned = isPinned ?? isFavorite
        self.lastCopiedAt = lastCopiedAt
        self.payloadSizeBytes = payloadSizeBytes
        self.expiresAt = expiresAt
    }
}

public enum IngestPlan: Sendable, Equatable {
    /// Insert the new record and delete `victims` in the same transaction.
    case accept(victims: [UUID])
    /// Still over `maxStorageBytes` without touching pinned records: no deletes, no insert.
    case rejectQuota
}

/// Victim planning for `ClipboardStore` (PLAN §6). Pinned records are never victims.
/// Oldest first by `lastCopiedAt`; ties broken by id for determinism.
public enum RetentionPlanner {
    public static let defaultMaxCount = 500
    public static let maxCountRange = 1...10_000
    public static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60
    public static let defaultMaxStorageBytes = 512 * (1 << 20)
    /// The storage limit in Settings, in MiB.
    public static let maxStorageMiBRange = 64...16_384

    /// Storage preflight for a new unique non-pinned (§6 steps 3–8).
    public static func planIngest(
        existing: [RetentionCandidate],
        newPayloadBytes: Int,
        maxCount: Int,
        maxStorageBytes: Int
    ) -> IngestPlan {
        let free = oldestFirst(existing.filter { !$0.isPinned })
        let countVictims = Array(free.prefix(max(0, free.count + 1 - maxCount)))
        let actualStoredBytes = existing.reduce(0) { $0 + $1.payloadSizeBytes }
        let countVictimBytes = countVictims.reduce(0) { $0 + $1.payloadSizeBytes }
        let required = max(0, actualStoredBytes + newPayloadBytes - maxStorageBytes - countVictimBytes)

        var victims = countVictims
        var reclaimed = 0
        for candidate in free.dropFirst(countVictims.count) where reclaimed < required {
            victims.append(candidate)
            reclaimed += candidate.payloadSizeBytes
        }
        let victimBytes = countVictimBytes + reclaimed
        guard actualStoredBytes + newPayloadBytes - victimBytes <= maxStorageBytes else { return .rejectQuota }
        return .accept(victims: victims.map(\.id))
    }

    /// Settings lowered `maxCount`: oldest non-pinned until `freeCount ≤ maxCount`.
    public static func planCountShrink(existing: [RetentionCandidate], maxCount: Int) -> [UUID] {
        let free = oldestFirst(existing.filter { !$0.isPinned })
        return free.prefix(max(0, free.count - maxCount)).map(\.id)
    }

    /// Settings lowered the storage limit: oldest non-pinned until everything fits. Pinned
    /// count but are never deleted, so with many of them the total may stay above the limit.
    public static func planStorageShrink(existing: [RetentionCandidate], maxStorageBytes: Int) -> [UUID] {
        let pinnedBytes = existing.filter(\.isPinned).reduce(0) { $0 + $1.payloadSizeBytes }
        guard pinnedBytes <= maxStorageBytes else { return [] }
        var excess = existing.reduce(0) { $0 + $1.payloadSizeBytes } - maxStorageBytes
        var victims: [UUID] = []
        for candidate in oldestFirst(existing.filter { !$0.isPinned }) where excess > 0 {
            victims.append(candidate.id)
            excess -= candidate.payloadSizeBytes
        }
        return victims
    }

    /// After unpinning `id` (already non-pinned in `existing`): evict oldest *other* non-pinned.
    public static func planUnfavorite(_ id: UUID, existing: [RetentionCandidate], maxCount: Int) -> [UUID] {
        let free = existing.filter { !$0.isPinned }
        let excess = max(0, free.count - maxCount)
        return oldestFirst(free.filter { $0.id != id }).prefix(excess).map(\.id)
    }

    public static func planAge(existing: [RetentionCandidate], now: Date, maxAge: TimeInterval) -> [UUID] {
        let cutoff = now.addingTimeInterval(-maxAge)
        return oldestFirst(existing.filter { !$0.isPinned && $0.lastCopiedAt < cutoff }).map(\.id)
    }

    /// Short per-app retention (§5.1, §6).
    public static func planExpired(existing: [RetentionCandidate], now: Date) -> [UUID] {
        oldestFirst(existing.filter { !$0.isPinned && ($0.expiresAt.map { $0 <= now } ?? false) }).map(\.id)
    }

    /// When the expiry timer should fire next.
    public static func nextExpiry(existing: [RetentionCandidate]) -> Date? {
        existing.filter { !$0.isPinned }.compactMap(\.expiresAt).min()
    }

    /// Freshest stack activity: Choose (`lastUsedAt`) or any member capture (`lastCopiedAt`).
    public static func stackFreshAt(lastUsedAt: Date, memberLastCopiedAt: [Date]) -> Date {
        ([lastUsedAt] + memberLastCopiedAt).max() ?? lastUsedAt
    }

    private static func oldestFirst(_ candidates: [RetentionCandidate]) -> [RetentionCandidate] {
        candidates.sorted {
            $0.lastCopiedAt != $1.lastCopiedAt ? $0.lastCopiedAt < $1.lastCopiedAt : $0.id.uuidString < $1.id.uuidString
        }
    }
}
