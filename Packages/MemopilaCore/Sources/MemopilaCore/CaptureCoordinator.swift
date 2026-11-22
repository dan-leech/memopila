import Foundation

public enum IdleReason: Sendable, Equatable {
    case accessNotAllowed
    case paused
    case unchanged
    case busy
}

public enum SkipConsumeReason: Sendable, Equatable {
    case skipArmed
    case confidentialStable
}

public enum SkipTickResult: Sendable, Equatable {
    case keepArmed(TypesPeek)
    case consume(changeCount: Int, reason: SkipConsumeReason)
}

public enum TickPhaseA: Sendable, Equatable {
    case idle(IdleReason)
    case suppressedOwnWrite(Int)
    /// Timed pause ended — Monitor peeks then ResumePolicy; Core does not markHandled here.
    case pauseEnded(changeCount: Int)
    case needsPeek(changeCount: Int)
}

public enum ApplyPeekResult: Sendable, Equatable {
    case skip(SkipTickResult)
    case empty(EmptyDisposition)
    case ephemeralLeaveOpen
    case peekFailedLeaveOpen
    case confidentialProgress(hits: Int)
    case confidentialStable(Int, PasteboardType)
    case startReader(readerSeq: Int)
}

/// The monitor's capture state machine (PLAN §3.2 "Capture coordination", §3.4 token, §3.7 pause/skip).
/// Pure value type; Phase A (`tick`) and Phase B (`applyPeek`) are peek-free.
public struct CaptureCoordinator: Sendable, Equatable {
    public private(set) var lastHandledChangeCount: Int?
    public private(set) var flight: CaptureFlight = .idle
    /// Store mutation serialisation (Clear / Delete / Edit). Independent of pasteboard `flight`.
    public private(set) var destructiveInProgress = false
    public private(set) var opSeq = 0
    public private(set) var token: Int?
    public private(set) var skipArmed = false
    public private(set) var pausedUntil: Date?
    public private(set) var pausedIndefinitely = false
    public private(set) var consecutiveSaveFailures = 0
    public private(set) var openGeneration = OpenGeneration()

    public static let saveFailuresBeforePause = 3

    public init(pausedUntil: Date? = nil, pausedIndefinitely: Bool = false) {
        self.pausedUntil = pausedUntil
        self.pausedIndefinitely = pausedIndefinitely
    }

    public var isPaused: Bool { pausedIndefinitely || pausedUntil != nil }

    public var isBusy: Bool { !flight.isIdle || destructiveInProgress }

    /// Compatibility for diagnostics that still ask "is a reader running?".
    public var isCapturing: Bool {
        switch flight {
        case .reading, .ingesting: true
        case .idle, .leased: false
        }
    }

    // MARK: Phase A

    /// Tick order (§3.2 rule 1): access → pause → unchanged → token → flight busy → needsPeek.
    public mutating func tick(accessAllowed: Bool, now: Date, changeCount readChangeCount: () -> Int) -> TickPhaseA {
        guard accessAllowed else { return .idle(.accessNotAllowed) }
        if pausedIndefinitely { return .idle(.paused) }
        if let pausedUntil {
            guard now >= pausedUntil else { return .idle(.paused) }
            let count = readChangeCount()
            endPause()
            return .pauseEnded(changeCount: count)
        }

        let count = readChangeCount()
        if let lastHandledChangeCount, count == lastHandledChangeCount { return .idle(.unchanged) }

        if let token {
            self.token = nil
            if count == token {
                markHandled(count)
                openGeneration.reset()
                return .suppressedOwnWrite(count)
            }
        }

        guard flight.isIdle else { return .idle(.busy) }
        guard !destructiveInProgress else { return .idle(.busy) }
        return .needsPeek(changeCount: count)
    }

    // MARK: Phase B

