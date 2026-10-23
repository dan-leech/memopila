import Foundation
import MemopilaCore
import Testing
@testable import MemopilaServices

private func snapshot(
    _ text: String,
    at seconds: TimeInterval = 1_000,
    app: String? = "com.example.editor",
    settings: ResolvedAppSettings = ResolvedAppSettings(),
    items: [CanonicalItem]? = nil
) -> OwnedSnapshot {
    let items = items ?? [CanonicalItem([.bytes(.utf8PlainText, Data(text.utf8))])]
    return OwnedSnapshot(
        changeCount: 1,
        observedAt: Date(timeIntervalSince1970: seconds),
        identity: AppIdentity(bundleID: app, source: .frontmost),
        settings: settings,
        items: items,
        contentHash: MCS1.contentHash(of: items),
        payloadSizeBytes: MCS1.payloadSize(of: items),
        displayType: DisplayType.classify(items),
        skippedTypes: [],
        sourceURL: nil
    )
}

private func ingest(_ store: ClipboardStore, _ snapshot: OwnedSnapshot, readerSeq: Int = 0, limits: RetentionLimits = RetentionLimits()) async -> IngestResult {
    await store.ingest(snapshot, readerSeq: readerSeq, enrichment: IngestEnrichment.make(for: snapshot.items, sourceAppName: "Editor"), limits: limits)
}

@Suite("Clipboard store (§3.5, §4, §6)")
struct ClipboardStoreTests {
    @Test func ingestAndPage() async throws {
        let store = try ClipboardStore(url: nil)
        let result = await ingest(store, snapshot("hello world"))
        guard case .committed(let id) = result else { Issue.record("\(result)"); return }
        let cards = try await store.page(HistoryQuery(), offset: 0, limit: 10)
        #expect(cards.map(\.id) == [id])
        #expect(cards.first?.preview == "hello world")
        #expect(cards.first?.displayType == .text)
        #expect(cards.first?.sourceAppName == "Editor")
        #expect(cards.first?.copyCount == 1)
    }

