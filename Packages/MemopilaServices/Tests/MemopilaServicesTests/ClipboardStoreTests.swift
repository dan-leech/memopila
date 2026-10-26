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
        #expect(cards.first?.storedTypes == ["public.utf8-plain-text"])
        #expect(cards.first?.lineCount == 1)
        #expect(cards.first?.sensitiveKind == nil)
    }

    @Test func lineCountIgnoresTrailingBreaks() {
        #expect(TextStats.lineCount("") == 1)
        #expect(TextStats.lineCount("a") == 1)
        #expect(TextStats.lineCount("a\n") == 1)
        #expect(TextStats.lineCount("a\nb") == 2)
        #expect(TextStats.lineCount("a\r\nb\r\n\r\n") == 2)
        #expect(TextStats.lineCount("a\n\nb") == 3)
    }

    @Test func sensitiveKindIsStoredAndKeptOnMerge() async throws {
        let store = try ClipboardStore(url: nil)
        var secret = snapshot("token-like")
        secret.sensitiveKind = .jwt
        guard case .committed(let id) = await ingest(store, secret) else { Issue.record("not committed"); return }
        #expect(try await store.card(id)?.sensitiveKind == "jwt")
        #expect(await ingest(store, snapshot("token-like", at: 2_000)) == .merged(id))
        #expect(try await store.card(id)?.sensitiveKind == "jwt", "a later copy without detection does not unmask it")
    }

    @Test func unreadableStoreIsMovedAsideNotDeleted() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "memopila-recover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "History.store")
        try Data("not a database".utf8).write(to: url)

        let (store, movedTo) = try ClipboardStore.openRecovering(at: url, now: Date(timeIntervalSince1970: 0))
        let backup = try #require(movedTo)
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "History.store").path))
        guard case .committed = await ingest(store, snapshot("fresh start")) else { Issue.record("new store must work"); return }

        let (_, second) = try ClipboardStore.openRecovering(at: url)
        #expect(second == nil, "a healthy store opens in place")
    }

    @Test func windowTitleFollowsTheRecordSourcePageSetting() async throws {
        let store = try ClipboardStore(url: nil)
        let enrichment = IngestEnrichment(cardPreview: "a", sourceWindowTitle: "Docs — Example")
        guard case .committed(let id) = await store.ingest(snapshot("a"), readerSeq: 0, enrichment: enrichment, limits: RetentionLimits()) else { Issue.record("not committed"); return }
        #expect(try await store.details(id)?.sourceWindowTitle == "Docs — Example")
        var off = ResolvedAppSettings()
        off.recordSourcePage = false
        guard case .committed(let other) = await store.ingest(snapshot("b", settings: off), readerSeq: 0, enrichment: enrichment, limits: RetentionLimits()) else { Issue.record("not committed"); return }
        #expect(try await store.details(other)?.sourceWindowTitle == nil)
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

    @Test func should_skip_oversized_rtfd_and_use_html() async throws {
        let store = try ClipboardStore(url: nil)
        let fat = Data(repeating: 0x41, count: 600 * 1_024)
        let html = Data("<p>hi</p>".utf8)
        let items = [CanonicalItem([.bytes(.flatRTFD, fat), .bytes(.html, html), .bytes(.utf8PlainText, Data("hi".utf8))])]
        guard case .committed(let id) = await ingest(store, snapshot("hi", items: items)) else { Issue.record("not committed"); return }
        let source = try #require(try await store.richPreviewSource(for: id, maxBytes: 512 * 1_024))
        #expect(source.type == .html)
        #expect(String(decoding: source.data, as: UTF8.self) == "<p>hi</p>")
    }

    @Test func should_return_archive_when_only_web_archive() async throws {
        let store = try ClipboardStore(url: nil)
        let archive = try PropertyListSerialization.data(
            fromPropertyList: [
                "WebMainResource": [
                    "WebResourceData": Data("<p>archived</p>".utf8),
                    "WebResourceMIMEType": "text/html",
                    "WebResourceURL": "https://example.com/",
                ] as [String: Any],
            ] as [String: Any],
            format: .binary,
            options: 0
        )
        let items = [CanonicalItem([.bytes(.webArchive, archive)])]
        guard case .committed(let id) = await ingest(store, snapshot("", items: items)) else { Issue.record("not committed"); return }
        let source = try #require(try await store.richPreviewSource(for: id))
        #expect(source.type == .webArchive)
        #expect(source.data == archive)
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

    @Test func filterBarKindsAndPeriod() async throws {
        let store = try ClipboardStore(url: nil)
        _ = await ingest(store, snapshot("plain words", at: 100))
        _ = await ingest(store, snapshot("https://example.com", at: 200))
        _ = await ingest(store, snapshot("more words", at: 300))
        let text = HistoryQuery(kinds: [.text, .richText])
        #expect(try await store.page(text, offset: 0, limit: 10).map(\.preview) == ["more words", "plain words"])
        #expect(try await store.count(HistoryQuery(kinds: [.url])) == 1)
        let recent = HistoryQuery(since: Date(timeIntervalSince1970: 150))
        #expect(try await store.count(recent) == 2)
        let recentText = HistoryQuery(search: "words", kinds: [.text], since: Date(timeIntervalSince1970: 250))
        #expect(try await store.page(recentText, offset: 0, limit: 10).map(\.preview) == ["more words"])
    }

    @Test func idsOfAQuerySetFavoritesApart() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1, app: "com.a.app")),
              case .committed(let b) = await ingest(store, snapshot("b", at: 2, app: "com.a.app")),
              case .committed = await ingest(store, snapshot("c", at: 3, app: "com.c.app")) else { return }
        try await store.setFavorite(a, true, limits: RetentionLimits(), now: Date(timeIntervalSince1970: 4))
        let found = try await store.ids(HistoryQuery(scope: .app("com.a.app")))
        #expect(found.others == [b])
        #expect(found.favorites == [a])
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
        #expect(try await store.memberships(of: [a, b]) == [b: [collection]])
        let usage = try await store.usage()
        #expect(usage.count == 2)
        #expect(usage.favorites == 1)
        #expect(usage.payloadBytes == 1 + "https://example.com".utf8.count)
        #expect(try await store.apps().map(\.bundleID) == ["com.b.app", "com.a.app"])
        #expect(try await store.displayTypes() == [.text, .url])

        try await store.deleteCollection(collection)
        #expect(try await store.collections().isEmpty)
        #expect(try await store.memberships(of: [a, b]).isEmpty)
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

    @Test func editRichTextKeepsFormattingHTMLAndPlainText() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("plain", at: 1)) else { return }
        let rich = RichContent(type: .rtf, data: Data("{\\rtf1 {\\b bold} text}".utf8), html: Data("<b>bold</b> text".utf8))
        #expect(try await store.editText(id, text: "bold text", rich: rich, opSeq: 1, maxBytes: 1_000) == .updated)
        let card = try #require(try await store.card(id))
        #expect(card.displayType == .richText)
        #expect(card.storedTypes == [PasteboardType.rtf.rawValue, PasteboardType.html.rawValue, PasteboardType.utf8PlainText.rawValue])
        let payload = try await store.payload(for: id)
        #expect(payload.text == "bold text")
        #expect(payload.items.flatMap(\.representations).map(\.type) == [.rtf, .html, .utf8PlainText])
        #expect(try await store.editText(id, text: "bold text", rich: rich, opSeq: 2, maxBytes: 10) != .updated, "RTF and HTML count against the limit")
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

    @Test func editedSecretIsMaskedAndExpires() async throws {
        let store = try ClipboardStore(url: nil)
        let now = Date(timeIntervalSince1970: 10_000)
        guard case .committed(let id) = await ingest(store, snapshot("draft", at: 9_000)) else { Issue.record("not committed"); return }
        let token = "gh" + "p_" + String(repeating: "A1b2", count: 9)
        #expect(try await store.editText(id, text: token, opSeq: 1, maxBytes: 1_000, secretPolicy: .deleteAfter(minutes: 15), now: now) == .updated)
        #expect(try await store.card(id)?.sensitiveKind == SecretKind.githubToken.rawValue)
        try await store.applyRetention(limits: RetentionLimits(), now: now.addingTimeInterval(16 * 60))
        #expect(try await store.card(id) == nil)
    }

    @Test func plainFormattingIsReclassifiedAsText() async throws {
        let store = try ClipboardStore(url: nil)
        func record(_ rtf: String, _ text: String) -> OwnedSnapshot {
            var copy = snapshot("", items: [CanonicalItem([.bytes(.rtf, Data(rtf.utf8)), .bytes(.utf8PlainText, Data(text.utf8))])])
            // As stored before formatting was weighed.
            copy.displayType = .richText
            return copy
        }
        guard case .committed(let plain) = await ingest(store, record("{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0\\fs24 plain words}", "plain words")),
              case .committed(let bold) = await ingest(store, record("{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0\\fs24 {\\b bold} words}", "bold words"))
        else { Issue.record("not committed"); return }
        #expect(try await store.reclassifyRichText() == 1)
        #expect(try await store.card(plain)?.displayType == .text)
        #expect(try await store.card(bold)?.displayType == .richText)
    }

    @Test func recordsWithSeveralItemsAreNotEdited() async throws {
        let store = try ClipboardStore(url: nil)
        let items = [CanonicalItem([.bytes(.utf8PlainText, Data("one".utf8))]), CanonicalItem([.bytes(.utf8PlainText, Data("two".utf8))])]
        guard case .committed(let id) = await ingest(store, snapshot("", items: items)) else { Issue.record("not committed"); return }
        #expect(try await store.itemCount(id) == 2)
        guard case .rejected = try await store.editText(id, text: "one!", opSeq: 1, maxBytes: 1_000) else {
            Issue.record("a record with two items was edited down to one")
            return
        }
    }

    @Test func unfavoritingAnOldRecordDeletesIt() async throws {
        // The app asks first (§6); the store then deletes it, as the next cleanup would.
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let old) = await ingest(store, snapshot("old", at: 1), limits: limits) else { return }
        try await store.setFavorite(old, true, limits: limits, now: Date(timeIntervalSince1970: 2))
        try await store.setFavorite(old, false, limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.card(old) == nil)
    }

    @Test func withFavoriteClearsExpiresAtOnDTO() async throws {
        let store = try ClipboardStore(url: nil)
        let settings = ResolvedAppSettings(captureMode: .deleteAfter(minutes: 60))
        guard case .committed(let id) = await ingest(store, snapshot("secret-ish", settings: settings)) else {
            Issue.record("not committed")
            return
        }
        let card = try #require(try await store.card(id))
        #expect(card.expiresAt != nil)
        #expect(card.isFavorite == false)
        let favored = card.withFavorite(true)
        #expect(favored.isFavorite)
        #expect(favored.expiresAt == nil, "favor-on clears expiry like ClipboardStore.setFavorite")
        let unfavored = favored.withFavorite(false)
        #expect(!unfavored.isFavorite)
        #expect(unfavored.expiresAt == nil, "unfavorite does not restore expiresAt (§6)")
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
