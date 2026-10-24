import Foundation

/// The monitor's capture state machine (PLAN §3.2 "Capture coordination", §3.4 token, §3.7 pause/skip).
/// Pure value type; the app owns one instance on the main actor and calls it synchronously,
/// so every decision up to starting a reader happens without an `await`.
public struct CaptureCoordinator: Sendable, Equatable {
    public enum IdleReason: Sendable, Equatable {
        case accessNotAllowed
        case paused
        case unchanged
        case busy
    }

    public enum TickDecision: Sendable, Equatable {
        case idle(IdleReason)
        /// Our own confirmed write: handled once, no reader.
        case suppressedOwnWrite(changeCount: Int)
        /// Skip next copy consumed this change without any read.
        case skipped(changeCount: Int)
        /// A timed pause ended; the current count was marked handled.
        case resumed(changeCount: Int)
        case startReader(readerSeq: Int)
    }

    public private(set) var lastHandledChangeCount: Int?
    public private(set) var isCapturing = false
    public private(set) var destructiveInProgress = false
    public private(set) var opSeq = 0
    public private(set) var token: Int?
    public private(set) var skipArmed = false
    public private(set) var pausedUntil: Date?
    public private(set) var pausedIndefinitely = false
    public private(set) var consecutiveSaveFailures = 0

    public static let saveFailuresBeforePause = 3

    public init(pausedUntil: Date? = nil, pausedIndefinitely: Bool = false) {
        self.pausedUntil = pausedUntil
        self.pausedIndefinitely = pausedIndefinitely
    }

    public var isPaused: Bool { pausedIndefinitely || pausedUntil != nil }

    // MARK: Tick

    /// Tick order (§3.2 rule 1): access → pause → unchanged → token → single flight → skip → reader.
    public mutating func tick(accessAllowed: Bool, now: Date, changeCount readChangeCount: () -> Int) -> TickDecision {
        guard accessAllowed else { return .idle(.accessNotAllowed) }
        if pausedIndefinitely { return .idle(.paused) }
        if let pausedUntil {
            guard now >= pausedUntil else { return .idle(.paused) }
            let count = readChangeCount()
            resume(currentChangeCount: count)
            return .resumed(changeCount: count)
        }

        let count = readChangeCount()
        if let lastHandledChangeCount, count == lastHandledChangeCount { return .idle(.unchanged) }

        if let token {
            self.token = nil
            if count == token {
                markHandled(count)
                return .suppressedOwnWrite(changeCount: count)
            }
        }
        // A change already being read is not the next copy: *Skip Next Copy* waits for the one
        // after it (review finding: a slow read used the skip up and the password was saved).
        guard !isCapturing else { return .idle(.busy) }
        if skipArmed {
            skipArmed = false
            markHandled(count)
            return .skipped(changeCount: count)
        }
        guard !destructiveInProgress else { return .idle(.busy) }
        isCapturing = true
        return .startReader(readerSeq: opSeq)
    }

    /// Reader and store finished (§3.2 rule 2). `handledChangeCount` is `nil` when the outcome
    /// must not mark the change handled (unstable read, failed post-read gate).
    public mutating func captureFinished(handledChangeCount: Int?) {
        isCapturing = false
        if let handledChangeCount { markHandled(handledChangeCount) }
    }

    // MARK: Save failures (§3.2 rule 3)

    public mutating func recordSaveSuccess() { consecutiveSaveFailures = 0 }

    /// Returns `true` when capture should pause with a storage error.
    public mutating func recordSaveFailure() -> Bool {
        consecutiveSaveFailures += 1
        return consecutiveSaveFailures >= Self.saveFailuresBeforePause
    }

    // MARK: Restore token (§3.4)

    /// Publish only a confirmed `ownedCount`.
    public mutating func publishToken(_ ownedCount: Int) { token = ownedCount }

    // MARK: Pause and skip (§3.7)

    public mutating func pause(until date: Date) {
        pausedUntil = date
        pausedIndefinitely = false
    }

    public mutating func pauseIndefinitely() {
        pausedUntil = nil
        pausedIndefinitely = true
    }

    /// Content copied during the pause is never captured: the current count becomes handled.
    public mutating func resume(currentChangeCount: Int) {
        pausedUntil = nil
        pausedIndefinitely = false
        token = nil
        markHandled(currentChangeCount)
    }

    public mutating func armSkip() { skipArmed = true }
    public mutating func cancelSkip() { skipArmed = false }

    // MARK: Clear / Delete / Edit (§3.2 rule 5)

    /// `nil` = busy (another destructive operation is running). Otherwise the operation's `opSeq`.
    public mutating func beginDestructive() -> Int? {
        guard !destructiveInProgress else { return nil }
        destructiveInProgress = true
        opSeq += 1
        return opSeq
    }

    public mutating func endDestructive() { destructiveInProgress = false }

    /// `changeCount` only grows, so the handled mark never moves backwards (a late reader of an
    /// older count must not re-open a newer handled count).
    private mutating func markHandled(_ count: Int) {
        lastHandledChangeCount = max(lastHandledChangeCount ?? count, count)
    }
}

/// Store-side protection against resurrecting cleared, deleted or pre-edit content (PLAN §3.2 rule 5).
/// Checked inside the same serialized mutation as the commit.
public struct IngestStaleGuard: Sendable, Equatable {
    public static let tombstoneLimit = 64

    public private(set) var lastClearSeq = 0
    private var tombstones: [Tombstone] = []

    private struct Tombstone: Sendable, Equatable {
        let contentHash: String
        let opSeq: Int
    }

    public init() {}

    public mutating func recordClear(opSeq: Int) {
        lastClearSeq = max(lastClearSeq, opSeq)
    }

    /// Delete and Edit record the hash of the content they removed.
    public mutating func recordTombstone(contentHash: String, opSeq: Int) {
        tombstones.append(Tombstone(contentHash: contentHash, opSeq: opSeq))
        if tombstones.count > Self.tombstoneLimit { tombstones.removeFirst(tombstones.count - Self.tombstoneLimit) }
    }

    /// A snapshot read before a Clear, or before a Delete/Edit of the same content, is stale.
    public func isStale(contentHash: String, readerSeq: Int) -> Bool {
        if readerSeq < lastClearSeq { return true }
        return tombstones.contains { $0.contentHash == contentHash && $0.opSeq > readerSeq }
    }
}