    public mutating func applyPeek(_ peek: TypesPeek, changeCount: Int) -> ApplyPeekResult {
        if skipArmed {
            return .skip(applySkipPeek(peek, changeCount: changeCount))
        }
        switch peek {
        case .empty:
            return .empty(openGeneration.noteEmpty(changeCount))
        case .ephemeralPrivacy:
            openGeneration.reset()
            return .ephemeralLeaveOpen
        case .peekFailed:
            return .peekFailedLeaveOpen
        case .confidential(let type):
            switch openGeneration.noteConfidential(changeCount, type: type) {
            case .progress(let hits):
                return .confidentialProgress(hits: hits)
            case .stable(let stableType):
                markHandled(changeCount)
                openGeneration.reset()
                return .confidentialStable(changeCount, stableType)
            }
        case .hasContent:
            openGeneration.reset()
            flight = .reading(readerSeq: opSeq)
            return .startReader(readerSeq: opSeq)
        }
    }

    private mutating func applySkipPeek(_ peek: TypesPeek, changeCount: Int) -> SkipTickResult {
        switch peek {
        case .empty, .ephemeralPrivacy, .peekFailed:
            return .keepArmed(peek)
        case .hasContent:
            skipArmed = false
            markHandled(changeCount)
            openGeneration.reset()
            return .consume(changeCount: changeCount, reason: .skipArmed)
        case .confidential(let type):
            switch openGeneration.noteConfidential(changeCount, type: type) {
            case .progress:
                return .keepArmed(peek)
            case .stable:
                skipArmed = false
                markHandled(changeCount)
                openGeneration.reset()
                return .consume(changeCount: changeCount, reason: .confidentialStable)
            }
        }
    }

    // MARK: Flight lifecycle

    /// Take the reading flight without a peek (Save anyway of an already-handled change).
    public mutating func beginReading() -> Int? {
        guard case .idle = flight else { return nil }
        flight = .reading(readerSeq: opSeq)
        return opSeq
    }

    public mutating func beginIngest(changeCount: Int) {
        flight = .ingesting(changeCount: changeCount)
    }

    /// Reader and store finished (§3.2 rule 2). `handledChangeCount` is `nil` when the outcome
    /// must not mark the change handled (unstable read, leaveOpen).
    public mutating func captureFinished(handledChangeCount: Int?) {
        flight = .idle
        if let handledChangeCount {
            markHandled(handledChangeCount)
            openGeneration.reset()
        }
    }

    /// Await reading|ingesting, then CAS `idle → leased`. Returns nil if CAS fails.
    public mutating func beginLease(kind: PasteboardLeaseKind) -> PasteboardLease? {
        guard case .idle = flight else { return nil }
        opSeq += 1
        let lease = PasteboardLease(kind: kind, opSeq: opSeq)
        flight = .leased(lease)
        return lease
    }

    public mutating func endLease(_ lease: PasteboardLease) {
        guard case .leased(let current) = flight, current == lease else { return }
        flight = .idle
    }

    // MARK: Save failures (§3.2 rule 3)

    public mutating func recordSaveSuccess() { consecutiveSaveFailures = 0 }

    /// Returns `true` when capture should pause with a storage error.
    public mutating func recordSaveFailure() -> Bool {
        consecutiveSaveFailures += 1
        return consecutiveSaveFailures >= Self.saveFailuresBeforePause
    }

    // MARK: Restore token (§3.4)

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

    /// Clears pause flags only. Peek + ResumePolicy decide markHandled vs leaveOpen.
    public mutating func endPause() {
        pausedUntil = nil
        pausedIndefinitely = false
        token = nil
    }

    public mutating func markHandled(_ count: Int) {
        lastHandledChangeCount = max(lastHandledChangeCount ?? count, count)
        openGeneration.reset()
    }

    public mutating func armSkip() { skipArmed = true }

    public mutating func cancelSkip() {
        skipArmed = false
        openGeneration.reset()
    }

    // MARK: Clear / Delete / Edit (§3.2 rule 5)

    /// `nil` = busy (another destructive operation is running). Otherwise the operation's `opSeq`.
    public mutating func beginDestructive() -> Int? {
        guard !destructiveInProgress else { return nil }
        destructiveInProgress = true
        opSeq += 1
        return opSeq
    }

    public mutating func endDestructive() { destructiveInProgress = false }
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
