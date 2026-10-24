import Foundation
import Testing
@testable import MemopilaCore

private func candidate(_ n: Int, favorite: Bool = false, bytes: Int = 10, expiresAt: Date? = nil) -> RetentionCandidate {
    RetentionCandidate(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", n))!,
        isFavorite: favorite,
        lastCopiedAt: Date(timeIntervalSince1970: TimeInterval(n)),
        payloadSizeBytes: bytes,
        expiresAt: expiresAt
    )
}

@Suite("Retention planner (§6)")
struct RetentionTests {
    @Test func countCapEvictsOldestNonFavorites() {
        let existing = [candidate(1), candidate(2, favorite: true), candidate(3), candidate(4)]
        #expect(RetentionPlanner.planIngest(existing: existing, newPayloadBytes: 1, maxCount: 2, maxStorageBytes: 1_000)
            == .accept(victims: [candidate(1).id, candidate(3).id]))
    }

    @Test func favoritesNeverCountTowardMaxCount() {
        let favorites = (1...500).map { candidate($0, favorite: true, bytes: 0) }
        #expect(RetentionPlanner.planIngest(existing: favorites, newPayloadBytes: 1, maxCount: 1, maxStorageBytes: 1_000) == .accept(victims: []))
    }

    @Test func storageQuotaAddsOldestVictimsBeyondTheCountCap() {
        let existing = [candidate(1, bytes: 40), candidate(2, bytes: 40), candidate(3, bytes: 40)]
        #expect(RetentionPlanner.planIngest(existing: existing, newPayloadBytes: 50, maxCount: 10, maxStorageBytes: 100)
            == .accept(victims: [candidate(1).id, candidate(2).id]))
    }

    @Test func rejectsWhenOnlyFavoritesWouldHaveToGo() {
        let existing = [candidate(1, favorite: true, bytes: 90), candidate(2, bytes: 5)]
        #expect(RetentionPlanner.planIngest(existing: existing, newPayloadBytes: 20, maxCount: 10, maxStorageBytes: 100) == .rejectQuota)
    }

    @Test func countShrink() {
        let existing = [candidate(1), candidate(2, favorite: true), candidate(3), candidate(4)]
        #expect(RetentionPlanner.planCountShrink(existing: existing, maxCount: 1) == [candidate(1).id, candidate(3).id])
    }

    @Test func storageShrinkDeletesOldestNonFavoritesUntilItFits() {
        let existing = [candidate(1, bytes: 40), candidate(2, favorite: true, bytes: 40), candidate(3, bytes: 40), candidate(4, bytes: 40)]
        #expect(RetentionPlanner.planStorageShrink(existing: existing, maxStorageBytes: 100) == [candidate(1).id, candidate(3).id])
        #expect(RetentionPlanner.planStorageShrink(existing: existing, maxStorageBytes: 200).isEmpty)
        #expect(RetentionPlanner.planStorageShrink(existing: existing, maxStorageBytes: 50) == [candidate(1).id, candidate(3).id, candidate(4).id])
        #expect(RetentionPlanner.planStorageShrink(existing: existing, maxStorageBytes: 10).isEmpty, "favorites alone are over: nothing goes")
    }

    @Test func unfavoriteKeepsTheUnfavoritedRecord() {
        // Record 1 was just unfavorited: oldest, but it must survive.
        let existing = [candidate(1), candidate(2), candidate(3)]
        #expect(RetentionPlanner.planUnfavorite(candidate(1).id, existing: existing, maxCount: 2) == [candidate(2).id])
    }

    @Test func ageAndExpiry() {
        let now = Date(timeIntervalSince1970: 100)
        let existing = [
            candidate(1), candidate(2, favorite: true), candidate(95),
            candidate(96, expiresAt: Date(timeIntervalSince1970: 99)),
            candidate(97, favorite: true, expiresAt: Date(timeIntervalSince1970: 99)),
            candidate(98, expiresAt: Date(timeIntervalSince1970: 150)),
        ]
        #expect(RetentionPlanner.planAge(existing: existing, now: now, maxAge: 10) == [candidate(1).id])
        #expect(RetentionPlanner.planExpired(existing: existing, now: now) == [candidate(96).id])
        #expect(RetentionPlanner.nextExpiry(existing: existing) == Date(timeIntervalSince1970: 99))
    }
}

