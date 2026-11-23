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
    /// The record the clipboard holds now (§8.2, *In Clipboard* on its card): set by a save or a
    /// restore of exactly that change, cleared as soon as the clipboard holds anything else.
    private(set) var clipboardRecordID: UUID?
    /// When a paste stack wrote the clipboard: green chrome on the stack card (§3.11 / §5).
    private(set) var clipboardStackID: UUID?
    @ObservationIgnored private var clipboardRecordChangeCount: Int?
    /// Fired when identity clears because of an external pasteboard change (disarm stacks).
    @ObservationIgnored var onExternalClipboardChange: (() -> Void)?
    /// Fired when a Memopila write replaces an armed stack identity (P27 Diagnostics / other writes).
    @ObservationIgnored var onStackIdentitySuperseded: (() -> Void)?
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
    /// A copy being read or saved when ⌘Q arrives is waited for, not lost.
    @ObservationIgnored private let writes: WriteLedger
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.dan-leech.Memopila", category: "capture")
    /// A record was committed or merged.
    @ObservationIgnored var onSaved: ((UUID) -> Void)?
    /// Record ids that must not be quota-evicted on ingest (Undo window, open editor).
    @ObservationIgnored var protectingRecords: () -> Set<UUID> = { [] }
    @ObservationIgnored var panelIsKey: () -> Bool = { false }
    @ObservationIgnored private let frontmostTracker = FrontmostTracker()
    /// What was on the clipboard at launch was copied by an unknown app (§3.2 rule 4).
    @ObservationIgnored private var launchChangeCount: Int?
    /// Who was in front when a change was first seen: its reader may start later, after the user
    /// moved on (review finding: a copy read after switching apps went to the new app).
    @ObservationIgnored private var attribution: (changeCount: Int, source: String?, screenshotSource: String?, panelKey: Bool)?
    /// The panel was key at the previous poll too: opening it right after copying elsewhere does
    /// not make Memopila the source (review finding).
    @ObservationIgnored private var panelWasKey = false
    @ObservationIgnored private var previousTick = Date()
    /// Holds App Nap off while provisional empty, skip armed, or a capture flight is open.
    @ObservationIgnored private var napActivity: NSObjectProtocol?
    /// Bumped on `stopAndIdle`: late detached readers must release flight and stop mutating UI.
    @ObservationIgnored private var captureEpoch = 0

    static let ownBundleID = Bundle.main.bundleIdentifier ?? "io.github.dan-leech.Memopila"

    /// The last other app that was active: where the focus goes back to when nothing else is known.
    var lastOtherApp: NSRunningApplication? { frontmostTracker.lastOtherApp }

    init(settings: SettingsStore, store: ClipboardStore, writes: WriteLedger) {
        self.settings = settings
        self.store = store
        self.writes = writes
        coordinator = CaptureCoordinator(pausedUntil: settings.pausedUntil, pausedIndefinitely: settings.pausedIndefinitely)
    }

    var isPaused: Bool { coordinator.isPaused }
    var pausedUntil: Date? { coordinator.pausedUntil }
    var skipArmed: Bool { coordinator.skipArmed }
    /// Store mutation busy (Clear / Delete / Edit). Pasteboard lease is separate (`flight`).
    var isBusy: Bool { coordinator.destructiveInProgress }
    var isCaptureBlocked: Bool { !access.allowsCapture || storageError != nil }
    var needsNap: Bool {
        coordinator.openGeneration.hasProvisionalHeat
            || coordinator.skipArmed
            || !coordinator.flight.isIdle
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
        // Only while capturing: paused or blocked, nothing is attributed (review finding).
        if !isCaptureBlocked, !isPaused { frontmostTracker.sampleScreenshotAgents() }
        let changeCount = NSPasteboard.general.changeCount
        let panelKeyNow = panelIsKey()
        if attribution?.changeCount != changeCount {
            attribution = (
                changeCount,
                frontmostTracker.source(since: previousTick),
                frontmostTracker.screenshotSource(),
                panelKeyNow && panelWasKey
            )
        }
        panelWasKey = panelKeyNow
        if let current, changeCount != current.changeCount {
            self.current = nil
        }
        // Own clear→write bumps changeCount before identity is updated; both happen under
        // `.leased`, so a tick must not treat that gap as an external change (would disarm stacks).
        if clipboardRecordID != nil || clipboardStackID != nil,
           changeCount != clipboardRecordChangeCount,
           coordinator.flight.isIdle {
            let hadStack = clipboardStackID != nil
            setClipboardIdentity(recordID: nil, stackID: nil, changeCount: nil)
            if hadStack { onExternalClipboardChange?() }
        }
        // Tick a copy: writing back an unchanged coordinator would still notify every observer
        // four times a second (menu bar icon, banners) through the @Observable accessor.
        var next = coordinator
        let phaseA = next.tick(accessAllowed: !isCaptureBlocked, now: Date()) {
            NSPasteboard.general.changeCount
        }
        if next != coordinator { coordinator = next }
        let tickStart = previousTick
        previousTick = Date()
        switch phaseA {
        case .needsPeek(let changeCount):
            applyAndExecute(peek: PasteboardTypesPeek.read(), changeCount: changeCount, sourceSince: tickStart)
        case .pauseEnded(let changeCount):
            persistPause()
            applyResumePeek(changeCount: changeCount, reason: "pause ended")
        case .suppressedOwnWrite(let changeCount):
            record("own write \(changeCount) suppressed")
        case .idle:
            break
        }
        refreshNap()
    }

    private func applyAndExecute(peek: TypesPeek, changeCount: Int, sourceSince: Date?) {
        var next = coordinator
        let result = next.applyPeek(peek, changeCount: changeCount)
        if next != coordinator { coordinator = next }
        execute(result, changeCount: changeCount, sourceSince: sourceSince)
    }

    private func execute(_ result: ApplyPeekResult, changeCount: Int, sourceSince: Date?) {
        switch result {
        case .skip(.keepArmed(let peek)):
            record("skip armed; keep open for \(peekLabel(peek)) @\(changeCount)")
        case .skip(.consume(let count, let reason)):
            switch reason {
            case .skipArmed:
                record("skip next copy: change \(count) skipped without reading")
            case .ignoreNext:
                record("ignore next content: change \(count) skipped without reading")
            case .confidentialStable:
                record("skip next copy: confidential change \(count) consumed after stable peek")
            }
        case .empty(.provisional(let hits)):
            record("empty @\(changeCount) provisional hit \(hits)")
            if let launchChangeCount, changeCount == launchChangeCount, hits >= 1 {
                // Empty at launch: nothing to attribute; drop the launch marker so later copies are normal.
                self.launchChangeCount = nil
            }
        case .empty(.quietOpen):
            break
        case .ephemeralLeaveOpen:
            record("ephemeral @\(changeCount) left open")
        case .peekFailedLeaveOpen:
            record("types peek failed @\(changeCount); left open")
        case .confidentialProgress(let hits):
            record("confidential @\(changeCount) progress hit \(hits)")
        case .confidentialStable(let count, let type):
            let source = attribution?.changeCount == count ? attribution?.source : nil
            current = CurrentClipboard(
                changeCount: count,
                status: .concealed,
                change: UnsavedChange(
                    identity: AppIdentity(bundleID: source, source: source == nil ? .unknown : .frontmost),
                    declaredTypes: [type],
                    knownBytes: 0
                )
            )
            record("confidential @\(count) stable; marked handled")
        case .startReader(let readerSeq):
            if let launchChangeCount, changeCount == launchChangeCount {
                // Consumed as launch content (or will be); marker cleared after context build.
            }
            startReader(readerSeq: readerSeq, saveAnyway: false, sourceSince: sourceSince)
        }
    }

    private func applyResumePeek(changeCount: Int, reason: String) {
        let peek = PasteboardTypesPeek.read()
        switch ResumePolicy.decide(peek, changeCount: changeCount) {
        case .leaveOpen:
            record("\(reason); \(peekLabel(peek)) @\(changeCount) left open")
        case .markHandled(let count):
            coordinator.markHandled(count)
            record("\(reason); \(peekLabel(peek)) @\(count) marked handled")
        }
    }

    private func peekLabel(_ peek: TypesPeek) -> String {
        switch peek {
        case .empty: "empty"
        case .confidential: "confidential"
        case .ephemeralPrivacy: "ephemeral"
        case .hasContent: "content"
        case .peekFailed: "peekFailed"
        }
    }

    private func refreshNap() {
        if needsNap {
            if napActivity == nil {
                napActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical],
                    reason: "Memopila pasteboard capture"
                )
            }
        } else if let napActivity {
            ProcessInfo.processInfo.endActivity(napActivity)
            self.napActivity = nil
        }
    }

    /// - Parameter expectedChangeCount: *Save anyway* reads only the change its red card shows;
    ///   any other count is treated as unstable.
    private func startReader(
        readerSeq: Int,
        saveAnyway: Bool,
        expectedChangeCount: Int? = nil,
        sourceSince: Date? = nil,
        identity: AppIdentity? = nil
    ) {
        let reader = SnapshotReader(context: captureContext(saveAnyway: saveAnyway, sourceSince: sourceSince, identity: identity))
        let frontmost = NSWorkspace.shared.frontmostApplication
        let titleSource = AccessibilityBridge.isTrusted ? frontmost.map { ($0.processIdentifier, $0.bundleIdentifier) } : nil
        let writes = writes
        let epoch = captureEpoch
        writes.begin()
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
            await self?.finishRead(
                outcome,
                enrichment: enrichment,
                readerSeq: readerSeq,
                saveAnyway: saveAnyway,
                epoch: epoch
            )
            await writes.end()
        }
    }

    private func captureContext(saveAnyway: Bool, sourceSince: Date?, identity: AppIdentity? = nil) -> CaptureContext {
        let changeCount = NSPasteboard.general.changeCount
        var source: String?
        var screenshotSource: String?
        var panelKey: Bool
        if let attribution, attribution.changeCount == changeCount {
            source = attribution.source
            screenshotSource = attribution.screenshotSource
            panelKey = attribution.panelKey
        } else {
            source = frontmostTracker.source(since: sourceSince ?? Date())
            screenshotSource = frontmostTracker.screenshotSource()
            panelKey = panelIsKey()
        }
        var isLaunchContent = false
        if let launchChangeCount, changeCount == launchChangeCount {
            // Copied before launch: not by the panel that opened with it either.
            source = nil
            screenshotSource = nil
            panelKey = false
            isLaunchContent = true
        } else {
            launchChangeCount = nil
        }
        return CaptureContext(
            profiles: settings.profiles,
            formatPolicy: settings.formatPolicy,
            frontmostBundleID: source,
            panelIsKey: panelKey,
            ownBundleID: Self.ownBundleID,
            ignoreRemoteClipboard: settings.ignoreRemoteClipboard,
            saveAnyway: saveAnyway,
            secretPolicy: settings.secretPolicy,
            secretKinds: settings.secretKinds,
            screenshotSource: screenshotSource,
            isLaunchContent: isLaunchContent,
            identityOverride: identity
        )
    }

    /// Reader returned (§3.2 rule 2): post-read gate → store → outcome table → single flight ends.
    private func finishRead(
        _ outcome: SnapshotReadOutcome,
        enrichment: IngestEnrichment?,
        readerSeq: Int,
        saveAnyway: Bool,
        epoch: Int
    ) async {
        defer {
            if saveAnyway { isSavingAnyway = false }
            refreshNap()
        }
        // Quit abandoned this generation: release flight only, do not ingest or touch cards.
        guard epoch == captureEpoch else {
            coordinator.captureFinished(handledChangeCount: nil)
            record("reader epoch \(epoch) abandoned (current \(captureEpoch))")
            return
        }
        refreshAccess()
        guard access.allowsCapture else {
            // Always release the flight we hold (normal capture or Save anyway).
            coordinator.captureFinished(handledChangeCount: nil)
            record("post-read gate: access gone, result discarded")
            return
        }
        switch outcome {
        case .unstable:
            record("unstable read discarded")
        case .skipped(let changeCount, let reason):
            record("change \(changeCount) skipped: \(reason)")
            // Peek-first usually handles confidential; reader path still shows the password card
            // if a mid-read marker appears.
            if case .privacyMarker(let type) = reason, PrivacyMarker.kind(of: type) == .confidential {
                let source = attribution?.changeCount == changeCount ? attribution?.source : nil
                current = CurrentClipboard(
                    changeCount: changeCount,
                    status: .concealed,
                    change: UnsavedChange(identity: AppIdentity(bundleID: source, source: source == nil ? .unknown : .frontmost), declaredTypes: [type], knownBytes: 0)
                )
            }
        case .notSaved(let changeCount, let reason, let change):
            current = CurrentClipboard(changeCount: changeCount, status: .notSaved(reason), change: change)
            record("change \(changeCount) not saved: \(reason)")
        case .captured(let snapshot):
            coordinator.beginIngest(changeCount: snapshot.changeCount)
            // Colour-UTI-only → HEX text before hash so store ≡ makeItems write (§8.5).
            let normalized = ColorPayload.normalizedSnapshot(snapshot)
            var enrichment = IngestEnrichment.make(
                for: normalized.items,
                sourceAppName: AppInfo.name(for: normalized.identity.bundleID),
                sourceWindowTitle: enrichment?.sourceWindowTitle
            )
            enrichment.sourceAppName = AppInfo.name(for: normalized.identity.bundleID)
            await ingest(normalized, enrichment: enrichment, readerSeq: readerSeq)
        }
        // Save anyway re-reads an already-handled count: release flight only, do not move lastHandled.
        if saveAnyway {
            coordinator.captureFinished(handledChangeCount: nil)
        } else {
            switch outcome.handlePolicy {
            case .leaveOpen:
                coordinator.captureFinished(handledChangeCount: nil)
            case .markHandled(let count):
                coordinator.captureFinished(handledChangeCount: count)
            }
        }
    }

    private func ingest(_ snapshot: OwnedSnapshot, enrichment: IngestEnrichment, readerSeq: Int) async {
        let limits = settings.retentionLimits
        let protecting = protectingRecords()
        var result = await store.ingest(
            snapshot, readerSeq: readerSeq, enrichment: enrichment, limits: limits, protectingRecords: protecting
        )
        if case .failed = result {
            record("change \(snapshot.changeCount): save failed, retrying once")
            try? await Task.sleep(for: .seconds(1))
            result = await store.ingest(
                snapshot, readerSeq: readerSeq, enrichment: enrichment, limits: limits, protectingRecords: protectingRecords()
            )
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
            if NSPasteboard.general.changeCount == snapshot.changeCount { setClipboardRecord(id, changeCount: snapshot.changeCount) }
            // The source app's bundle ID is metadata, never clipboard content.
            record("change \(snapshot.changeCount) saved: \(snapshot.displayType.rawValue), \(snapshot.payloadSizeBytes) bytes, from \(snapshot.identity.bundleID ?? "unknown app")")
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
    /// Takes `CaptureFlight.reading` so a concurrent tick cannot start a second reader (flight SSOT).
    func saveCurrentAnyway() {
        guard let current, current.allowsSaveAnyway, !isSavingAnyway, !coordinator.destructiveInProgress, access.allowsCapture else { return }
        guard NSPasteboard.general.changeCount == current.changeCount else {
            self.current = nil
            return
        }
        guard let readerSeq = coordinator.beginReading() else { return }
        isSavingAnyway = true
        refreshNap()
        // For the app the red card named: clicking it makes the panel key, which is not who
        // copied (review finding).
        startReader(readerSeq: readerSeq, saveAnyway: true, expectedChangeCount: current.changeCount, identity: current.change.identity)
    }

    func dismissCurrent() { current = nil }

    /// *Clear Clipboard* on the password card: empties the clipboard while it still holds that
    /// password. Nothing is read.
    func clearConcealed() {
        guard let current, current.status == .concealed else { return }
        let expected = current.changeCount
        self.current = nil
        Task { @MainActor in
            _ = await ownedMutate(kind: .ownedWrite) {
                guard NSPasteboard.general.changeCount == expected else { return .aborted }
                let ownedCount = NSPasteboard.general.clearContents()
                return .written(ownedCount: ownedCount)
            } onOwned: { [self] ownedCount in
                record("concealed copy \(expected) cleared as own change \(ownedCount)")
            }
        }
    }

    /// The record no longer matches the clipboard (its text was edited).
    func recordChanged(_ id: UUID) {
        guard clipboardRecordID == id else { return }
        let hadStack = clipboardStackID != nil
        setClipboardIdentity(recordID: nil, stackID: nil, changeCount: nil)
        // Editing the dealt member while a stack is armed: disarm (pasteboard no longer matches).
        if hadStack { onExternalClipboardChange?() }
    }

    func clearStackIdentity() {
        if clipboardStackID != nil {
            setClipboardIdentity(recordID: clipboardRecordID, stackID: nil, changeCount: clipboardRecordChangeCount)
        }
    }

    /// Empty the pasteboard as our own write (suppression token). Used when a paste stack
    /// exhausts so ⌘V does not keep pasting the last member (PLAN §3.11).
    func clearOwnedClipboard() {
        Task { @MainActor in
            _ = await clearOwnedClipboardAsync()
        }
    }

    @discardableResult
    func clearOwnedClipboardAsync() async -> OwnedMutationResult {
        await ownedMutate(kind: .ownedWrite) {
            let ownedCount = NSPasteboard.general.clearContents()
            return .written(ownedCount: ownedCount)
        } onOwned: { [self] ownedCount in
            if current != nil { current = nil }
            setClipboardIdentity(recordID: nil, stackID: nil, changeCount: nil)
            record("clipboard cleared as own change \(ownedCount)")
        }
    }

    private func setClipboardRecord(_ id: UUID?, changeCount: Int?) {
        setClipboardIdentity(recordID: id, stackID: nil, changeCount: changeCount)
    }

    private func setClipboardIdentity(recordID: UUID?, stackID: UUID?, changeCount: Int?) {
        clipboardRecordChangeCount = (recordID == nil && stackID == nil) ? nil : changeCount
        if clipboardRecordID != recordID { clipboardRecordID = recordID }
        if clipboardStackID != stackID { clipboardStackID = stackID }
    }

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

    enum OwnedMutationFailure: Equatable {
        case busy
        case idleTimeout
        case cancelled
        case aborted
        case unconfirmed
        case writeFailed
    }

    enum OwnedMutationResult: Equatable {
        case written(ownedCount: Int)
        case failed(OwnedMutationFailure)
    }

    private enum OwnedWriteBody: Equatable {
        case written(ownedCount: Int)
        case aborted
        case unconfirmed
        case writeFailed
    }

    /// Await reading|ingesting idle → CAS lease → body → token iff confirmed owned count.
    /// Retries CAS: after `await` another MainActor tick can start a reader before we lease (TOCTOU).
    /// `onOwned` runs under the lease (after token, before endLease) so clipboard identity cannot
    /// race a tick that would treat the new count as an external change.
    private func ownedMutate(
        kind: PasteboardLeaseKind,
        timeout: Duration = .seconds(2),
        body: () -> OwnedWriteBody,
        onOwned: ((Int) -> Void)? = nil
    ) async -> OwnedMutationResult {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch coordinator.flight {
            case .reading, .ingesting:
                try? await Task.sleep(for: .milliseconds(10))
                continue
            case .leased:
                // Another owned mutate holds the pasteboard; wait it out.
                try? await Task.sleep(for: .milliseconds(10))
                continue
            case .idle:
                break
            }
            guard let lease = coordinator.beginLease(kind: kind) else {
                // Lost the race to tick/applyPeek → reading; retry.
                continue
            }
            defer {
                coordinator.endLease(lease)
                refreshNap()
            }
            refreshNap()
            switch body() {
            case .written(let ownedCount):
                coordinator.publishToken(ownedCount)
                onOwned?(ownedCount)
                return .written(ownedCount: ownedCount)
            case .aborted:
                return .failed(.aborted)
            case .unconfirmed:
                return .failed(.unconfirmed)
            case .writeFailed:
                return .failed(.writeFailed)
            }
        }
        return .failed(.idleTimeout)
    }

    /// Clear → write → confirm under pasteboard lease; publishes the token only when confirmed.
    /// `recordID`: the record whose content this is, marked *In Clipboard*.
    /// `stackID`: when set, green chrome tracks the stack card (§3.11).
    func write(
        _ items: [CanonicalItem],
        sourceBundleID: String?,
        recordID: UUID?,
        stackID: UUID? = nil
    ) -> WriteOutcome {
        // Sync entry for UI call sites: CAS lease only when already idle (no await).
        guard coordinator.flight.isIdle, let lease = coordinator.beginLease(kind: .ownedWrite) else {
            return .failed(String(localized: "Clipboard is busy. Try again."))
        }
        defer {
            coordinator.endLease(lease)
            refreshNap()
        }
        refreshNap()
        let result = autoreleasepool { PasteboardWriter.write(items, sourceBundleID: sourceBundleID) }
        switch result {
        case .written(let ownedCount):
            let supersededStack = clipboardStackID != nil && stackID == nil
            coordinator.publishToken(ownedCount)
            if current != nil { current = nil }
            setClipboardIdentity(recordID: recordID, stackID: stackID, changeCount: ownedCount)
            record("restored as change \(ownedCount)")
            if supersededStack { onStackIdentitySuperseded?() }
            return .written
        case .unconfirmed:
            let hadStack = clipboardStackID != nil
            setClipboardIdentity(recordID: nil, stackID: nil, changeCount: nil)
            record("restore written but not confirmed: no suppression token")
            if hadStack { onStackIdentitySuperseded?() }
            return .failed(String(localized: "Could not put this on the clipboard."))
        case .aborted:
            record("restore aborted: another app changed the clipboard")
            return .failed(String(localized: "Another app changed the clipboard. Try again."))
        case .failed:
            record("restore failed: writeObjects returned false")
            return .failed(String(localized: "Could not put this on the clipboard."))
        }
    }

    /// Async restore that waits for an in-flight reader before leasing the pasteboard.
    func writeAsync(
        _ items: [CanonicalItem],
        sourceBundleID: String?,
        recordID: UUID?,
        stackID: UUID? = nil
    ) async -> WriteOutcome {
        var supersededStack = false
        let mutation = await ownedMutate(kind: .ownedWrite) {
            switch PasteboardWriter.write(items, sourceBundleID: sourceBundleID) {
            case .written(let ownedCount): .written(ownedCount: ownedCount)
            case .aborted: .aborted
            case .unconfirmed: .unconfirmed
            case .failed: .writeFailed
            }
        } onOwned: { [self] ownedCount in
            supersededStack = clipboardStackID != nil && stackID == nil
            if current != nil { current = nil }
            setClipboardIdentity(recordID: recordID, stackID: stackID, changeCount: ownedCount)
            record("restored as change \(ownedCount)")
        }
        switch mutation {
        case .written:
            if supersededStack { onStackIdentitySuperseded?() }
            return .written
        case .failed(.busy), .failed(.idleTimeout), .failed(.cancelled):
            return .failed(String(localized: "Clipboard is busy. Try again."))
        case .failed(.aborted):
            record("restore aborted: another app changed the clipboard")
            return .failed(String(localized: "Another app changed the clipboard. Try again."))
        case .failed(.unconfirmed):
            let hadStack = clipboardStackID != nil
            setClipboardIdentity(recordID: nil, stackID: nil, changeCount: nil)
            record("restore written but not confirmed: no suppression token")
            if hadStack { onStackIdentitySuperseded?() }
            return .failed(String(localized: "Could not put this on the clipboard."))
        case .failed(.writeFailed):
            record("restore failed: writeObjects returned false")
            return .failed(String(localized: "Could not put this on the clipboard."))
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
        let changeCount = NSPasteboard.general.changeCount
        coordinator.endPause()
        persistPause()
        applyResumePeek(changeCount: changeCount, reason: "resumed")
        refreshNap()
    }

    /// Wait for capture flight idle (quit / shutdown). Does not force a pasteboard write.
    func stopAndIdle(timeout: Duration = .seconds(2)) async {
        timer?.invalidate()
        timer = nil
        captureEpoch += 1
        let deadline = ContinuousClock.now + timeout
        while !coordinator.flight.isIdle {
            if ContinuousClock.now >= deadline {
                record("stopAndIdle: abandoned in-flight \(String(describing: coordinator.flight))")
                // Fence late finishRead; do not force a pasteboard write.
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let napActivity {
            ProcessInfo.processInfo.endActivity(napActivity)
            self.napActivity = nil
        }
    }

    func togglePause() {
        isPaused ? resume() : pauseIndefinitely()
    }

    func toggleSkip() {
        if coordinator.skipArmed { coordinator.cancelSkip() } else { coordinator.armSkip() }
    }

    /// Silent one-shot ignore for synthetic Cmd+C (layout convert). Does not show Skip chrome.
    func armIgnoreNextContentChange() {
        coordinator.armIgnoreNextContentChange()
    }

    func cancelIgnoreNextContentChange() {
        coordinator.cancelIgnoreNextContentChange()
    }

    /// Restores arbitrary pasteboard items as an owned write (layout-convert clipboard dance).
    @discardableResult
    func restorePasteboardItems(_ items: [NSPasteboardItem]) async -> OwnedMutationResult {
        await ownedMutate(kind: .ownedWrite) {
            let pasteboard = NSPasteboard.general
            let before = pasteboard.clearContents()
            guard !items.isEmpty else { return .written(ownedCount: before) }
            guard pasteboard.writeObjects(items) else { return .writeFailed }
            let after = pasteboard.changeCount
            return after > before ? .written(ownedCount: after) : .unconfirmed
        } onOwned: { [self] ownedCount in
            if current != nil { current = nil }
            setClipboardIdentity(recordID: nil, stackID: nil, changeCount: nil)
            record("pasteboard restored as own change \(ownedCount)")
        }
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
        /// A password manager marked it concealed: never read, saved or shown.
        case concealed
    }

    let changeCount: Int
    let status: Status
    let change: UnsavedChange
    var observedAt = Date()
    /// Only from data already read within the budget; never persisted.
    var thumbnail: Data?

    var title: String {
        switch status {
        case .notSaved(.noSupportedFormats): String(localized: "No supported formats")
        case .notSaved(.tooLarge(let limit)): String(localized: "Larger than \(ByteCount.string(limit))")
        case .notSaved(.readFailed): String(localized: "Read failed")
        case .rejected(let reason): String(localized: "Not saved: \(reason)")
        case .saveFailed(let reason): String(localized: "Save failed: \(reason)")
        case .concealed: String(localized: "Password")
        }
    }

    var allowsSaveAnyway: Bool {
        switch status {
        case .notSaved, .saveFailed: true
        case .rejected, .concealed: false
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
