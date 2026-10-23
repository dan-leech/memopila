import AppKit
import MemopilaCore
import MemopilaServices
import Observation
import os

/// Polls the pasteboard and turns stable changes into history records (PLAN §3.1, §3.2, §3.7).
/// Owns the capture state machine, the red Current card, Restore writes and the busy state of
/// destructive operations. History itself lives in `ClipboardStore`; nothing here keeps payload bytes.
@MainActor
@Observable
final class ClipboardMonitor {
    private(set) var current: CurrentClipboard?
    private(set) var access: PasteboardAccess.State = .needsEnable
    private(set) var coordinator: CaptureCoordinator
    private(set) var log: [DiagnosticsEvent] = []
    /// *Capture paused: storage error* after 3 consecutive failed saves (§3.2 rule 3).
    private(set) var storageError: String?
    private(set) var isSavingAnyway = false
    /// Shown next to *Enable capture* when the clipboard was empty, so nothing could be read yet.
    private(set) var enableHint: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.dan-leech.Memopila", category: "capture")
    /// A record was committed or merged.
    @ObservationIgnored var onSaved: ((UUID) -> Void)?
    @ObservationIgnored var panelIsKey: () -> Bool = { false }
    @ObservationIgnored private let frontmostTracker = FrontmostTracker()
    /// What was on the clipboard at launch was copied by an unknown app (§3.2 rule 4).
    @ObservationIgnored private var launchChangeCount: Int?
    @ObservationIgnored private var previousTick = Date()

    static let ownBundleID = Bundle.main.bundleIdentifier ?? "io.github.dan-leech.Memopila"

    init(settings: SettingsStore, store: ClipboardStore) {
        self.settings = settings
        self.store = store
        coordinator = CaptureCoordinator(pausedUntil: settings.pausedUntil, pausedIndefinitely: settings.pausedIndefinitely)
    }

    var isPaused: Bool { coordinator.isPaused }
    var pausedUntil: Date? { coordinator.pausedUntil }
    var skipArmed: Bool { coordinator.skipArmed }
    var isBusy: Bool { coordinator.destructiveInProgress }
    var isCaptureBlocked: Bool { !access.allowsCapture || storageError != nil }

    var statusSymbol: String {
        if isCaptureBlocked { return "exclamationmark.triangle" }
        if isPaused { return "pause.circle" }
        if skipArmed { return "forward.end.circle" }
        return "list.clipboard"
    }