@Suite("Dedup metadata merge (§4)")
struct DedupMergeTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func newRecordUsesObservedAt() {
        let record = DedupMerge.newRecord(from: CaptureObservation(observedAt: t0, sourceAppBundleID: "com.a.b", retentionMinutes: 60))
        #expect(record.firstCopiedAt == t0 && record.lastCopiedAt == t0 && record.copyCount == 1)
        #expect(record.expiresAt == t0.addingTimeInterval(3_600))
    }

    @Test func newerObservationUpdatesAttribution() {
        let existing = RecordMetadata(firstCopiedAt: t0, lastCopiedAt: t0, copyCount: 1, lastSourceAppBundleID: "com.a.b", sourceURL: "https://a.example")
        let merged = DedupMerge.merge(existing, with: CaptureObservation(observedAt: t0 + 10, sourceAppBundleID: "com.c.d"))
        #expect(merged.lastCopiedAt == t0 + 10)
        #expect(merged.copyCount == 2)
        #expect(merged.lastSourceAppBundleID == "com.c.d")
        #expect(merged.sourceURL == nil)
    }

    @Test func lateRetryOfOlderObservationDoesNotRollBack() {
        let existing = RecordMetadata(firstCopiedAt: t0, lastCopiedAt: t0 + 100, copyCount: 3, lastSourceAppBundleID: "com.new.app")
        let merged = DedupMerge.merge(existing, with: CaptureObservation(observedAt: t0 - 5, sourceAppBundleID: "com.old.app", retentionMinutes: 1))
        #expect(merged.firstCopiedAt == t0 - 5)
        #expect(merged.lastCopiedAt == t0 + 100)
        #expect(merged.copyCount == 4)
        #expect(merged.lastSourceAppBundleID == "com.new.app")
        #expect(merged.expiresAt == nil)
    }

    @Test func unknownObservationKeepsAKnownSourceAndExpiry() {
        let existing = RecordMetadata(firstCopiedAt: t0, lastCopiedAt: t0, copyCount: 1, lastSourceAppBundleID: "com.a.b", expiresAt: t0 + 900)
        let merged = DedupMerge.merge(existing, with: CaptureObservation(observedAt: t0 + 10, sourceAppBundleID: nil))
        #expect(merged.lastCopiedAt == t0 + 10 && merged.copyCount == 2)
        #expect(merged.lastSourceAppBundleID == "com.a.b")
        #expect(merged.expiresAt == t0 + 900)
    }

    @Test func favoritesNeverGetAnExpiry() {
        let existing = RecordMetadata(firstCopiedAt: t0, lastCopiedAt: t0, copyCount: 1, isFavorite: true)
        #expect(DedupMerge.merge(existing, with: CaptureObservation(observedAt: t0 + 1, retentionMinutes: 15)).expiresAt == nil)
    }

    @Test func editCollisionMerge() {
        let edited = RecordMetadata(firstCopiedAt: t0 - 50, lastCopiedAt: t0 + 5, copyCount: 2, isFavorite: true)
        let survivor = RecordMetadata(firstCopiedAt: t0, lastCopiedAt: t0, copyCount: 3, expiresAt: t0 + 60)
        let merged = DedupMerge.mergeEdited(edited, into: survivor)
        #expect(merged.firstCopiedAt == t0 - 50 && merged.lastCopiedAt == t0 + 5)
        #expect(merged.copyCount == 5 && merged.isFavorite && merged.expiresAt == nil)
    }
}

@Suite("Payload integrity before Restore (§3.5)")
struct PayloadIntegrityTests {
    let items = [
        CanonicalItem([.bytes(.utf8PlainText, utf8("a")), .bytes(.html, utf8("<b>a</b>"))]),
        CanonicalItem([.files(.fileURL, ["/tmp/x"])]),
    ]

    func verify(_ rows: [StoredRepresentation], size: Int? = nil, hash: String? = nil, scheme: Int = 1, format: Int = 1) throws(IntegrityError) -> [CanonicalItem] {
        try PayloadIntegrity.verify(
            rows: rows,
            payloadSizeBytes: size ?? MCS1.payloadSize(of: items),
            contentHash: hash ?? MCS1.contentHash(of: items),
            hashSchemeVersion: scheme,
            storageFormatVersion: format
        )
    }

