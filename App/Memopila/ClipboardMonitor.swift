import AppKit
import MemopilaCore
import Observation
import os

/// Polls the pasteboard and turns stable changes into history entries (PLAN §3.1, §3.2, §3.7).
///
/// Phase 1 shell: history lives in memory and is bounded (`HistoryLimits`); the SwiftData store
/// replaces it in Phase 2.
@MainActor
@Observable
final class ClipboardMonitor {
    private(set) var history: [HistoryEntry] = []
    private(set) var current: CurrentClipboard?
    private(set) var access: PasteboardAccess.State = .needsEnable
    private(set) var coordinator: CaptureCoordinator
    private(set) var log: [DiagnosticsEvent] = []
    private(set) var storageError: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.dan-leech.Memopila", category: "capture")

    init() {
        coordinator = CaptureCoordinator(
            pausedUntil: Preferences.pausedUntil,
            pausedIndefinitely: Preferences.pausedIndefinitely
        )
    }

    var isPaused: Bool { coordinator.isPaused }
    var pausedUntil: Date? { coordinator.pausedUntil }
    var skipArmed: Bool { coordinator.skipArmed }

    var statusSymbol: String {
        if !access.allowsCapture || storageError != nil { return "exclamationmark.triangle" }
        if isPaused { return "pause.circle" }
        if skipArmed { return "forward.end.circle" }
        return "list.clipboard"
    }

    func start() {
        refreshAccess()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
    }

    // MARK: Access (§3.1)

    func refreshAccess() {
        let state = PasteboardAccess.currentState()
        if state != access {
            record("access → \(state) (behavior \(PasteboardAccess.behaviorName))")
            access = state
        }
    }

    /// Enable capture: one discarded content read from a user action.
    func enableCapture() -> Bool {
        let before = PasteboardAccess.behaviorName
        let didRead = PasteboardAccess.bootstrapRead()
        refreshAccess()
        record("bootstrap read: \(didRead ? "read" : "pasteboard empty"); behavior \(before) → \(PasteboardAccess.behaviorName)")
        return didRead
    }

    // MARK: Tick (§3.2 rule 1)

    private func tick() {
        refreshAccess()
        let decision = coordinator.tick(accessAllowed: access.allowsCapture, now: Date()) {
            NSPasteboard.general.changeCount
        }
        switch decision {
        case .startReader(let readerSeq):
            startReader(readerSeq: readerSeq)
        case .resumed(let changeCount):
            persistPause()
            record("pause ended; change \(changeCount) skipped")
        case .skipped(let changeCount):
            current = nil
            record("skip next copy: change \(changeCount) skipped without reading")
        case .suppressedOwnWrite(let changeCount):
            record("own write \(changeCount) suppressed")
        case .idle:
            break
        }
    }

