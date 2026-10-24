import Foundation
import MemopilaServices
import os

/// Background text recognition, one job at a time at utility priority (PLAN §3.8).
/// Never blocks capture; pauses under memory pressure.
@MainActor
final class RecognitionService {
    private let store: ClipboardStore
    private let settings: SettingsStore
    private var loop: Task<Void, Never>?
    private var pausedUntil: Date?
    private let logger = Logger(subsystem: "io.github.dan-leech.Memopila", category: "recognition")
    /// A record's recognition finished: done, no text or failed.
    var onUpdate: ((UUID, RecognitionState) -> Void)?

    init(store: ClipboardStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    /// A wake that came while the queue was busy: it looks once more before it stops (review
    /// finding: an image captured just as the queue emptied waited for the next capture).
    private var wakeAgain = false

    /// Starts the queue if it is idle (after an ingest, on launch, when recognition is turned on).
    /// Whether a record is recognized is decided per record from its app's settings, so an app
    /// turned on while the global switch is off is still served (review finding).
    func wake() {
        if let pausedUntil, pausedUntil > Date() { return }
        guard loop == nil else {
            wakeAgain = true
            return
        }
        loop = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        repeat {
            wakeAgain = false
            await run()
        } while wakeAgain && !Task.isCancelled
        loop = nil
        // A wake that came while a cancelled pass finished its job is served now (review finding:
        // after memory pressure, waiting images stayed until the next copy).
        if wakeAgain, Task.isCancelled {
            wakeAgain = false
            wake()
        }
    }

    /// Memory pressure (§7.3): stop after the current job and stay idle for a minute.
    func postpone() {
        pausedUntil = Date().addingTimeInterval(60)
        loop?.cancel()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(61))
            self?.wake()
        }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            guard let id = try? await store.recognitionCandidates(limit: 1).first else { return }
            let app = (try? await store.card(id))?.sourceAppBundleID
            let allowed = app.map { settings.settings(for: $0).recognizeText } ?? settings.recognizeText
            // Every outcome is saved before going on, and a store that fails stops the queue
            // instead of handing back the same record forever (review finding).
            guard allowed else {
                guard (try? await store.setRecognizedText(id, text: nil, state: .off)) != nil else { return }
                onUpdate?(id, .off)
                continue
            }
            let state: RecognitionState
            var text: String?
            do {
                guard let input = try await store.recognitionInput(for: id) else {
                    guard (try? await store.setRecognizedText(id, text: nil, state: .failed)) != nil else { return }
                    onUpdate?(id, .failed)
                    continue
                }
                let languages = settings.effectiveRecognitionLanguages
                text = try await Task.detached(priority: .utility) {
                    try autoreleasepool { try TextRecognizer.recognize(data: input.data, isPDF: input.isPDF, languages: languages) }
                }.value
                state = text == nil ? .noText : .done
            } catch {
                logger.error("recognition failed: \(error.localizedDescription, privacy: .public)")
                state = .failed
                failures += 1
            }
            do {
                try await store.setRecognizedText(id, text: text, state: state)
            } catch {
                // The store is failing; try again on the next wake instead of spinning.
                return
            }
            onUpdate?(id, state)
            if failures >= 5 { return }
        }
    }
}