    @Test func validRowsRoundTripInAnyLoadOrder() throws {
        let rows = StoredRepresentation.rows(for: items)
        #expect(try verify(rows.reversed()) == items)
    }

    @Test func rejections() {
        let rows = StoredRepresentation.rows(for: items)
        #expect(throws: IntegrityError.unsupportedHashScheme(2)) { try verify(rows, scheme: 2) }
        #expect(throws: IntegrityError.unsupportedStorageFormat(2)) { try verify(rows, format: 2) }
        #expect(throws: IntegrityError.empty) { try verify([]) }
        #expect(throws: IntegrityError.nonContiguousRows) { try verify(Array(rows.dropFirst())) }
        #expect(throws: IntegrityError.payloadSizeMismatch(expected: 1, actual: MCS1.payloadSize(of: items))) { try verify(rows, size: 1) }
        #expect(throws: IntegrityError.hashMismatch) { try verify(rows, hash: String(repeating: "0", count: 64)) }

        var wrongCount = rows
        wrongCount[0].byteCount = 99
        #expect(throws: IntegrityError.byteCountMismatch(itemIndex: 0, repIndex: 0)) { try verify(wrongCount) }

        var badPath = rows
        badPath[2].payload = .filePaths([""])
        badPath[2].byteCount = 0
        #expect(throws: IntegrityError.invalidPath(itemIndex: 1, repIndex: 0)) { try verify(badPath) }
    }
}

/// Reference wrapper so `#expect` only sees non-mutating calls.
private final class CoordinatorHarness {
    var coordinator = CaptureCoordinator()
    let start = Date(timeIntervalSince1970: 1_000)

    func tick(_ count: Int, after seconds: TimeInterval = 0, access: Bool = true) -> CaptureCoordinator.TickDecision {
        coordinator.tick(accessAllowed: access, now: start + seconds) { count }
    }

    func finish(_ count: Int?) { coordinator.captureFinished(handledChangeCount: count) }
    func saveFailed() -> Bool { coordinator.recordSaveFailure() }
    func beginDestructive() -> Int? { coordinator.beginDestructive() }
}

@Suite("Capture coordination (§3.2, §3.4, §3.7)")
struct CaptureCoordinatorTests {
    @Test func unchangedTicksDoNotRead() {
        let h = CoordinatorHarness()
        #expect(h.tick(5) == .startReader(readerSeq: 0))
        h.finish(5)
        for _ in 0..<10 {
            #expect(h.tick(5) == .idle(.unchanged))
        }
    }

    @Test func singleFlight() {
        let h = CoordinatorHarness()
        #expect(h.tick(1) == .startReader(readerSeq: 0))
        #expect(h.tick(2) == .idle(.busy))
        h.finish(1)
        #expect(h.tick(2) == .startReader(readerSeq: 0))
    }

    @Test func unstableReadLeavesTheCountEligible() {
        let h = CoordinatorHarness()
        _ = h.tick(1)
        h.finish(nil)
        #expect(h.tick(1) == .startReader(readerSeq: 0))
    }

    @Test func noAccessMeansNoCounterRead() {
        var coordinator = CaptureCoordinator()
        var reads = 0
        let decision = coordinator.tick(accessAllowed: false, now: Date()) { reads += 1; return 1 }
        #expect(decision == .idle(.accessNotAllowed))
        #expect(reads == 0)
    }

    @Test func confirmedRestoreIsSuppressedOnce() {
        let h = CoordinatorHarness()
        h.coordinator.publishToken(9)
        #expect(h.tick(9) == .suppressedOwnWrite(changeCount: 9))
        #expect(h.tick(9) == .idle(.unchanged))
        #expect(h.tick(10) == .startReader(readerSeq: 0))
    }

    @Test func wrongTokenNeverSuppressesAnExternalChange() {
        let h = CoordinatorHarness()
        h.coordinator.publishToken(9)
        #expect(h.tick(10) == .startReader(readerSeq: 0))
        #expect(h.coordinator.token == nil)
    }