    func start() {
        launchChangeCount = NSPasteboard.general.changeCount
        refreshAccess()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Access (§3.1)

    func refreshAccess() {
        let state = PasteboardAccess.currentState(verifiedBuild: settings.silentDefaultVerifiedOSBuild)
        if state != access {
            record("access → \(state) (behavior \(PasteboardAccess.behaviorName))")
            access = state
        }
    }

    /// *Enable capture*: one discarded content read from a user action (§3.1 bootstrap).
    func enableCapture() {
        let before = PasteboardAccess.behaviorName
        let result = PasteboardAccess.bootstrapRead()
        if let build = result.verifiedBuild { settings.silentDefaultVerifiedOSBuild = build }
        refreshAccess()
        record("bootstrap read: \(result.didRead ? "read" : "pasteboard empty"); behavior \(before) → \(PasteboardAccess.behaviorName)")
        enableHint = result.didRead ? nil : String(localized: "The clipboard is empty. Copy something, then choose Enable Capture again.")
    }

    // MARK: Tick (§3.2 rule 1)

    private func tick() {
        refreshAccess()
        if let current, NSPasteboard.general.changeCount != current.changeCount {
            self.current = nil
        }
        // Tick a copy: writing back an unchanged coordinator would still notify every observer
        // four times a second (menu bar icon, banners) through the @Observable accessor.
        var next = coordinator
        let decision = next.tick(accessAllowed: !isCaptureBlocked, now: Date()) {
            NSPasteboard.general.changeCount
        }
        if next != coordinator { coordinator = next }
        let tickStart = previousTick
        previousTick = Date()
        switch decision {
        case .startReader(let readerSeq):
            startReader(readerSeq: readerSeq, saveAnyway: false, sourceSince: tickStart)
        case .resumed(let changeCount):
            persistPause()
            record("pause ended; change \(changeCount) skipped")
        case .skipped(let changeCount):
            record("skip next copy: change \(changeCount) skipped without reading")
        case .suppressedOwnWrite(let changeCount):
            record("own write \(changeCount) suppressed")
        case .idle:
            break
        }
    }

    /// - Parameter expectedChangeCount: *Save anyway* reads only the change its red card shows;
    ///   any other count is treated as unstable.
    private func startReader(readerSeq: Int, saveAnyway: Bool, expectedChangeCount: Int? = nil, sourceSince: Date? = nil) {
        let reader = SnapshotReader(context: captureContext(saveAnyway: saveAnyway, sourceSince: sourceSince))
        let frontmost = NSWorkspace.shared.frontmostApplication
        let titleSource = AccessibilityBridge.isTrusted ? frontmost.map { ($0.processIdentifier, $0.bundleIdentifier) } : nil
        Task.detached(priority: .userInitiated) { [weak self] in
            var outcome = reader.read(GeneralPasteboardSource())
            if let expectedChangeCount, outcome.changeCount != expectedChangeCount { outcome = .unstable }
            var enrichment: IngestEnrichment?
            if case .captured(let snapshot) = outcome {
                var title: String?
                if let titleSource, snapshot.settings.recordSourcePage, titleSource.1 == snapshot.identity.bundleID {
                    title = AccessibilityBridge.focusedWindowTitle(pid: titleSource.0)
                }
                enrichment = IngestEnrichment.make(for: snapshot.items, sourceAppName: nil, sourceWindowTitle: title)
            }
            await self?.finishRead(outcome, enrichment: enrichment, readerSeq: readerSeq, saveAnyway: saveAnyway)
        }
    }

    private func captureContext(saveAnyway: Bool, sourceSince: Date?) -> CaptureContext {
        var source = frontmostTracker.source(since: sourceSince ?? Date())
        if let launchChangeCount, NSPasteboard.general.changeCount == launchChangeCount {
            source = nil
        } else {
            launchChangeCount = nil
        }
        return CaptureContext(
            profiles: settings.profiles,
            formatPolicy: settings.formatPolicy,
            frontmostBundleID: source,
            panelIsKey: panelIsKey(),
            ownBundleID: Self.ownBundleID,
            ignoreRemoteClipboard: settings.ignoreRemoteClipboard,
            saveAnyway: saveAnyway,
            secretPolicy: settings.secretPolicy,
            secretKinds: settings.secretKinds
        )
    }

    /// Reader returned (§3.2 rule 2): post-read gate → store → outcome table → single flight ends.
    private func finishRead(_ outcome: SnapshotReadOutcome, enrichment: IngestEnrichment?, readerSeq: Int, saveAnyway: Bool) async {
        defer {
            if saveAnyway { isSavingAnyway = false }
        }
        refreshAccess()
        guard access.allowsCapture else {
            if !saveAnyway { coordinator.captureFinished(handledChangeCount: nil) }
            record("post-read gate: access gone, result discarded")
            return
        }
        switch outcome {
        case .unstable:
            record("unstable read discarded")
        case .skipped(let changeCount, let reason):
            record("change \(changeCount) skipped: \(reason)")
        case .notSaved(let changeCount, let reason, let change):
            current = CurrentClipboard(changeCount: changeCount, status: .notSaved(reason), change: change)
            record("change \(changeCount) not saved: \(reason)")
        case .captured(let snapshot):
            var enrichment = enrichment ?? IngestEnrichment()
            enrichment.sourceAppName = AppInfo.name(for: snapshot.identity.bundleID)
            await ingest(snapshot, enrichment: enrichment, readerSeq: readerSeq)
        }
        if !saveAnyway {
            coordinator.captureFinished(handledChangeCount: outcome.marksHandled ? outcome.changeCount : nil)
        }
    }

    private func ingest(_ snapshot: OwnedSnapshot, enrichment: IngestEnrichment, readerSeq: Int) async {
        let limits = settings.retentionLimits
        var result = await store.ingest(snapshot, readerSeq: readerSeq, enrichment: enrichment, limits: limits)
        if case .failed = result {
            record("change \(snapshot.changeCount): save failed, retrying once")
            try? await Task.sleep(for: .seconds(1))
            result = await store.ingest(snapshot, readerSeq: readerSeq, enrichment: enrichment, limits: limits)
        }
        let change = UnsavedChange(
            identity: snapshot.identity,
            declaredTypes: snapshot.items.flatMap(\.representations).map(\.type),
            knownBytes: snapshot.payloadSizeBytes
        )
        switch result {
        case .committed(let id), .merged(let id):
            coordinator.recordSaveSuccess()
            if current?.changeCount == snapshot.changeCount { current = nil }
            record("change \(snapshot.changeCount) saved: \(snapshot.displayType.rawValue), \(snapshot.payloadSizeBytes) bytes")
            onSaved?(id)
        case .rejected(let reason):
            current = CurrentClipboard(changeCount: snapshot.changeCount, status: .rejected(reason), change: change, thumbnail: enrichment.thumbnail)
            record("change \(snapshot.changeCount) rejected by the store")
        case .failed(let error):
            current = CurrentClipboard(changeCount: snapshot.changeCount, status: .saveFailed(error), change: change, thumbnail: enrichment.thumbnail)
            record("change \(snapshot.changeCount) save failed twice")
            if coordinator.recordSaveFailure() {
                storageError = error
                record("capture paused: storage error")
            }
        case .dropped:
            record("change \(snapshot.changeCount) dropped: raced with clear, delete or edit")
        }
    }

    /// *Save anyway* (§3.2.3): one-shot read, only if the clipboard did not change.
    func saveCurrentAnyway() {
        guard let current, current.allowsSaveAnyway, !isSavingAnyway, !coordinator.destructiveInProgress, access.allowsCapture else { return }
        guard NSPasteboard.general.changeCount == current.changeCount else {
            self.current = nil
            return
        }
        isSavingAnyway = true
        startReader(readerSeq: coordinator.opSeq, saveAnyway: true, expectedChangeCount: current.changeCount)
    }

    func dismissCurrent() { current = nil }

    func resumeAfterStorageError() {
        storageError = nil
        coordinator.recordSaveSuccess()
        record("capture resumed after storage error")
    }

    // MARK: Restore (§3.4)

    enum WriteOutcome: Equatable {
        case written
        case failed(String)
    }

    /// Synchronous clear → write → confirm on the main actor; publishes the token only when confirmed.
    func write(_ items: [CanonicalItem], sourceBundleID: String?) -> WriteOutcome {
        let result = autoreleasepool { PasteboardWriter.write(items, sourceBundleID: sourceBundleID) }
        switch result {
        case .written(let ownedCount):
            coordinator.publishToken(ownedCount)
            if current != nil { current = nil }
            record("restored as change \(ownedCount)")
            return .written
        case .unconfirmed:
            record("restore written but not confirmed: no suppression token")
            return .written
        case .aborted:
            record("restore aborted: another app changed the clipboard")
            return .failed(String(localized: "Another app changed the clipboard. Try again."))
        case .failed:
            record("restore failed: writeObjects returned false")
            return .failed(String(localized: "Could not write to the clipboard."))
        }
    }

    // MARK: Clear / Delete / Edit (§3.2 rule 5)

    enum DestructiveError: Error {
        case busy
        case failed(String)
    }

    /// Runs one destructive store operation with a fresh `opSeq`; a second one while it runs is busy.
    func destructive<T: Sendable>(_ operation: (Int) async throws -> T) async -> Result<T, DestructiveError> {
        guard let opSeq = coordinator.beginDestructive() else { return .failure(.busy) }
        defer { coordinator.endDestructive() }
        do {
            return .success(try await operation(opSeq))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    // MARK: Pause and skip (§3.7)

    func pause(minutes: Int) {
        coordinator.pause(until: Date().addingTimeInterval(TimeInterval(minutes) * 60))
        persistPause()
        record("paused for \(minutes) min")
    }

    func pauseIndefinitely() {
        coordinator.pauseIndefinitely()
        persistPause()
        record("paused until resumed")
    }

    func resume() {
        coordinator.resume(currentChangeCount: NSPasteboard.general.changeCount)
        persistPause()
        record("resumed; current change marked handled")
    }

    func togglePause() {
        isPaused ? resume() : pauseIndefinitely()
    }

    func toggleSkip() {
        if coordinator.skipArmed { coordinator.cancelSkip() } else { coordinator.armSkip() }
    }

    private func persistPause() {
        settings.pausedUntil = coordinator.pausedUntil
        settings.pausedIndefinitely = coordinator.pausedIndefinitely
    }

    // MARK: Diagnostics (never clipboard content, §6)

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

/// The latest stable change that was not saved (red card, §3.2.3). In memory only.
struct CurrentClipboard: Equatable {
    enum Status: Equatable {
        case notSaved(NotSavedReason)
        case rejected(String)
        case saveFailed(String)
    }

    let changeCount: Int
    let status: Status
    let change: UnsavedChange
    /// Only from data already read within the budget; never persisted.
    var thumbnail: Data?

    var title: String {
        switch status {
        case .notSaved(.noSupportedFormats): String(localized: "No supported formats")
        case .notSaved(.tooLarge(let limit)): String(localized: "Larger than \(ByteCount.string(limit))")
        case .notSaved(.readFailed): String(localized: "Read failed")
        case .rejected(let reason): String(localized: "Not saved: \(reason)")
        case .saveFailed(let reason): String(localized: "Save failed: \(reason)")
        }
    }

    var allowsSaveAnyway: Bool {
        switch status {
        case .notSaved, .saveFailed: true
        case .rejected: false
        }
    }

    var isTooLarge: Bool {
        if case .notSaved(.tooLarge) = status { return true }
        return false
    }

    var hasNoSupportedFormats: Bool {
        status == .notSaved(.noSupportedFormats)
    }
}

enum ByteCount {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
