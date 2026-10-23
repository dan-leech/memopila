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
    /// A record's recognized text changed.
    var onUpdate: ((UUID) -> Void)?

    init(store: ClipboardStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    /// Starts the queue if it is idle (after an ingest, on launch, when recognition is turned on).
    func wake() {
        guard loop == nil, settings.recognizeText else { return }
        if let pausedUntil, pausedUntil > Date() { return }
        loop = Task { [weak self] in
            await self?.run()
            self?.loop = nil
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
        while !Task.isCancelled, settings.recognizeText {
            guard let id = try? await store.recognitionCandidates(limit: 1).first else { return }
            if let card = try? await store.card(id), let app = card.sourceAppBundleID, !settings.settings(for: app).recognizeText {
                try? await store.setRecognizedText(id, text: nil, state: .off)
                continue
            }
            let state: RecognitionState
            var text: String?
            do {
                guard let input = try await store.recognitionInput(for: id) else {
                    try? await store.setRecognizedText(id, text: nil, state: .failed)
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
            if state == .done { onUpdate?(id) }
            if failures >= 5 { return }
        }
    }
}