    private func startReader(readerSeq: Int) {
        let reader = SnapshotReader(context: captureContext())
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = reader.read(GeneralPasteboardSource())
            await self?.finishCapture(outcome)
        }
    }

    private func captureContext(saveAnyway: Bool = false) -> CaptureContext {
        CaptureContext(
            formatPolicy: FormatPolicy(defaultMaxBytes: Preferences.maxSinglePayloadMiB * FormatPolicy.mebibyte),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            panelIsKey: NSApp.keyWindow is HistoryPanel,
            ownBundleID: Bundle.main.bundleIdentifier ?? "io.github.dan-leech.Memopila",
            saveAnyway: saveAnyway
        )
    }

    private func finishCapture(_ outcome: SnapshotReadOutcome) {
        refreshAccess()
        guard access.allowsCapture else {
            // Post-read gate (§3.1): discard, keep the change eligible.
            coordinator.captureFinished(handledChangeCount: nil)
            record("post-read gate: access gone, result discarded")
            return
        }
        apply(outcome)
        coordinator.captureFinished(handledChangeCount: outcome.marksHandled ? outcome.changeCount : nil)
    }

    private func apply(_ outcome: SnapshotReadOutcome) {
        switch outcome {
        case .unstable:
            record("unstable read discarded")
        case .skipped(let changeCount, let reason):
            current = nil
            record("change \(changeCount) skipped: \(reason)")
        case .notSaved(let changeCount, let reason, let change):
            current = CurrentClipboard(changeCount: changeCount, reason: reason, change: change)
            record("change \(changeCount) not saved: \(reason)")
        case .captured(let snapshot):
            ingest(snapshot)
            current = nil
            record("change \(snapshot.changeCount) captured: \(snapshot.displayType.rawValue), \(snapshot.payloadSizeBytes) bytes")
        }
    }

    /// In-memory stand-in for `ClipboardStore.ingest` (§4 merge rules, bounded memory).
    private func ingest(_ snapshot: OwnedSnapshot) {
        let observation = CaptureObservation(
            observedAt: snapshot.observedAt,
            sourceAppBundleID: snapshot.identity.bundleID,
            sourceURL: snapshot.sourceURL,
            retentionMinutes: snapshot.settings.retentionMinutes
        )
        if let index = history.firstIndex(where: { $0.snapshot.contentHash == snapshot.contentHash }) {
            var entry = history.remove(at: index)
            entry.metadata = DedupMerge.merge(entry.metadata, with: observation)
            history.insert(entry, at: 0)
        } else {
            history.insert(HistoryEntry(snapshot: snapshot, metadata: DedupMerge.newRecord(from: observation)), at: 0)
        }
        HistoryLimits.trim(&history)
    }

    // MARK: Restore (§3.4)

    @discardableResult
    func restore(_ entry: HistoryEntry, plainText: Bool = false) -> Bool {
        guard let items = plainText ? entry.plainTextItems : entry.snapshot.items else { return false }
        return write(items, for: entry)
    }

    /// *Copy As* text actions and recognized text: plain text only, not added to history (§3.4).
    @discardableResult
    func copy(text: String, from entry: HistoryEntry) -> Bool {
        write([CanonicalItem([.bytes(.utf8PlainText, Data(text.utf8))])], for: entry)
    }

    private func write(_ items: [CanonicalItem], for entry: HistoryEntry) -> Bool {
        switch PasteboardWriter.write(items, sourceBundleID: entry.metadata.lastSourceAppBundleID) {
        case .written(let ownedCount):
            coordinator.publishToken(ownedCount)
            if let index = history.firstIndex(where: { $0.id == entry.id }) {
                var moved = history.remove(at: index)
                moved.metadata.lastCopiedAt = max(moved.metadata.lastCopiedAt, Date())
                history.insert(moved, at: 0)
            }
            record("restored \(entry.snapshot.displayType.rawValue) as change \(ownedCount)")
            return true
        case .unconfirmed:
            record("restore written but not confirmed: no suppression token")
            return true
        case .aborted:
            record("restore aborted: another app changed the clipboard")
            return false
        case .failed:
            record("restore failed: writeObjects returned false")
            return false
        }
    }

    func delete(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
    }

    func clearHistory(includingFavorites: Bool) {
        history.removeAll { includingFavorites || !$0.metadata.isFavorite }
    }

    /// *Save anyway* for the red card (§3.2.3): one-shot read, only if the clipboard did not change.
    func saveCurrentAnyway() {
        guard let current, NSPasteboard.general.changeCount == current.changeCount else { return }
        let outcome = SnapshotReader(context: captureContext(saveAnyway: true)).read(GeneralPasteboardSource())
        apply(outcome)
    }

    func dismissCurrent() { current = nil }

    // MARK: Pause and skip (§3.7)

    func pause(minutes: Int) {
        coordinator.pause(until: Date().addingTimeInterval(TimeInterval(minutes) * 60))
        persistPause()
    }

    func pauseIndefinitely() {
        coordinator.pauseIndefinitely()
        persistPause()
    }

    func resume() {
        coordinator.resume(currentChangeCount: NSPasteboard.general.changeCount)
        persistPause()
    }

    func toggleSkip() {
        if coordinator.skipArmed { coordinator.cancelSkip() } else { coordinator.armSkip() }
    }

    private func persistPause() {
        Preferences.pausedUntil = coordinator.pausedUntil
        Preferences.pausedIndefinitely = coordinator.pausedIndefinitely
    }

    // MARK: Diagnostics

    func record(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        log.insert(DiagnosticsEvent(date: Date(), message: message), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}

struct DiagnosticsEvent: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

/// The latest stable change that was not saved (red card, §3.2.3). Never persisted.
struct CurrentClipboard: Equatable {
    let changeCount: Int
    let reason: NotSavedReason
    let change: UnsavedChange

    var title: String {
        switch reason {
        case .noSupportedFormats: "No supported formats"
        case .tooLarge(let limit): "Larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory))"
        case .readFailed(let type): "Read failed: \(type.rawValue)"
        }
    }
}

/// Phase 1 shell bounds for the in-memory history: at most 50 entries and 64 MiB of payload.
enum HistoryLimits {
    static let maxEntries = 50
    static let maxBytes = 64 * FormatPolicy.mebibyte

    static func trim(_ history: inout [HistoryEntry]) {
        while history.count > maxEntries || history.reduce(0, { $0 + $1.snapshot.payloadSizeBytes }) > maxBytes,
              let index = history.lastIndex(where: { !$0.metadata.isFavorite }) {
            history.remove(at: index)
        }
    }
}