    @Test func dedupMergesMetadataOnly() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("same", at: 1_000)) else { Issue.record("not committed"); return }
        #expect(await ingest(store, snapshot("same", at: 2_000, app: "com.other.app")) == .merged(id))
        let card = try #require(try await store.card(id))
        #expect(card.copyCount == 2)
        #expect(card.lastCopiedAt == Date(timeIntervalSince1970: 2_000))
        #expect(card.sourceAppBundleID == "com.other.app")
        #expect(try await store.count(HistoryQuery()) == 1)
    }

    @Test func clearDropsInFlightSnapshots() async throws {
        let store = try ClipboardStore(url: nil)
        try await store.clear(.all, opSeq: 1)
        #expect(await ingest(store, snapshot("late"), readerSeq: 0) == .dropped)
        guard case .committed = await ingest(store, snapshot("fresh"), readerSeq: 1) else { Issue.record("not committed"); return }
    }

    @Test func deleteDoesNotResurrectButKeepsUnrelated() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("A")) else { Issue.record("not committed"); return }
        try await store.delete([id], opSeq: 1)
        #expect(await ingest(store, snapshot("A"), readerSeq: 0) == .dropped)
        guard case .committed = await ingest(store, snapshot("C"), readerSeq: 0) else { Issue.record("unrelated content must be saved"); return }
        guard case .committed = await ingest(store, snapshot("A"), readerSeq: 1) else { Issue.record("copied again after delete"); return }
    }

    @Test func countCapEvictsOldestNonFavorites() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxCount: 2)
        guard case .committed(let first) = await ingest(store, snapshot("1", at: 1), limits: limits) else { return }
        try await store.setFavorite(first, true, limits: limits, now: Date(timeIntervalSince1970: 2))
        _ = await ingest(store, snapshot("2", at: 2), limits: limits)
        _ = await ingest(store, snapshot("3", at: 3), limits: limits)
        _ = await ingest(store, snapshot("4", at: 4), limits: limits)
        let previews = try await store.page(HistoryQuery(), offset: 0, limit: 10).map(\.preview)
        #expect(previews == ["4", "3", "1"])
    }

    @Test func storageQuotaRejectsWithoutDeletingFavorites() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxStorageBytes: 10)
        guard case .committed(let id) = await ingest(store, snapshot("12345678", at: 1), limits: limits) else { return }
        try await store.setFavorite(id, true, limits: limits, now: Date(timeIntervalSince1970: 1))
        guard case .rejected = await ingest(store, snapshot("abcdef", at: 2), limits: limits) else { Issue.record("expected reject"); return }
        #expect(try await store.count(HistoryQuery()) == 1)
    }

    @Test func payloadRoundTripsThroughIntegrityChecks() async throws {
        let items = [
            CanonicalItem([.bytes(.utf8PlainText, Data("a b".utf8)), .bytes(.html, Data("<b>a b</b>".utf8))]),
            CanonicalItem([.files(.fileURL, ["/tmp/a b.txt", "/tmp/ü.txt"])]),
        ]
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("", items: items)) else { Issue.record("not committed"); return }
        let payload = try await store.payload(for: id)
        #expect(payload.items == items)
        #expect(payload.sourceBundleID == "com.example.editor")
    }

    @Test func search() async throws {
        let store = try ClipboardStore(url: nil)
        _ = await ingest(store, snapshot("the quick brown fox", at: 1))
        _ = await ingest(store, snapshot("quick silver", at: 2))
        _ = await ingest(store, snapshot("Ёлка и ПРИВЕТ", at: 3))
        #expect(try await store.page(HistoryQuery(search: "quick"), offset: 0, limit: 10).count == 2)
        #expect(try await store.page(HistoryQuery(search: "quick fox"), offset: 0, limit: 10).map(\.preview) == ["the quick brown fox"])
        #expect(try await store.page(HistoryQuery(search: "привет"), offset: 0, limit: 10).count == 1)
        #expect(try await store.page(HistoryQuery(search: "QUICK"), offset: 0, limit: 10).count == 2)
        #expect(try await store.page(HistoryQuery(search: "editor"), offset: 0, limit: 10).count == 3, "source app name is searchable")
    }

    @Test func scopes() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1, app: "com.a.app")),
              case .committed(let b) = await ingest(store, snapshot("https://example.com", at: 2, app: "com.b.app")) else { return }
        try await store.setFavorite(a, true, limits: RetentionLimits(), now: Date(timeIntervalSince1970: 3))
        #expect(try await store.page(HistoryQuery(scope: .favorites), offset: 0, limit: 10).map(\.id) == [a])
        #expect(try await store.page(HistoryQuery(scope: .app("com.b.app")), offset: 0, limit: 10).map(\.id) == [b])
        #expect(try await store.page(HistoryQuery(scope: .type(.url)), offset: 0, limit: 10).map(\.id) == [b])

        let collection = try await store.createCollection(named: "Work")
        try await store.setMembership(record: b, collection: collection, isMember: true)
        #expect(try await store.page(HistoryQuery(scope: .collection(collection)), offset: 0, limit: 10).map(\.id) == [b])
        #expect(try await store.collections().first?.count == 1)
        #expect(try await store.apps().map(\.bundleID) == ["com.b.app", "com.a.app"])
        #expect(try await store.displayTypes() == [.text, .url])

        try await store.deleteCollection(collection)
        #expect(try await store.collections().isEmpty)
        #expect(try await store.count(HistoryQuery()) == 2, "deleting a collection keeps its records")
    }

    @Test func editTextReplacesInPlaceAndMergesOnCollision() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("draft", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("final", at: 2)) else { return }
        #expect(try await store.editText(a, text: "draft v2", opSeq: 1, maxBytes: 1_000) == .updated)
        let edited = try #require(try await store.card(a))
        #expect(edited.preview == "draft v2")
        #expect(edited.isEdited)
        #expect(try await store.payload(for: a).text == "draft v2")

        #expect(try await store.editText(a, text: "final", opSeq: 2, maxBytes: 1_000) == .merged(into: b))
        #expect(try await store.card(a) == nil)
        #expect(try await store.card(b)?.copyCount == 2)
    }

    @Test func renameIsSearchable() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("x")) else { return }
        try await store.rename(id, title: "  Deploy token  ")
        #expect(try await store.card(id)?.customTitle == "Deploy token")
        #expect(try await store.page(HistoryQuery(search: "deploy"), offset: 0, limit: 10).map(\.id) == [id])
    }

    @Test func shortRetentionExpires() async throws {
        let store = try ClipboardStore(url: nil)
        let settings = ResolvedAppSettings(captureMode: .deleteAfter(minutes: 1))
        guard case .committed = await ingest(store, snapshot("token", at: 1_000, settings: settings)) else { return }
        let next = try await store.applyRetention(limits: RetentionLimits(), now: Date(timeIntervalSince1970: 1_010))
        #expect(next == Date(timeIntervalSince1970: 1_060))
        try await store.applyRetention(limits: RetentionLimits(), now: Date(timeIntervalSince1970: 1_061))
        #expect(try await store.count(HistoryQuery()) == 0)
    }

    @Test func unfavoriteEnforcesTheCountCapAndKeepsTheRecord() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxCount: 1)
        guard case .committed(let old) = await ingest(store, snapshot("old", at: 1), limits: limits) else { return }
        try await store.setFavorite(old, true, limits: limits, now: Date(timeIntervalSince1970: 2))
        _ = await ingest(store, snapshot("new", at: 3), limits: limits)
        try await store.setFavorite(old, false, limits: limits, now: Date(timeIntervalSince1970: 4))
        #expect(try await store.page(HistoryQuery(), offset: 0, limit: 10).map(\.preview) == ["old"])
    }

    @Test func recognitionQueue() async throws {
        let store = try ClipboardStore(url: nil)
        let png = try #require(TestImages.png(width: 40, height: 20))
        let image = snapshot("", items: [CanonicalItem([.bytes(.png, png)])])
        guard case .committed(let id) = await ingest(store, image) else { Issue.record("not committed"); return }
        #expect(try await store.recognitionCandidates(limit: 10) == [id])
        #expect(try await store.card(id)?.pixelWidth == 40)
        #expect(try await store.card(id)?.hasThumbnail == true)
        #expect(try await store.thumbnail(for: id) != nil)
        try await store.setRecognizedText(id, text: "Invoice 42", state: .done)
        #expect(try await store.recognitionCandidates(limit: 10).isEmpty)
        #expect(try await store.page(HistoryQuery(search: "invoice"), offset: 0, limit: 10).map(\.id) == [id])
    }

    @Test func persistentStoreWithLargeExternalPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "memopila-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "History.store")
        let big = Data(repeating: 7, count: 32 * FormatPolicy.mebibyte)
        let items = [CanonicalItem([.bytes("com.example.big", big)])]
        let id: UUID
        do {
            let store = try ClipboardStore(url: url)
            guard case .committed(let committed) = await ingest(store, snapshot("", items: items)) else { Issue.record("not committed"); return }
            id = committed
            #expect(try await store.page(HistoryQuery(), offset: 0, limit: 10).first?.payloadSizeBytes == big.count)
        }
        // Reopen: the payload round-trips from disk.
        let reopened = try ClipboardStore(url: url)
        #expect(try await reopened.payload(for: id).items == items)
        try await reopened.delete([id], opSeq: 1)
        #expect(try await reopened.count(HistoryQuery()) == 0)
        await #expect(throws: StoreError.notFound) { try await reopened.payload(for: id) }
    }
}
