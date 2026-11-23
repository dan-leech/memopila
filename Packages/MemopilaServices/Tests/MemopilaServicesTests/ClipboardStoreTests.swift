import AppKit
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

    @Test func should_not_evict_protectingRecords_on_ingest_or_retention() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxCount: 1)
        guard case .committed(let protected) = await ingest(store, snapshot("keep", at: 1), limits: limits) else { return }
        let result = await store.ingest(
            snapshot("new", at: 2),
            readerSeq: 0,
            enrichment: IngestEnrichment.make(for: [CanonicalItem([.bytes(.utf8PlainText, Data("new".utf8))])], sourceAppName: "Editor"),
            limits: limits,
            protectingRecords: [protected]
        )
        guard case .committed = result else { Issue.record("\(result)"); return }
        #expect(try await store.card(protected) != nil, "Undo/open-editor protect must survive quota ingest")
        try await store.applyRetention(
            limits: limits, now: Date(timeIntervalSince1970: 10_000), protectingRecords: [protected]
        )
        #expect(try await store.card(protected) != nil, "protect must survive age/count retention")
    }

    @Test func should_not_evict_protectingRecords_on_unfavorite() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxCount: 1)
        guard case .committed(let kept) = await ingest(store, snapshot("kept", at: 1), limits: limits) else { return }
        // Second ingest would normally evict `kept` — protect it so both exist for the unfavorite case.
        let favResult = await store.ingest(
            snapshot("fav", at: 2),
            readerSeq: 0,
            enrichment: IngestEnrichment.make(for: [CanonicalItem([.bytes(.utf8PlainText, Data("fav".utf8))])], sourceAppName: "Editor"),
            limits: limits,
            protectingRecords: [kept]
        )
        guard case .committed(let fav) = favResult else { Issue.record("\(favResult)"); return }
        try await store.setFavorite(fav, true, limits: limits, now: Date(timeIntervalSince1970: 3))
        // Unfavorite at maxCount would otherwise delete `kept` as a count-cap victim.
        let deleted = try await store.setFavorite(
            fav, false, limits: limits, now: Date(timeIntervalSince1970: 4), protectingRecords: [kept]
        )
        #expect(!deleted.contains(kept))
        #expect(try await store.card(kept) != nil)
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

    @Test func reclassifyRichTextDoesNotDemoteColourUTI() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#112233"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#112233", items: items),
            enrichment: IngestEnrichment(cardPreview: "#112233", colorHex: "#112233", sourceAppName: "Editor")
        )
        // Text-only classify of utf8 would yield .text and leave a colour-UTI type-lag orphan.
        try await store.corruptColorDisplayTypeForTesting(id, to: .richText)
        #expect(try await store.reclassifyRichText() == 1)
        #expect(try await store.card(id)?.displayType == .color)
        #expect(try await store.payload(for: id).items == items)
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

    @Test func unfavoritingAnOldStackMemberKeepsIt() async throws {
        // Stack membership pins (§6) — confirmUnfavorite must not count these as "will delete".
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let old) = await ingest(store, snapshot("old", at: 1), limits: limits) else { return }
        try await store.setFavorite(old, true, limits: limits, now: Date(timeIntervalSince1970: 2))
        _ = try await store.createStack(title: "Pin", recordIDs: [old])
        try await store.setFavorite(old, false, limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.card(old) != nil)
        #expect(try await store.card(old)?.isFavorite == false)
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

    @Test func stackPinsAndClearsExpiresAt() async throws {
        let store = try ClipboardStore(url: nil)
        let settings = ResolvedAppSettings(captureMode: .deleteAfter(minutes: 60))
        guard case .committed(let a) = await ingest(store, snapshot("a", settings: settings)) else { Issue.record("a"); return }
        guard case .committed(let b) = await ingest(store, snapshot("b", at: 2_000, settings: settings)) else { Issue.record("b"); return }
        #expect(try await store.card(a)?.expiresAt != nil)
        let stackID = try await store.createStack(title: "Demo", recordIDs: [a, b])
        #expect(try await store.card(a)?.expiresAt == nil)
        #expect(try await store.card(b)?.expiresAt == nil)
        let card = try #require(try await store.stack(stackID))
        #expect(card.memberIDs == [a, b])
        #expect(card.title == "Demo")

        let (others, kept) = try await store.ids(HistoryQuery())
        #expect(others.isEmpty)
        #expect(Set(kept) == Set([a, b]))

        try await store.clear(.nonFavorites, opSeq: 1)
        #expect(try await store.count(HistoryQuery()) == 2, "stack members survive Clear non-favorites")

        try await store.delete([a], opSeq: 2)
        #expect(try await store.stackMemberIDs(stackID) == [b], "delete cascades StackMember")

        try await store.removeStackMember(stackID, recordID: b)
        #expect(try await store.stack(stackID) == nil, "last member removal drops the stack shell")
        #expect(try await store.stackMemberIDs(stackID).isEmpty)
        // Leaving the last stack does not restore expiresAt (§6).
        #expect(try await store.card(b)?.expiresAt == nil)
    }

    @Test func should_delete_stack_shell_when_last_member_record_deleted() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("solo", at: 1)) else { return }
        let stackID = try await store.createStack(title: "Solo", recordIDs: [a])
        try await store.delete([a], opSeq: 1)
        #expect(try await store.stack(stackID) == nil)
        // Intentionally empty stacks (created with no members) are not swept by unrelated deletes.
        let emptyID = try await store.createStack(title: "Empty", recordIDs: [])
        guard case .committed(let other) = await ingest(store, snapshot("other", at: 2)) else { return }
        try await store.delete([other], opSeq: 2)
        #expect(try await store.stack(emptyID) != nil)
    }

    @Test func should_keep_payload_readable_across_editText_external_swap() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "memopila-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(url: directory.appending(path: "History.store"))
        // Large enough to land in `_EXTERNAL_DATA` so the staged-swap path is exercised.
        let original = String(repeating: "a", count: 256 * 1024)
        let edited = String(repeating: "b", count: 256 * 1024)
        guard case .committed(let id) = await ingest(store, snapshot(original)) else {
            Issue.record("not committed")
            return
        }
        #expect(try await store.editText(id, text: edited, opSeq: 1, maxBytes: edited.utf8.count + 1) == .updated)
        #expect(try await store.payload(for: id).text == edited)
    }

    @Test func mergeRetargetsStackMembers() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("one")) else { Issue.record("a"); return }
        guard case .committed(let b) = await ingest(store, snapshot("two", at: 2_000)) else { Issue.record("b"); return }
        let stackID = try await store.createStack(title: "S", recordIDs: [a, b])
        // Edit a into the same text as b → merge into b, retarget membership.
        let result = try await store.editText(a, text: "two", opSeq: 1, maxBytes: 1_000_000)
        #expect(result == .merged(into: b))
        #expect(try await store.stackMemberIDs(stackID) == [b])
    }

    @Test func should_keep_stack_membership_when_edit_merges_into_existing_record() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("draft")),
              case .committed(let b) = await ingest(store, snapshot("final", at: 2_000)) else { return }
        // Survivor b is NOT in the stack — retarget must insert, not mutate-then-cascade-lose.
        let stackID = try await store.createStack(title: "S", recordIDs: [a])
        let other = try await store.createStack(title: "T", recordIDs: [a])
        #expect(try await store.editText(a, text: "final", opSeq: 1, maxBytes: 1_000) == .merged(into: b))
        #expect(try await store.stackMemberIDs(stackID) == [b])
        #expect(try await store.stackMemberIDs(other) == [b])
        #expect(try await store.stackedRecordIDs().contains(b))
    }

    @Test func should_keep_pinboard_position_when_edit_merges_into_existing_record() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let x) = await ingest(store, snapshot("x", at: 1)),
              case .committed(let draft) = await ingest(store, snapshot("draft", at: 2)),
              case .committed(let y) = await ingest(store, snapshot("y", at: 3)),
              case .committed(let keeper) = await ingest(store, snapshot("final", at: 4)) else { return }
        try await store.setFavorite(x, true, limits: limits, now: Date(timeIntervalSince1970: 10))
        try await store.setFavorite(draft, true, limits: limits, now: Date(timeIntervalSince1970: 11))
        try await store.setFavorite(y, true, limits: limits, now: Date(timeIntervalSince1970: 12))
        try await store.reorderFavorites([.record(x), .record(draft), .record(y)])
        #expect(try await store.editText(draft, text: "final", opSeq: 1, maxBytes: 1_000) == .merged(into: keeper))
        #expect(
            try await store.pinboardEntries(HistoryQuery(scope: .favorites)).map(\.id)
                == [.record(x), .record(keeper), .record(y)]
        )
    }

    @Test func should_duplicate_stack_member_after_source_as_independent_record() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("alpha", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("beta", at: 2)) else { return }
        let stackID = try await store.createStack(title: "S", recordIDs: [a, b])
        let copy = try await store.duplicateInStack(recordID: a, stackID: stackID)
        #expect(copy != a)
        #expect(try await store.stackMemberIDs(stackID) == [a, copy, b])
        #expect(try await store.payload(for: a).text == "alpha")
        #expect(try await store.payload(for: copy).text == "alpha")
        _ = try await store.editText(copy, text: "alpha-edited", opSeq: 1, maxBytes: 1_000)
        #expect(try await store.payload(for: a).text == "alpha")
        #expect(try await store.payload(for: copy).text == "alpha-edited")
    }

    @Test func stackScopePagesInPositionOrder() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("first", at: 3_000)) else { Issue.record("a"); return }
        guard case .committed(let b) = await ingest(store, snapshot("second", at: 2_000)) else { Issue.record("b"); return }
        guard case .committed(let c) = await ingest(store, snapshot("third", at: 1_000)) else { Issue.record("c"); return }
        // UI order a→b→c despite lastCopiedAt ranking c, b, a.
        let stackID = try await store.createStack(title: "Ordered", recordIDs: [a, b, c])
        let query = HistoryQuery(scope: .stack(stackID))
        #expect(try await store.page(query, offset: 0, limit: 10).map(\.id) == [a, b, c])
        #expect(try await store.page(query, offset: 1, limit: 1).map(\.id) == [b])
        #expect(try await store.count(query) == 3)
        #expect(try await store.stacks(query).isEmpty, "stack drill-down never nests stack cards")
        try await store.reorderStackMembers(stackID, orderedIDs: [c, a, b])
        #expect(try await store.page(query, offset: 0, limit: 10).map(\.id) == [c, a, b])
    }

    @Test func should_reorder_stack_members_without_dropping_unlisted() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("b", at: 2)),
              case .committed(let c) = await ingest(store, snapshot("c", at: 3)) else { return }
        let stackID = try await store.createStack(title: "S", recordIDs: [a, b, c])
        // Visible reorder a↔c while b is "hidden" from the UI list — splice must keep b.
        try await store.reorderStackMembers(stackID, orderedIDs: [c, a])
        #expect(try await store.stackMemberIDs(stackID) == [c, b, a])
        try await store.appendStackMember(stackID, recordID: a) // already a member — no-op
        #expect(try await store.stackMemberIDs(stackID) == [c, b, a])
        guard case .committed(let d) = await ingest(store, snapshot("d", at: 4)) else { return }
        try await store.appendStackMember(stackID, recordID: d)
        // [c,b,a,d] + visible [a,c] → splice listed slots only → [a,b,c,d]
        try await store.reorderStackMembers(stackID, orderedIDs: [a, c])
        #expect(try await store.stackMemberIDs(stackID) == [a, b, c, d])
    }

    @Test func should_append_after_position_gaps_without_collision() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("b", at: 2)),
              case .committed(let c) = await ingest(store, snapshot("c", at: 3)) else { return }
        let stackID = try await store.createStack(title: "S", recordIDs: [a, b, c])
        try await store.removeStackMember(stackID, recordID: b)
        guard case .committed(let d) = await ingest(store, snapshot("d", at: 4)) else { return }
        try await store.appendStackMember(stackID, recordID: d)
        #expect(try await store.stackMemberIDs(stackID) == [a, c, d])
        let copy = try await store.duplicateInStack(recordID: a, stackID: stackID)
        #expect(try await store.stackMemberIDs(stackID) == [a, copy, c, d])
    }

    @Test func stackScopeEmptyAndFiltered() async throws {
        let store = try ClipboardStore(url: nil)
        let stackID = try await store.createStack(title: "Empty", recordIDs: [])
        let empty = HistoryQuery(scope: .stack(stackID))
        #expect(try await store.page(empty, offset: 0, limit: 10).isEmpty)
        #expect(try await store.count(empty) == 0)

        guard case .committed(let text) = await ingest(store, snapshot("hello")) else { Issue.record("text"); return }
        let png = try #require(TestImages.png(width: 8, height: 8))
        guard case .committed(let image) = await ingest(
            store,
            snapshot("", at: 2_000, items: [CanonicalItem([.bytes(.png, png)])])
        ) else { Issue.record("image"); return }
        let filled = try await store.createStack(title: "Mixed", recordIDs: [text, image])
        var onlyText = HistoryQuery(scope: .stack(filled), kinds: [.text])
        #expect(try await store.page(onlyText, offset: 0, limit: 10).map(\.id) == [text])
        onlyText.search = "nope"
        #expect(try await store.count(onlyText) == 0)
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

    /// Retention eviction must not share a save with new `@Attribute(.externalStorage)` inserts —
    /// that race logged "Failed to clone … .interim" in production.
    @Test func should_evict_large_external_payloads_and_keep_survivors_readable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "memopila-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(url: directory.appending(path: "History.store"))
        // Above SwiftData's typical inline threshold so blobs land in `_EXTERNAL_DATA`.
        let chunk = 256 * 1024
        let limits = RetentionLimits(maxCount: 2, maxStorageBytes: 50 * FormatPolicy.mebibyte)
        for i in 0..<4 {
            var bytes = Data(repeating: UInt8(i + 1), count: chunk)
            bytes[0] = UInt8(i)
            let items = [CanonicalItem([.bytes("com.example.big", bytes)])]
            let result = await ingest(store, snapshot("", at: TimeInterval(1_000 + i), items: items), limits: limits)
            guard case .committed = result else {
                Issue.record("ingest \(i) → \(result)")
                return
            }
        }
        let cards = try await store.page(HistoryQuery(), offset: 0, limit: 10)
        #expect(cards.count == 2)
        for card in cards {
            let payload = try await store.payload(for: card.id)
            #expect(payload.items.first?.representations.first?.byteCount == chunk)
        }
    }

    // MARK: Pinboard order (Favorites / Collections)

    @Test func should_keep_favorites_order_when_choose_bumps_lastCopiedAt() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let older) = await ingest(store, snapshot("older", at: 1)),
              case .committed(let newer) = await ingest(store, snapshot("newer", at: 2)) else { return }
        try await store.setFavorite(older, true, limits: limits, now: Date(timeIntervalSince1970: 3))
        try await store.setFavorite(newer, true, limits: limits, now: Date(timeIntervalSince1970: 4))
        // Newer favorite joins at front.
        let before = try await store.pinboardEntries(HistoryQuery(scope: .favorites))
        #expect(before.map(\.id) == [.record(newer), .record(older)])
        try await store.markUsed(older, at: Date(timeIntervalSince1970: 100))
        #expect(try await store.page(HistoryQuery(), offset: 0, limit: 10).map(\.id).first == older)
        let after = try await store.pinboardEntries(HistoryQuery(scope: .favorites))
        #expect(after.map(\.id) == [.record(newer), .record(older)], "Choose must not reshuffle Favorites")
    }

    @Test func should_insert_new_favorite_at_front_of_slots() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("b", at: 2)) else { return }
        try await store.setFavorite(a, true, limits: limits, now: Date(timeIntervalSince1970: 3))
        try await store.setFavorite(b, true, limits: limits, now: Date(timeIntervalSince1970: 4))
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .favorites)).map(\.id) == [.record(b), .record(a)])
    }

    @Test func should_reorder_collection_persisting_record_and_stack_positions() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("b", at: 2)) else { return }
        let stackID = try await store.createStack(title: "S", recordIDs: [a])
        let collection = try await store.createCollection(named: "Board")
        try await store.setMembership(record: b, collection: collection, isMember: true)
        try await store.setStackMembership(stack: stackID, collection: collection, isMember: true)
        // Latest join at front: stack, then b.
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .collection(collection))).map(\.id)
            == [.stack(stackID), .record(b)])
        try await store.reorderCollection(collection, [.record(b), .stack(stackID)])
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .collection(collection))).map(\.id)
            == [.record(b), .stack(stackID)])
        // Splice must keep unlisted membership — c stays even when omitted from the visible order.
        guard case .committed(let c) = await ingest(store, snapshot("c", at: 3)) else { return }
        try await store.setMembership(record: c, collection: collection, isMember: true)
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .collection(collection))).map(\.id)
            == [.record(c), .record(b), .stack(stackID)])
        try await store.reorderCollection(collection, [.stack(stackID), .record(b)])
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .collection(collection))).map(\.id)
            == [.record(c), .stack(stackID), .record(b)])
    }

    @Test func should_ignore_since_in_favorites_and_collection_scopes() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let old) = await ingest(store, snapshot("old", at: 1)) else { return }
        try await store.setFavorite(old, true, limits: limits, now: Date(timeIntervalSince1970: 2))
        let collection = try await store.createCollection(named: "C")
        try await store.setMembership(record: old, collection: collection, isMember: true)
        let since = Date(timeIntervalSince1970: 1_000)
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .favorites, since: since)).count == 1)
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .collection(collection), since: since)).count == 1)
        #expect(try await store.count(HistoryQuery(scope: .favorites, since: since)) == 0, "page/count still use since; pinboard feed ignores it")
    }

    @Test func should_retarget_favorite_slot_on_dedup_merge() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let keeper) = await ingest(store, snapshot("final", at: 1)),
              case .committed(let draft) = await ingest(store, snapshot("draft", at: 2)) else { return }
        try await store.setFavorite(draft, true, limits: limits, now: Date(timeIntervalSince1970: 3))
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .favorites)).map(\.id) == [.record(draft)])
        #expect(try await store.editText(draft, text: "final", opSeq: 1, maxBytes: 1_000) == .merged(into: keeper))
        let board = try await store.pinboardEntries(HistoryQuery(scope: .favorites))
        #expect(board.map(\.id) == [.record(keeper)])
        #expect(try await store.card(keeper)?.isFavorite == true)
    }

    @Test func should_seed_positions_from_recency_on_migration() async throws {
        // In-memory V3 store: favoriting creates slots; reorderFavorites rewrites them; seed path
        // reconciles when slots are missing relative to isFavorite (covered via setFavorite + reorder).
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 10)),
              case .committed(let b) = await ingest(store, snapshot("b", at: 20)) else { return }
        try await store.setFavorite(a, true, limits: limits, now: Date(timeIntervalSince1970: 30))
        try await store.setFavorite(b, true, limits: limits, now: Date(timeIntervalSince1970: 40))
        try await store.reorderFavorites([.record(a), .record(b)])
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .favorites)).map(\.id) == [.record(a), .record(b)])
        try await store.markUsed(b, at: Date(timeIntervalSince1970: 99))
        #expect(try await store.pinboardEntries(HistoryQuery(scope: .favorites)).map(\.id) == [.record(a), .record(b)])
    }

    // MARK: useCount arrange + stack age retention (§8.2 / §6)

    @Test func should_bump_useCount_on_choose_not_copyCount() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("x", at: 1)) else { return }
        #expect(try await store.card(id)?.useCount == 0)
        #expect(try await store.card(id)?.copyCount == 1)
        try await store.markUsed(id, at: Date(timeIntervalSince1970: 10))
        let card = try #require(try await store.card(id))
        #expect(card.useCount == 1)
        #expect(card.copyCount == 1)
        #expect(card.lastCopiedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func should_page_mostUsed_by_useCount_then_recency() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("b", at: 2)),
              case .committed(let c) = await ingest(store, snapshot("c", at: 3)) else { return }
        try await store.markUsed(a, at: Date(timeIntervalSince1970: 10))
        try await store.markUsed(a, at: Date(timeIntervalSince1970: 11))
        try await store.markUsed(c, at: Date(timeIntervalSince1970: 12))
        let recent = try await store.page(HistoryQuery(sort: .recent), offset: 0, limit: 10)
        #expect(recent.map(\.id) == [c, a, b])
        let used = try await store.page(HistoryQuery(sort: .mostUsed), offset: 0, limit: 10)
        #expect(used.map(\.id) == [a, c, b])
    }

    @Test func should_sum_useCount_on_edit_merge() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("draft", at: 1)),
              case .committed(let b) = await ingest(store, snapshot("final", at: 2)) else { return }
        try await store.markUsed(a, at: Date(timeIntervalSince1970: 3))
        try await store.markUsed(a, at: Date(timeIntervalSince1970: 4))
        try await store.markUsed(b, at: Date(timeIntervalSince1970: 5))
        #expect(try await store.editText(a, text: "final", opSeq: 1, maxBytes: 1_000) == .merged(into: b))
        #expect(try await store.card(b)?.useCount == 3)
    }

    @Test func should_start_duplicateInStack_at_useCount_zero() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("alpha", at: 1)) else { return }
        try await store.markUsed(a, at: Date(timeIntervalSince1970: 2))
        let stackID = try await store.createStack(title: "S", recordIDs: [a], now: Date(timeIntervalSince1970: 3))
        let copy = try await store.duplicateInStack(recordID: a, stackID: stackID, now: Date(timeIntervalSince1970: 4))
        #expect(try await store.card(copy)?.useCount == 0)
        #expect(try await store.card(a)?.useCount == 1)
    }

    @Test func should_unfavorite_age_delete_only_that_record_not_all_aged() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxCount: 1_000, maxAge: 100)
        guard case .committed(let oldFav) = await ingest(store, snapshot("old-fav", at: 1), limits: limits),
              case .committed(let otherAged) = await ingest(store, snapshot("other", at: 2), limits: limits) else { return }
        try await store.setFavorite(oldFav, true, limits: limits, now: Date(timeIntervalSince1970: 3))
        // otherAged stays non-favorite and aged — unfavorite must not sweep it.
        let deleted = try await store.setFavorite(oldFav, false, limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(deleted == Set<UUID>([oldFav]))
        #expect(try await store.card(oldFav) == nil)
        #expect(try await store.card(otherAged) != nil)
    }

    @Test func should_fetch_stack_by_id_outside_recent_cap() async throws {
        let store = try ClipboardStore(url: nil)
        var oldest: UUID?
        for i in 0..<5 {
            guard case .committed(let id) = await ingest(store, snapshot("m\(i)", at: TimeInterval(i + 1))) else { return }
            let stackID = try await store.createStack(
                title: "S\(i)", recordIDs: [id], now: Date(timeIntervalSince1970: TimeInterval(i + 1))
            )
            if i == 0 { oldest = stackID }
            try await store.markStackUsed(stackID, at: Date(timeIntervalSince1970: TimeInterval(100 + i)))
        }
        let id = try #require(oldest)
        #expect(try await store.stack(id)?.title == "S0")
        let snap = try #require(try await store.stackSnapshot(id))
        #expect(snap.stack.id == id)
        #expect(!snap.order.isEmpty)
    }

    @Test func should_age_delete_stale_non_favorite_stack_and_sole_members() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1), limits: limits) else { return }
        let stackID = try await store.createStack(title: "Stale", recordIDs: [a], now: Date(timeIntervalSince1970: 1))
        try await store.applyRetention(limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.stack(stackID) == nil)
        #expect(try await store.card(a) == nil)
    }

    @Test func should_spare_favorite_stack_past_age_cutoff() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1), limits: limits) else { return }
        let stackID = try await store.createStack(title: "Keep", recordIDs: [a], now: Date(timeIntervalSince1970: 1))
        try await store.setStackFavorite(stackID, true)
        try await store.applyRetention(limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.stack(stackID) != nil)
        #expect(try await store.card(a) != nil)
    }

    @Test func should_not_age_delete_stack_right_after_it_is_unfavorited() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1), limits: limits) else { return }
        let stackID = try await store.createStack(title: "Was favorite", recordIDs: [a], now: Date(timeIntervalSince1970: 1))
        try await store.setStackFavorite(stackID, true)
        try await store.setStackFavorite(stackID, false)
        try await store.applyRetention(limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.stack(stackID) != nil)
        #expect(try await store.card(a) != nil)
    }

    @Test func should_spare_protected_open_stack_from_age_delete() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1), limits: limits) else { return }
        let stackID = try await store.createStack(title: "Open", recordIDs: [a], now: Date(timeIntervalSince1970: 1))
        try await store.applyRetention(
            limits: limits, now: Date(timeIntervalSince1970: 1_000), protectingStacks: [stackID]
        )
        #expect(try await store.stack(stackID) != nil)
        #expect(try await store.card(a) != nil)
    }

    @Test func should_not_tag_record_into_deleted_collection() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let a) = await ingest(store, snapshot("a", at: 1)) else { return }
        let collection = try await store.createCollection(named: "Gone")
        try await store.deleteCollection(collection)
        try await store.setMembership(record: a, collection: collection, isMember: true)
        #expect(try await store.memberships(of: [a])[a] == nil)
    }

    @Test func should_keep_member_still_in_fresh_stack_when_other_ages_out() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let shared) = await ingest(store, snapshot("shared", at: 1), limits: limits),
              case .committed(let onlyFresh) = await ingest(store, snapshot("fresh-only", at: 2), limits: limits)
        else { return }
        let staleID = try await store.createStack(
            title: "Stale",
            recordIDs: [shared],
            now: Date(timeIntervalSince1970: 1)
        )
        let freshID = try await store.createStack(
            title: "Fresh",
            recordIDs: [shared, onlyFresh],
            now: Date(timeIntervalSince1970: 950)
        )
        try await store.applyRetention(limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.stack(staleID) == nil)
        #expect(try await store.stack(freshID) != nil)
        #expect(try await store.card(shared) != nil)
        #expect(try await store.card(onlyFresh) != nil)
    }

    @Test func should_keep_favorite_member_when_stack_ages_out() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits(maxAge: 100)
        guard case .committed(let fav) = await ingest(store, snapshot("fav", at: 1), limits: limits),
              case .committed(let free) = await ingest(store, snapshot("free", at: 1), limits: limits)
        else { return }
        try await store.setFavorite(fav, true, limits: limits, now: Date(timeIntervalSince1970: 2))
        let stackID = try await store.createStack(
            title: "Stale",
            recordIDs: [fav, free],
            now: Date(timeIntervalSince1970: 1)
        )
        try await store.applyRetention(limits: limits, now: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.stack(stackID) == nil)
        #expect(try await store.card(fav) != nil)
        #expect(try await store.card(free) == nil)
    }

    @Test func should_keep_favorites_pinboard_order_when_useCount_changes() async throws {
        let store = try ClipboardStore(url: nil)
        let limits = RetentionLimits()
        guard case .committed(let older) = await ingest(store, snapshot("older", at: 1)),
              case .committed(let newer) = await ingest(store, snapshot("newer", at: 2)) else { return }
        try await store.setFavorite(older, true, limits: limits, now: Date(timeIntervalSince1970: 3))
        try await store.setFavorite(newer, true, limits: limits, now: Date(timeIntervalSince1970: 4))
        try await store.markUsed(older, at: Date(timeIntervalSince1970: 100))
        try await store.markUsed(older, at: Date(timeIntervalSince1970: 101))
        #expect(try await store.page(HistoryQuery(sort: .mostUsed), offset: 0, limit: 10).map(\.id).first == older)
        #expect(
            try await store.pinboardEntries(HistoryQuery(scope: .favorites)).map(\.id)
                == [.record(newer), .record(older)],
            "Choose / useCount must not reshuffle Favorites"
        )
    }

    @Test func applyColorPasteFormatChangesPreviewAndMergesOnCollision() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(red: 0, green: 255, blue: 0))
        let hexItems = PasteboardWriter.colorItems(values, textFormat: .hex)
        let rgbItems = PasteboardWriter.colorItems(values, textFormat: .rgb)
        guard case .committed(let hexID) = await ingest(store, snapshot("#00FF00", items: hexItems)),
              case .committed(let rgbID) = await ingest(store, snapshot("rgb", at: 1_001, items: rgbItems))
        else { Issue.record("colour ingest"); return }

        #expect(try await store.applyColorPasteFormat(hexID, format: .hex, opSeq: 1) == .updated)
        #expect(try await store.card(hexID)?.preview == "#00FF00")

        #expect(try await store.applyColorPasteFormat(hexID, format: .rgb, opSeq: 2) == .merged(into: rgbID))
        #expect(try await store.card(hexID) == nil)
        #expect(try await store.card(rgbID)?.preview == "rgb(0, 255, 0)")
    }

    @Test func applyColorPasteFormatNoopsWhenAlreadyCanonical() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#FF0000"))
        let items = PasteboardWriter.colorItems(values, textFormat: .hex)
        guard case .committed(let id) = await ingest(store, snapshot("red", items: items)) else {
            Issue.record("colour ingest"); return
        }
        let before = try await store.payload(for: id).items
        #expect(try await store.applyColorPasteFormat(id, format: .hex, opSeq: 1) == .updated)
        #expect(try await store.payload(for: id).items == before, "canonical HEX must not churn")
    }

    @Test func applyColorPasteFormatCanonicalizesLegacyOrderWhenCSSMatches() async throws {
        let store = try ClipboardStore(url: nil)
        // Text before colour UTI — same CSS, different framing than colorItems → must rewrite.
        let colorData = try #require(
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacy = [CanonicalItem([
            .bytes(.utf8PlainText, Data("#FF0000".utf8)),
            .bytes(.color, colorData),
        ])]
        guard case .committed(let id) = await ingest(store, snapshot("red", items: legacy)) else {
            Issue.record("colour ingest"); return
        }
        #expect(try await store.applyColorPasteFormat(id, format: .hex, opSeq: 1) == .updated)
        #expect(try await store.payload(for: id).items == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#FF0000"))))
    }

    @Test func detailsHealsNilColorHexAndEmptyPreview() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values, textFormat: .hsl)
        // Pre-fix row: empty caches (ingest now fills hex from payload).
        let id = try await store.plantColorForkForTesting(
            snapshot("hsl", items: items),
            enrichment: IngestEnrichment(sourceAppName: "Editor")
        )
        #expect(try await store.card(id)?.colorHex == nil)
        #expect(try await store.card(id)?.preview == "")
        let details = try #require(try await store.details(id, maxTextScalars: 0))
        #expect(details.card.colorHex == "#AABBCC")
        #expect(ColorPasteFormat.matching(details.card.preview) == .hsl)
        #expect(try await store.card(id)?.colorHex == "#AABBCC", "heal must persist for the grid")
    }

    @Test func ingestCanonicalizesNonNormalizedColourWithoutCallerNormalize() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        #expect(MCS1.contentHash(of: legacyItems) != MCS1.contentHash(of: canonical))
        // Caller passes raw snapshot (pre-normalize hash) — Store must canonicalize before address.
        let bare = IngestEnrichment(cardPreview: legacyHex, sourceAppName: "Editor")
        guard case .committed(let id) = await store.ingest(
            snapshot(legacyHex, items: legacyItems), readerSeq: 0, enrichment: bare, limits: RetentionLimits()
        ) else { Issue.record("colour ingest"); return }
        #expect(try await store.payload(for: id).items == canonical)
        #expect(try await store.card(id)?.colorHex == legacyHex)
        #expect(
            await store.ingest(
                snapshot(legacyHex, at: 2_000, items: canonical), readerSeq: 1, enrichment: bare, limits: RetentionLimits()
            ) == .merged(id)
        )
        #expect(try await store.count(HistoryQuery()) == 1)
    }

    @Test func ensureCanonicalColorRecordUpgradesLegacyPayload() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#334455"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let hex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(hex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: hex)))
        let enrichment = IngestEnrichment(cardPreview: hex, colorHex: hex, sourceAppName: "Editor")
        let id = try await store.plantColorForkForTesting(snapshot(hex, items: legacyItems), enrichment: enrichment)
        #expect(try await store.payload(for: id).items == legacyItems)
        let ensured = try await store.ensureCanonicalColorRecord(id, opSeq: 1)
        #expect(ensured.id == id)
        #expect(ensured.items == canonical)
        #expect(try await store.payload(for: id).items == canonical)
    }

    @Test func coalesceDuplicateColorRecordsMergesSameHexAndFormat() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        // Soft-merge would collapse these on ingest — plant forks the way a pre-fix store did.
        let enrichment = IngestEnrichment(cardPreview: legacyHex, colorHex: legacyHex, sourceAppName: "Editor")
        _ = try await store.plantColorForkForTesting(snapshot(legacyHex, items: legacyItems), enrichment: enrichment)
        _ = try await store.plantColorForkForTesting(
            snapshot(legacyHex, at: 2_000, items: canonical), enrichment: enrichment
        )
        #expect(try await store.count(HistoryQuery()) == 2)
        #expect(try await store.coalesceDuplicateColorRecords(opSeq: 1) == 1)
        #expect(try await store.count(HistoryQuery()) == 1)
        let survivor = try #require(try await store.page(HistoryQuery(), offset: 0, limit: 1).first)
        #expect(try await store.payload(for: survivor.id).items == canonical)
        #expect(try await store.coalesceDuplicateColorRecords(opSeq: 2) == 0)
    }

    @Test func softMergeUsesPayloadHexWhenEnrichmentColorHexNil() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        let bare = IngestEnrichment(cardPreview: legacyHex, sourceAppName: "Editor")
        guard case .committed(let id) = await store.ingest(
            snapshot(legacyHex, items: legacyItems), readerSeq: 0, enrichment: bare, limits: RetentionLimits()
        ) else { Issue.record("legacy colour ingest"); return }
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        // Inbound enrichment also lacks colorHex — identity must come from the colour UTI.
        #expect(
            await store.ingest(
                snapshot(legacyHex, at: 2_000, items: canonical), readerSeq: 1, enrichment: bare, limits: RetentionLimits()
            ) == .merged(id)
        )
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.payload(for: id).items == canonical)
    }

    @Test func softMergeMatchesWrongCasedStoredColorHex() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        #expect(MCS1.contentHash(of: legacyItems) != MCS1.contentHash(of: canonical))
        // Pre-fix row kept a lower-cased cache; identity must match via payload HEX, not cache case.
        let lowerCache = legacyHex.lowercased()
        let id = try await store.plantColorForkForTesting(
            snapshot(lowerCache, items: legacyItems),
            enrichment: IngestEnrichment(cardPreview: lowerCache, colorHex: lowerCache, sourceAppName: "Editor")
        )
        #expect(try await store.card(id)?.colorHex == lowerCache)
        let upper = IngestEnrichment.make(for: canonical, sourceAppName: "Editor")
        #expect(upper.colorHex == legacyHex)
        #expect(
            await store.ingest(
                snapshot(legacyHex, at: 2_000, items: canonical), readerSeq: 1, enrichment: upper, limits: RetentionLimits()
            ) == .merged(id)
        )
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(id)?.colorHex == legacyHex)
        #expect(try await store.payload(for: id).items == canonical)
    }

    @Test func applyColorPasteFormatSoftMergesLegacyFork() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#334455"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let hex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(hex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: hex)))
        let enrichment = IngestEnrichment(cardPreview: hex, colorHex: hex, sourceAppName: "Editor")
        let legacyID = try await store.plantColorForkForTesting(
            snapshot(hex, items: legacyItems), enrichment: enrichment
        )
        let canonicalID = try await store.plantColorForkForTesting(
            snapshot(hex, at: 2_000, items: canonical), enrichment: enrichment
        )
        #expect(legacyID != canonicalID)
        #expect(try await store.count(HistoryQuery()) == 2)
        #expect(try await store.applyColorPasteFormat(legacyID, format: .hex, opSeq: 1) == .merged(into: canonicalID))
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.payload(for: canonicalID).items == canonical)
    }

    @Test func backfillMissingColorMetadataFillsNilHexAndEmptyPreview() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values, textFormat: .rgb)
        // Empty preview + nil colorHex: format picker would seed HEX and Choose would rewrite RGB.
        let id = try await store.plantColorForkForTesting(
            snapshot("rgb", items: items),
            enrichment: IngestEnrichment(sourceAppName: "Editor")
        )
        #expect(try await store.card(id)?.colorHex == nil)
        #expect(try await store.card(id)?.preview == "")
        #expect(try await store.backfillMissingColorMetadata() == 1)
        #expect(try await store.card(id)?.colorHex == "#AABBCC")
        #expect(try await store.card(id)?.preview == "rgb(170, 187, 204)")
        #expect(ColorPasteFormat.matching(try #require(try await store.card(id)?.preview)) == .rgb)
        #expect(try await store.backfillMissingColorMetadata() == 0)
    }

    @Test func hardMergeBackfillsNilColorHexFromEnrichment() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00FF00"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#00FF00", items: items),
            enrichment: IngestEnrichment(cardPreview: "#00FF00", sourceAppName: "Editor")
        )
        #expect(try await store.card(id)?.colorHex == nil)

        let full = IngestEnrichment.make(for: items, sourceAppName: "Editor")
        #expect(full.colorHex == "#00FF00")
        #expect(
            await store.ingest(
                snapshot("#00FF00", at: 2_000, items: items), readerSeq: 0, enrichment: full, limits: RetentionLimits()
            ) == .merged(id)
        )
        #expect(try await store.card(id)?.colorHex == "#00FF00")
        #expect(try await store.card(id)?.copyCount == 2)
    }

    @Test func applyColorPasteFormatReadsColourFromPayloadWhenColorHexNil() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#112233"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#112233", items: items),
            enrichment: IngestEnrichment(cardPreview: "#112233", sourceAppName: "Editor")
        )
        #expect(try await store.applyColorPasteFormat(id, format: .rgb, opSeq: 1) == .updated)
        #expect(try await store.card(id)?.colorHex == "#112233")
        #expect(try await store.card(id)?.preview == "rgb(17, 34, 51)")
    }

    @Test func healOverwritesStaleColorHexAndPreviewFromPayload() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values, textFormat: .rgb)
        // Stale caches that disagree with the UTI — cache-first heal used to leave them forever.
        let id = try await store.plantColorForkForTesting(
            snapshot("rgb", items: items),
            enrichment: IngestEnrichment(cardPreview: "#FF0000", colorHex: "#FF0000", sourceAppName: "Editor")
        )
        #expect(try await store.card(id)?.colorHex == "#FF0000")
        #expect(try await store.backfillMissingColorMetadata() == 1)
        #expect(try await store.card(id)?.colorHex == "#AABBCC")
        #expect(try await store.card(id)?.preview == "rgb(170, 187, 204)")
        #expect(try await store.backfillMissingColorMetadata() == 0)
    }

    @Test func healPromotesStaleDisplayTypeOnColourUTIOrphan() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values, textFormat: .rgb)
        let id = try await store.plantColorForkForTesting(
            snapshot("rgb", items: items),
            enrichment: IngestEnrichment(cardPreview: "rgb(170, 187, 204)", colorHex: "#AABBCC", sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(id, to: .text)
        #expect(try await store.card(id)?.displayType == .text)
        #expect(try await store.card(id)?.looksLikeColor == true)
        #expect(try await store.backfillMissingColorMetadata() == 1)
        #expect(try await store.card(id)?.displayType == .color)
        #expect(try await store.backfillMissingColorMetadata() == 0)
    }

    @Test func healAndDetailsRecoverEmptyStoredTypesWithColourUTIRows() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values, textFormat: .rgb)
        let id = try await store.plantColorForkForTesting(
            snapshot("rgb", items: items),
            enrichment: IngestEnrichment(cardPreview: "rgb(170, 187, 204)", colorHex: "#AABBCC", sourceAppName: "Editor")
        )
        // Caches wiped — only payload rows still say colour. looksLikeColor is false until heal.
        try await store.corruptColorCachesForTesting(id, displayType: .text, storedTypes: [], colorHex: nil)
        #expect(try await store.card(id)?.looksLikeColor == false)
        #expect(try await store.backfillMissingColorMetadata() == 1)
        let card = try #require(try await store.card(id))
        #expect(card.displayType == .color)
        #expect(card.looksLikeColor == true)
        #expect(card.colorHex == "#AABBCC")
        #expect(card.preview == "rgb(170, 187, 204)")
        #expect(card.storedTypes.contains(PasteboardType.color.rawValue))
    }

    @Test func looksLikeColorWhenOnlyColorHexCacheRemains() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#AABBCC", items: items),
            enrichment: IngestEnrichment(cardPreview: "#AABBCC", colorHex: "#AABBCC", sourceAppName: "Editor")
        )
        try await store.corruptColorCachesForTesting(id, displayType: .text, storedTypes: [], colorHex: "#AABBCC")
        let card = try #require(try await store.card(id))
        #expect(card.displayType == .text)
        #expect(card.storedTypes.isEmpty)
        #expect(card.looksLikeColor == true, "colorHex alone must keep colour face / drag types")
        #expect(card.hasText == false)
    }

    @Test func hardMergeRestoresEmptyStoredTypesOnColour() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00FF00"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#00FF00", items: items),
            enrichment: IngestEnrichment(cardPreview: "#00FF00", colorHex: "#00FF00", sourceAppName: "Editor")
        )
        try await store.corruptColorCachesForTesting(id, displayType: .color, storedTypes: [], colorHex: "#00FF00")
        #expect(try await store.card(id)?.storedTypes.isEmpty == true)
        let full = IngestEnrichment.make(for: items, sourceAppName: "Editor")
        #expect(
            await store.ingest(
                snapshot("#00FF00", at: 2_000, items: items), readerSeq: 0, enrichment: full, limits: RetentionLimits()
            ) == .merged(id)
        )
        #expect(try await store.card(id)?.storedTypes.contains(PasteboardType.color.rawValue) == true)
    }

    @Test func detailsHealsColourWhenCardCachesHideUTI() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#112233"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#112233", items: items),
            enrichment: IngestEnrichment(cardPreview: "#112233", colorHex: "#112233", sourceAppName: "Editor")
        )
        try await store.corruptColorCachesForTesting(id, displayType: .text, storedTypes: [], colorHex: nil)
        let details = try #require(try await store.details(id, maxTextScalars: 0))
        #expect(details.card.displayType == .color)
        #expect(details.card.looksLikeColor == true)
        #expect(details.card.colorHex == "#112233")
    }

    @Test func colorsFilterIncludesTypeLagOrphanWithColorHex() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#AABBCC", items: items),
            enrichment: IngestEnrichment(cardPreview: "#AABBCC", colorHex: "#AABBCC", sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(id, to: .text)
        #expect(try await store.card(id)?.displayType == .text)
        #expect(try await store.count(HistoryQuery(kinds: [.color])) == 1)
        #expect(try await store.page(HistoryQuery(kinds: [.color]), offset: 0, limit: 10).map(\.id) == [id])
        #expect(try await store.count(HistoryQuery(scope: .type(.color))) == 1)
    }

    @Test func colorsFilterIncludesStackWithTypeLagColourMember() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values)
        let colorID = try await store.plantColorForkForTesting(
            snapshot("#AABBCC", items: items),
            enrichment: IngestEnrichment(cardPreview: "#AABBCC", colorHex: "#AABBCC", sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(colorID, to: .text)
        let stackID = try await store.createStack(title: "Swatches", recordIDs: [colorID])
        let stacks = try await store.stacks(HistoryQuery(kinds: [.color]))
        #expect(stacks.map(\.id) == [stackID], "stack Colors filter must use colorHex, not displayType alone")
        #expect(try await store.stacks(HistoryQuery(scope: .type(.color))).map(\.id) == [stackID])
    }

    @Test func displayTypesFindsColourUTIOrphanWithoutColorHex() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#CCDDEE"))
        let items = PasteboardWriter.colorItems(values)
        // Nil caches + stale displayType — only colour UTI in storedTypes says this is a colour.
        let id = try await store.plantColorForkForTesting(
            snapshot("colour", items: items),
            enrichment: IngestEnrichment(sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(id, to: .text)
        #expect(try await store.card(id)?.colorHex == nil)
        #expect(try await store.card(id)?.displayType == .text)
        #expect(try await store.card(id)?.looksLikeColor == true)
        // Colors chip must appear; filter itself needs colorHex/displayType (Predicate can't see UTI).
        #expect(try await store.displayTypes().contains(.color))
        #expect(try await store.backfillMissingColorMetadata() == 1)
        #expect(try await store.count(HistoryQuery(kinds: [.color])) == 1)
    }

    @Test func softMergeFindsColourUTIOrphanWithoutColorHex() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#CCDDEE"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let hex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(hex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: hex)))
        let orphanID = try await store.plantColorForkForTesting(
            snapshot(hex, items: legacyItems),
            enrichment: IngestEnrichment(sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(orphanID, to: .text)
        #expect(try await store.card(orphanID)?.colorHex == nil)
        #expect(await ingest(store, snapshot(hex, at: 2_000, items: canonical)) == .merged(orphanID))
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(orphanID)?.displayType == .color)
    }

    @Test func coalesceFindsTypeLagOrphanWithColourUTI() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        let enrichment = IngestEnrichment(cardPreview: legacyHex, colorHex: legacyHex, sourceAppName: "Editor")
        let orphanID = try await store.plantColorForkForTesting(
            snapshot(legacyHex, items: legacyItems), enrichment: enrichment
        )
        try await store.corruptColorDisplayTypeForTesting(orphanID, to: .text)
        _ = try await store.plantColorForkForTesting(
            snapshot(legacyHex, at: 2_000, items: canonical), enrichment: enrichment
        )
        #expect(try await store.count(HistoryQuery()) == 2)
        #expect(try await store.coalesceDuplicateColorRecords(opSeq: 1) == 1)
        #expect(try await store.count(HistoryQuery()) == 1)
    }

    @Test func softMergeFindsTypeLagColorOrphan() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00BBCC"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let hex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(hex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: hex)))
        let orphanID = try await store.plantColorForkForTesting(
            snapshot(hex, items: legacyItems),
            enrichment: IngestEnrichment(cardPreview: hex, colorHex: hex, sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(orphanID, to: .text)
        #expect(try await store.card(orphanID)?.displayType == .text)
        // Same sRGB+format, different MCS1 — must soft-merge even when displayType lagged to .text.
        #expect(await ingest(store, snapshot(hex, at: 2_000, items: canonical)) == .merged(orphanID))
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(orphanID)?.displayType == .color)
        #expect(try await store.payload(for: orphanID).items == canonical)
    }

    @Test func applyColorPasteFormatAcceptsColorHexWhenDisplayTypeLags() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#112233"))
        let items = PasteboardWriter.colorItems(values, textFormat: .hex)
        let id = try await store.plantColorForkForTesting(
            snapshot("#112233", items: items),
            enrichment: IngestEnrichment(cardPreview: "#112233", colorHex: "#112233", sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(id, to: .text)
        #expect(try await store.applyColorPasteFormat(id, format: .rgb, opSeq: 1) == .updated)
        #expect(try await store.card(id)?.displayType == .color)
        #expect(try await store.card(id)?.preview == "rgb(17, 34, 51)")
    }

    @Test func duplicateInStackHealsColourCachesFromPayload() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#AABBCC"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#AABBCC", items: items),
            enrichment: IngestEnrichment(cardPreview: "#AABBCC", colorHex: "#AABBCC", sourceAppName: "Editor")
        )
        try await store.corruptColorCachesForTesting(id, displayType: .text, storedTypes: [], colorHex: nil)
        let stackID = try await store.createStack(title: "Dup", recordIDs: [id])
        let copyID = try await store.duplicateInStack(recordID: id, stackID: stackID)
        let copy = try #require(try await store.card(copyID))
        #expect(copy.displayType == .color)
        #expect(copy.colorHex == "#AABBCC")
        #expect(copy.storedTypes.contains(PasteboardType.color.rawValue))
    }

    @Test func applyColorPasteFormatIgnoresStaleColorHexCache() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#112233"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#112233", items: items),
            enrichment: IngestEnrichment(cardPreview: "#112233", colorHex: "#FF0000", sourceAppName: "Editor")
        )
        #expect(try await store.applyColorPasteFormat(id, format: .rgb, opSeq: 1) == .updated)
        #expect(try await store.card(id)?.colorHex == "#112233")
        #expect(try await store.card(id)?.preview == "rgb(17, 34, 51)")
        #expect(try await store.payload(for: id).items == PasteboardWriter.colorItems(values, textFormat: .rgb))
    }

    @Test func ensureCanonicalHealsDisplayTypeWhenPayloadAlreadyCanonical() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#445566"))
        let items = PasteboardWriter.colorItems(values)
        // Lone CSS text orphan: ensureCanonical must promote displayType even when it also
        // rewrites bytes (hash changes) — and when a twin already holds canonical bytes, merge.
        let textID = try await store.plantTextRecordForTesting("#445566")
        #expect(try await store.card(textID)?.displayType == .text)
        let ensured = try await store.ensureCanonicalColorRecord(textID, opSeq: 1)
        #expect(try await store.card(ensured.id)?.displayType == .color)
        #expect(ensured.items == items)
        #expect(try await store.payload(for: ensured.id).items == items)
        // Second call: bytes already canonical — hash-noop must still keep .color (displayType heal).
        let again = try await store.ensureCanonicalColorRecord(ensured.id, opSeq: 2)
        #expect(again.id == ensured.id)
        #expect(try await store.card(again.id)?.displayType == .color)
        #expect(again.items == items)
    }

    @Test func ensureCanonicalDoesNotRewriteChannelsFromStaleCache() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#334455"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let hex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(hex.utf8)),
        ])]
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: hex)))
        let id = try await store.plantColorForkForTesting(
            snapshot(hex, items: legacyItems),
            enrichment: IngestEnrichment(cardPreview: hex, colorHex: "#FF0000", sourceAppName: "Editor")
        )
        let ensured = try await store.ensureCanonicalColorRecord(id, opSeq: 1)
        #expect(ensured.items == canonical)
        #expect(try await store.card(id)?.colorHex == hex)
    }

    @Test func ingestAlignsWrongEnrichmentHexToPayload() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00AA11"))
        let items = PasteboardWriter.colorItems(values)
        let wrong = IngestEnrichment(cardPreview: "#FF0000", colorHex: "#FF0000", sourceAppName: "Editor")
        guard case .committed(let id) = await store.ingest(
            snapshot("#00AA11", items: items), readerSeq: 0, enrichment: wrong, limits: RetentionLimits()
        ) else { Issue.record("colour ingest"); return }
        #expect(try await store.card(id)?.colorHex == "#00AA11")
        #expect(try await store.card(id)?.preview == "#00AA11")
    }

    @Test func editTextPromotesLoneCSSToColorCard() async throws {
        let store = try ClipboardStore(url: nil)
        guard case .committed(let id) = await ingest(store, snapshot("note")) else {
            Issue.record("seed"); return
        }
        // Colour UTI archive exceeds a 1 KB text-only limit — use the normal item budget.
        #expect(try await store.editText(id, text: "#00AA11", opSeq: 1, maxBytes: 1_000_000) == .updated)
        let card = try #require(try await store.card(id))
        #expect(card.displayType == .color)
        #expect(card.colorHex == "#00AA11")
        #expect(try await store.payload(for: id).items == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#00AA11"))))
    }

    @Test func editTextRejectsColourUTIEvenWhenDisplayTypeLags() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00AA11"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#00AA11", items: items),
            enrichment: IngestEnrichment(cardPreview: "#00AA11", colorHex: "#00AA11", sourceAppName: "Editor")
        )
        try await store.corruptColorDisplayTypeForTesting(id, to: .text)
        #expect(try await store.card(id)?.displayType == .text)
        #expect(try await store.card(id)?.looksLikeColor == true)
        let result = try await store.editText(id, text: "not a colour", opSeq: 1, maxBytes: 1_000_000)
        #expect(result == .rejected("Colour records use the paste-format picker, not the text editor."))
        #expect(try await store.payload(for: id).items == items)
    }

    @Test func editTextRejectsColourUTIWhenAllCachesWiped() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00AA11"))
        let items = PasteboardWriter.colorItems(values)
        let id = try await store.plantColorForkForTesting(
            snapshot("#00AA11", items: items),
            enrichment: IngestEnrichment(cardPreview: "#00AA11", colorHex: "#00AA11", sourceAppName: "Editor")
        )
        // Same corruption as heal recovery — storedTypes alone used to let edit destroy MCS1.
        try await store.corruptColorCachesForTesting(id, displayType: .text, storedTypes: [], colorHex: nil)
        #expect(try await store.card(id)?.looksLikeColor == false)
        let result = try await store.editText(id, text: "not a colour", opSeq: 1, maxBytes: 1_000_000)
        #expect(result == .rejected("Colour records use the paste-format picker, not the text editor."))
        #expect(try await store.payload(for: id).items == items)
    }

    @Test func detailsDoesNotPromoteLoneCSSWithoutColourUTI() async throws {
        let store = try ClipboardStore(url: nil)
        let id = try await store.plantTextRecordForTesting("#112233")
        let details = try #require(try await store.details(id, maxTextScalars: 100))
        #expect(details.card.displayType == .text, "open-details heal must not flip face without colour bytes")
        #expect(details.card.colorHex == nil)
        #expect(try await store.payload(for: id).items == [CanonicalItem([.bytes(.utf8PlainText, Data("#112233".utf8))])])
    }

    @Test func promoteOrphanMaterializesColorFaceWithoutColourUTI() async throws {
        let store = try ClipboardStore(url: nil)
        let id = try await store.plantTextRecordForTesting("#445566")
        // Simulate older heal: displayType.color while payload is still plain CSS text.
        try await store.corruptColorCachesForTesting(id, displayType: .color, storedTypes: [], colorHex: "#445566")
        #expect(try await store.payload(for: id).items.contains { item in
            item.representations.contains { $0.type == .color }
        } == false)
        #expect(try await store.promoteOrphanCSSColorTextRecords(opSeq: 1) == 1)
        let card = try #require(try await store.card(id))
        #expect(card.displayType == .color)
        #expect(card.colorHex == "#445566")
        #expect(try await store.payload(for: id).items == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#445566"))))
    }

    @Test func payloadTextUsesTrimmedColorPastePlainText() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#112233"))
        let colorData = try #require(
            PasteboardWriter.colorItems(values, textFormat: .rgb)
                .flatMap(\.representations)
                .first(where: { $0.type == .color })?
                .bytes
        )
        // Leading/trailing whitespace on utf8 — TextDecoding keeps it; paste SSOT trims.
        let items = [CanonicalItem([
            .bytes(.color, colorData),
            .bytes(.utf8PlainText, Data("  rgb(17, 34, 51)  ".utf8)),
        ])]
        let id = try await store.plantColorForkForTesting(
            snapshot("rgb", items: items),
            enrichment: IngestEnrichment(cardPreview: "rgb(17, 34, 51)", colorHex: "#112233", sourceAppName: "Editor")
        )
        #expect(try await store.payload(for: id).text == "rgb(17, 34, 51)")
        #expect(try await store.details(id, maxTextScalars: 100)?.text == "rgb(17, 34, 51)")
        #expect(try await store.card(id)?.hasText == false, "colour cards are not text-action sources")
        #expect(try await store.card(id)?.looksLikeColor == true)
    }

    @Test func editTextSoftMergesPromotedCSSIntoExistingColor() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00AA11"))
        let colorItems = PasteboardWriter.colorItems(values)
        guard case .committed(let colorID) = await ingest(store, snapshot("#00AA11", items: colorItems)) else {
            Issue.record("color"); return
        }
        guard case .committed(let textID) = await ingest(store, snapshot("draft", at: 2_000)) else {
            Issue.record("text"); return
        }
        #expect(try await store.editText(textID, text: "#00AA11", opSeq: 1, maxBytes: 1_000_000) == .merged(into: colorID))
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(colorID)?.displayType == .color)
    }

    @Test func ingestSoftMergesColorIntoOrphanCSSText() async throws {
        let store = try ClipboardStore(url: nil)
        let orphanID = try await store.plantTextRecordForTesting("#00BBCC")
        #expect(try await store.card(orphanID)?.displayType == .text)
        let values = try #require(ColorValues(hex: "#00BBCC"))
        let colorItems = PasteboardWriter.colorItems(values)
        #expect(await ingest(store, snapshot("#00BBCC", at: 2_000, items: colorItems)) == .merged(orphanID))
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(orphanID)?.displayType == .color)
        #expect(try await store.payload(for: orphanID).items == colorItems)
    }

    @Test func ingestPromotesInsignificantRTFHexAndMergesWithColor() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let colorItems = PasteboardWriter.colorItems(values)
        guard case .committed(let colorID) = await ingest(store, snapshot("#F0BF00", items: colorItems)) else {
            Issue.record("color"); return
        }
        // Browser/Notes chrome: insignificant RTF + lone CSS — must not fork a second card.
        let rtf = Data(("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n"
            + "{\\colortbl;\\red255\\green255\\blue255;\\red0\\green0\\blue0;}\n"
            + "\\pard\\tx560\\pardirnatural\\partightenfactor0\n\n\\f0\\fs24 \\cf0 #F0BF00}").utf8)
        let chrome = [CanonicalItem([
            .bytes(.rtf, rtf),
            .bytes(.utf8PlainText, Data("#F0BF00".utf8)),
        ])]
        #expect(DisplayType.classify(chrome) == .text)
        #expect(await ingest(store, snapshot("#F0BF00", at: 2_000, items: chrome)) == .merged(colorID))
        #expect(try await store.count(HistoryQuery()) == 1)
    }

    @Test func promoteOrphanCSSColorTextRecordsMergesIntoColorTwin() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#00BBCC"))
        let colorItems = PasteboardWriter.colorItems(values)
        guard case .committed(let colorID) = await ingest(store, snapshot("#00BBCC", items: colorItems)) else {
            Issue.record("color"); return
        }
        let orphanID = try await store.plantTextRecordForTesting("#00BBCC", at: Date(timeIntervalSince1970: 2_000))
        #expect(try await store.count(HistoryQuery()) == 2)
        #expect(try await store.promoteOrphanCSSColorTextRecords(opSeq: 1) == 1)
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(orphanID) == nil)
        #expect(try await store.card(colorID)?.displayType == .color)
        #expect(try await store.promoteOrphanCSSColorTextRecords(opSeq: 2) == 0)
    }

    @Test func promoteOrphanCSSColorTextRecordsUpgradesLoneOrphan() async throws {
        let store = try ClipboardStore(url: nil)
        let orphanID = try await store.plantTextRecordForTesting("#112233")
        #expect(try await store.promoteOrphanCSSColorTextRecords(opSeq: 1) == 1)
        let card = try #require(try await store.card(orphanID))
        #expect(card.displayType == .color)
        #expect(card.colorHex == "#112233")
        #expect(try await store.payload(for: orphanID).items == PasteboardWriter.colorItems(try #require(ColorValues(hex: "#112233"))))
    }

    @Test func softMergeFindsColorWhenStoredColorHexIsNil() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        let legacyArchive = try #require(
            NSColor(
                calibratedRed: CGFloat(values.red) / 255,
                green: CGFloat(values.green) / 255,
                blue: CGFloat(values.blue) / 255,
                alpha: 1
            ).pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        let id = try await store.plantColorForkForTesting(
            snapshot(legacyHex, items: legacyItems),
            enrichment: IngestEnrichment(cardPreview: legacyHex, sourceAppName: "Editor")
        )
        #expect(try await store.card(id)?.colorHex == nil)

        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        let full = IngestEnrichment.make(for: canonical, sourceAppName: "Editor")
        #expect(
            await store.ingest(
                snapshot(legacyHex, at: 2_000, items: canonical), readerSeq: 1, enrichment: full, limits: RetentionLimits()
            ) == .merged(id)
        )
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(id)?.colorHex == legacyHex)
        #expect(try await store.payload(for: id).items == canonical)
    }

    @Test func ingestMergesColorWhenArchiveBytesDifferButHexAndFormatMatch() async throws {
        let store = try ClipboardStore(url: nil)
        let values = try #require(ColorValues(hex: "#F0BF00"))
        // Pre-canonical card: colour UTI whose archive is not `colorItems`, plus matching HEX text.
        let legacyArchive = try #require(
            NSColor(calibratedRed: CGFloat(values.red) / 255, green: CGFloat(values.green) / 255, blue: CGFloat(values.blue) / 255, alpha: 1)
                .pasteboardPropertyList(forType: .color) as? Data
        )
        let legacyHex = try #require(ColorHex.string(fromPasteboardColor: legacyArchive))
        let legacyItems = [CanonicalItem([
            .bytes(.color, legacyArchive),
            .bytes(.utf8PlainText, Data(legacyHex.utf8)),
        ])]
        guard case .committed(let id) = await ingest(store, snapshot(legacyHex, items: legacyItems)) else {
            Issue.record("legacy colour ingest"); return
        }
        let canonical = PasteboardWriter.colorItems(try #require(ColorValues(hex: legacyHex)))
        #expect(MCS1.contentHash(of: canonical) != MCS1.contentHash(of: legacyItems), "archives must differ so MCS1 misses")
        #expect(await ingest(store, snapshot(legacyHex, at: 2_000, items: canonical)) == .merged(id))
        #expect(try await store.count(HistoryQuery()) == 1)
        #expect(try await store.card(id)?.copyCount == 2)
        #expect(try await store.card(id)?.colorHex == legacyHex)
        // Soft-merge must upgrade legacy UTI so the next MCS1 hit is a hard dedup.
        #expect(try await store.payload(for: id).items == canonical)
        #expect(await ingest(store, snapshot(legacyHex, at: 3_000, items: canonical)) == .merged(id))
        #expect(try await store.card(id)?.copyCount == 3)
    }
}