    @Test func lateReaderDoesNotReopenANewerHandledCount() {
        let h = CoordinatorHarness()
        _ = h.tick(1)
        h.coordinator.publishToken(2)
        #expect(h.tick(2) == .suppressedOwnWrite(changeCount: 2))
        h.finish(1)
        #expect(h.coordinator.lastHandledChangeCount == 2)
        #expect(h.tick(2) == .idle(.unchanged))
    }

    @Test func skipNextCopySkipsExactlyOneExternalChange() {
        let h = CoordinatorHarness()
        h.coordinator.armSkip()
        #expect(h.tick(3) == .skipped(changeCount: 3))
        #expect(h.tick(4) == .startReader(readerSeq: 0))
    }

    @Test func skipWaitsForTheChangeAlreadyBeingRead() {
        let h = CoordinatorHarness()
        #expect(h.tick(3) == .startReader(readerSeq: 0))
        h.coordinator.armSkip()
        #expect(h.tick(4) == .idle(.busy))
        h.finish(3)
        #expect(h.tick(4) == .skipped(changeCount: 4))
    }

    @Test func restoreWhileSkipIsArmedLeavesSkipArmed() {
        let h = CoordinatorHarness()
        h.coordinator.armSkip()
        h.coordinator.publishToken(3)
        #expect(h.tick(3) == .suppressedOwnWrite(changeCount: 3))
        #expect(h.coordinator.skipArmed)
        #expect(h.tick(4) == .skipped(changeCount: 4))
    }

    @Test func copiesDuringATimedPauseAreNeverCaptured() {
        let h = CoordinatorHarness()
        h.coordinator.pause(until: h.start + 60)
        #expect(h.tick(7) == .idle(.paused))
        #expect(h.tick(8, after: 61) == .resumed(changeCount: 8))
        #expect(h.tick(8, after: 62) == .idle(.unchanged))
        #expect(h.tick(9, after: 63) == .startReader(readerSeq: 0))
    }

    @Test func indefinitePauseAndManualResume() {
        let h = CoordinatorHarness()
        h.coordinator.pauseIndefinitely()
        #expect(h.tick(7, after: 10_000) == .idle(.paused))
        h.coordinator.resume(currentChangeCount: 7)
        #expect(h.tick(7) == .idle(.unchanged))
    }

    @Test func destructiveOperationsAreSerializedAndBlockNewReaders() {
        let h = CoordinatorHarness()
        #expect(h.beginDestructive() == 1)
        #expect(h.beginDestructive() == nil, "second Clear/Delete is busy")
        #expect(h.tick(1) == .idle(.busy))
        h.coordinator.endDestructive()
        #expect(h.tick(1) == .startReader(readerSeq: 1))
    }

    @Test func threeConsecutiveSaveFailuresPause() {
        let h = CoordinatorHarness()
        #expect(!h.saveFailed())
        #expect(!h.saveFailed())
        h.coordinator.recordSaveSuccess()
        #expect(!h.saveFailed())
        #expect(!h.saveFailed())
        #expect(h.saveFailed())
    }
}

@Suite("Ingest stale guard (§3.2 rule 5)")
struct IngestStaleGuardTests {
    @Test func readerStartedBeforeClearIsStale() {
        var guardState = IngestStaleGuard()
        guardState.recordClear(opSeq: 1)
        #expect(guardState.isStale(contentHash: "a", readerSeq: 0))
        #expect(!guardState.isStale(contentHash: "a", readerSeq: 1))
    }

    @Test func deleteOnlyDropsTheSameContent() {
        var guardState = IngestStaleGuard()
        guardState.recordTombstone(contentHash: "deleted", opSeq: 1)
        #expect(guardState.isStale(contentHash: "deleted", readerSeq: 0))
        #expect(!guardState.isStale(contentHash: "unrelated", readerSeq: 0))
        #expect(!guardState.isStale(contentHash: "deleted", readerSeq: 1), "copied again after the delete")
    }

    @Test func tombstonesAreBounded() {
        var guardState = IngestStaleGuard()
        for seq in 1...(IngestStaleGuard.tombstoneLimit + 1) {
            guardState.recordTombstone(contentHash: "h\(seq)", opSeq: seq)
        }
        #expect(!guardState.isStale(contentHash: "h1", readerSeq: 0))
        #expect(guardState.isStale(contentHash: "h2", readerSeq: 0))
    }
}
