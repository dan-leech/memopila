import Foundation
import MemopilaCore
import SwiftData

/// The only owner of history mutations (PLAN §3.5, §6, §7.1).
///
/// Every call uses a fresh `ModelContext`, so payload bytes inserted or loaded by one call are released
/// when it returns (§7.3) and no call sees stale cached rows. Checks and the save run in one actor
/// call without suspension points, so ingests, deletes and edits are serialized.
public actor ClipboardStore {
    private let container: ModelContainer
    private var staleGuard = IngestStaleGuard()

    /// Persistent store at `url`; `nil` keeps everything in memory (tests).
    public init(url: URL?) throws {
        let schema = Schema(StoreSchema.models)
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    /// `~/Library/Application Support/Memopila/History.store`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Memopila/History.store")
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    // MARK: - Ingest (§3.5, §4, §6)

    public func ingest(
        _ snapshot: OwnedSnapshot,
        readerSeq: Int,
        enrichment: IngestEnrichment,
        limits: RetentionLimits
    ) -> IngestResult {
        if staleGuard.isStale(contentHash: snapshot.contentHash, readerSeq: readerSeq) { return .dropped }
        let context = makeContext()
        let observation = CaptureObservation(
            observedAt: snapshot.observedAt,
            sourceAppBundleID: snapshot.identity.bundleID,
            sourceAppName: enrichment.sourceAppName,
            sourceURL: snapshot.sourceURL,
            retentionMinutes: snapshot.settings.retentionMinutes
        )
        do {
            if let existing = try fetchRecord(withHash: snapshot.contentHash, in: context) {
                apply(DedupMerge.merge(metadata(of: existing), with: observation), to: existing)
                existing.searchText = Self.searchText(for: existing)
                try context.save()
                return .merged(existing.id)
            }

            let candidates = try retentionCandidates(in: context)
            let plan = RetentionPlanner.planIngest(
                existing: candidates,
                newPayloadBytes: snapshot.payloadSizeBytes,
                maxCount: limits.maxCount,
                maxStorageBytes: limits.maxStorageBytes
            )
            guard case .accept(let victims) = plan else {
                return .rejected("History storage is full (\(ByteCountFormatter.string(fromByteCount: Int64(limits.maxStorageBytes), countStyle: .memory)) without favorites).")
            }

            let record = ClipboardRecord(
                displayTypeRaw: snapshot.displayType.rawValue,
                firstCopiedAt: snapshot.observedAt,
                lastCopiedAt: snapshot.observedAt,
                copyCount: 1,
                contentHash: snapshot.contentHash,
                hashSchemeVersion: MCS1.hashSchemeVersion,
                storageFormatVersion: PayloadIntegrity.storageFormatVersion,
                payloadSizeBytes: snapshot.payloadSizeBytes
            )
            apply(DedupMerge.newRecord(from: observation), to: record)
            record.cardPreview = enrichment.cardPreview
            record.textIndex = enrichment.textIndex
            record.textLength = enrichment.textLength
            record.pixelWidth = enrichment.pixelWidth
            record.pixelHeight = enrichment.pixelHeight
            record.colorHex = enrichment.colorHex
            record.filePaths = enrichment.filePaths
            record.skippedTypes = snapshot.skippedTypes.map(\.rawValue)
            record.ocrStateRaw = Self.initialRecognitionState(for: snapshot).rawValue
            record.searchText = Self.searchText(for: record)
            context.insert(record)
            insertRepresentations(of: snapshot.items, for: record, in: context)
            if let thumbnail = enrichment.thumbnail {
                let model = RecordThumbnail(data: thumbnail)
                context.insert(model)
                model.record = record
                record.hasThumbnail = true
            }
            try deleteRecords(ids: victims, in: context)
            try context.save()
            return .committed(record.id)
        } catch {
            context.rollback()
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Reads (§7.1)

    public func page(_ query: HistoryQuery, offset: Int, limit: Int) throws -> [HistoryCard] {
        let context = makeContext()
        var descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: try predicate(for: query, in: context),
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = Self.cardProperties
        return try context.fetch(descriptor).map(Self.card)
    }

    public func count(_ query: HistoryQuery) throws -> Int {
        let context = makeContext()
        return try context.fetchCount(FetchDescriptor(predicate: try predicate(for: query, in: context)))
    }

    public func card(_ id: UUID) throws -> HistoryCard? {
        let context = makeContext()
        return try fetchRecord(id, in: context).map(Self.card)
    }

    public func details(_ id: UUID, maxTextScalars: Int = 20_000) throws -> RecordDetails? {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return nil }
        let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        let items = Self.items(from: rows)
        let text = RichText.plainText(of: items).map { TextDecoding.prefix($0, maxScalars: maxTextScalars) }
        let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == id }))
        return RecordDetails(
            card: Self.card(record),
            text: text,
            recognizedText: record.ocrText,
            storedTypes: rows.map(\.uti),
            sourceWindowTitle: record.sourceWindowTitle,
            collectionIDs: Set(tags.map(\.collectionID))
        )
    }

    public func thumbnail(for id: UUID) throws -> Data? {
        let context = makeContext()
        return try fetchRecord(id, in: context)?.thumbnail?.data
    }

    /// Verified payload for Restore (§3.5 integrity). Throws `StoreError.unreadable` on any mismatch.
    public func payload(for id: UUID) throws -> RestorePayload {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { throw StoreError.notFound }
        let rows = record.representations.map { row in
            StoredRepresentation(
                itemIndex: row.itemIndex,
                repIndex: row.repIndex,
                type: PasteboardType(row.uti),
                payload: row.kindRaw == 1 ? .filePaths(row.paths ?? []) : .bytes(row.bytes ?? Data()),
                byteCount: row.byteCount
            )
        }
        do {
            let items = try PayloadIntegrity.verify(
                rows: rows,
                payloadSizeBytes: record.payloadSizeBytes,
                contentHash: record.contentHash,
                hashSchemeVersion: record.hashSchemeVersion,
                storageFormatVersion: record.storageFormatVersion
            )
            return RestorePayload(items: items, sourceBundleID: record.lastSourceAppBundleID, text: RichText.plainText(of: items))
        } catch {
            throw StoreError.unreadable("\(error)")
        }
    }

    public func apps() throws -> [AppSummary] {
        let context = makeContext()
        var descriptor = FetchDescriptor<ClipboardRecord>(sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.lastSourceAppBundleID, \.lastSourceAppName, \.lastCopiedAt]
        var summaries: [String: AppSummary] = [:]
        var order: [String] = []
        for record in try context.fetch(descriptor) {
            guard let bundleID = record.lastSourceAppBundleID else { continue }
            if let summary = summaries[bundleID] {
                summaries[bundleID] = AppSummary(bundleID: bundleID, name: summary.name, count: summary.count + 1, lastCopiedAt: summary.lastCopiedAt)
            } else {
                summaries[bundleID] = AppSummary(bundleID: bundleID, name: record.lastSourceAppName, count: 1, lastCopiedAt: record.lastCopiedAt)
                order.append(bundleID)
            }
        }
        return order.compactMap { summaries[$0] }
    }

    public func displayTypes() throws -> [DisplayType] {
        let context = makeContext()
        var descriptor = FetchDescriptor<ClipboardRecord>()
        descriptor.propertiesToFetch = [\.displayTypeRaw]
        let present = Set(try context.fetch(descriptor).compactMap { DisplayType(rawValue: $0.displayTypeRaw) })
        return DisplayType.allCases.filter(present.contains)
    }

    // MARK: - Mutations

    /// After a confirmed Restore: move to the top, `copyCount` unchanged (§3.4).
    public func markUsed(_ id: UUID, at date: Date) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        record.lastCopiedAt = max(record.lastCopiedAt, date)
        try context.save()
    }

    public func delete(_ ids: [UUID], opSeq: Int) throws {
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))
        for record in records { staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq) }
        try saveOrRollback(context) { try deleteRecords(ids: ids, in: context) }
    }

    public func clear(_ scope: ClearScope, opSeq: Int) throws {
        let context = makeContext()
        let descriptor: FetchDescriptor<ClipboardRecord>
        switch scope {
        case .all: descriptor = FetchDescriptor()
        case .nonFavorites: descriptor = FetchDescriptor(predicate: #Predicate { !$0.isFavorite })
        }
        var idsDescriptor = descriptor
        idsDescriptor.propertiesToFetch = [\.id]
        let ids = try context.fetch(idsDescriptor).map(\.id)
        try saveOrRollback(context) { try deleteRecords(ids: ids, in: context) }
        staleGuard.recordClear(opSeq: opSeq)
    }

    /// Favorite on / off with the count cap and age rules of §6.
    public func setFavorite(_ id: UUID, _ isFavorite: Bool, limits: RetentionLimits, now: Date) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        try saveOrRollback(context) {
            record.isFavorite = isFavorite
            guard !isFavorite else {
                record.expiresAt = nil
                return
            }
            let candidates = try retentionCandidates(in: context)
            var victims = RetentionPlanner.planUnfavorite(id, existing: candidates, maxCount: limits.maxCount)
            victims += RetentionPlanner.planAge(existing: candidates, now: now, maxAge: limits.maxAge).filter { !victims.contains($0) }
            try deleteRecords(ids: victims, in: context)
        }
    }

    public func rename(_ id: UUID, title: String?) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        record.customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        record.searchText = Self.searchText(for: record)
        try context.save()
    }

    public func setCodeLanguage(_ id: UUID, _ language: String?) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        record.codeLanguage = language
        try context.save()
    }

    /// Edit text (§3.6): in-place replacement with one plain-text item, merge on collision.
    public func editText(_ id: UUID, text: String, opSeq: Int, maxBytes: Int) throws -> EditResult {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return .rejected("The record no longer exists.") }
        guard let type = DisplayType(rawValue: record.displayTypeRaw), [.text, .richText, .url].contains(type) else {
            return .rejected("Only text records can be edited.")
        }
        guard !text.isEmpty else { return .rejected("The text is empty.") }
        let data = Data(text.utf8)
        guard data.count <= maxBytes else { return .rejected("The text is larger than the item size limit.") }

        let items = [CanonicalItem([.bytes(.utf8PlainText, data)])]
        let hash = MCS1.contentHash(of: items)
        guard hash != record.contentHash else { return .updated }
        staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq)

        if let survivor = try fetchRecord(withHash: hash, in: context), survivor.id != id {
            try saveOrRollback(context) {
                apply(DedupMerge.mergeEdited(metadata(of: record), into: metadata(of: survivor)), to: survivor)
                if survivor.customTitle == nil { survivor.customTitle = record.customTitle }
                survivor.searchText = Self.searchText(for: survivor)
                let survivorID = survivor.id
                let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == id }))
                let existing = Set(try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == survivorID })).map(\.collectionID))
                for tag in tags where !existing.contains(tag.collectionID) {
                    context.insert(RecordTag(recordID: survivorID, collectionID: tag.collectionID))
                }
                try deleteRecords(ids: [id], in: context)
            }
            return .merged(into: survivor.id)
        }

        try saveOrRollback(context) {
            for row in record.representations { context.delete(row) }
            record.representations = []
            insertRepresentations(of: items, for: record, in: context)
            record.contentHash = hash
            record.payloadSizeBytes = data.count
            record.displayTypeRaw = TextDecoding.isSingleWebURL(text) ? DisplayType.url.rawValue : DisplayType.text.rawValue
            record.cardPreview = TextDecoding.prefix(text, maxScalars: IngestEnrichment.cardPreviewScalars)
            record.textIndex = TextDecoding.prefix(text, maxScalars: IngestEnrichment.searchScalars)
            record.textLength = text.count
            record.editedAt = Date()
            record.skippedTypes = []
            record.searchText = Self.searchText(for: record)
        }
        return .updated
    }

    /// Age, short retention and count cap (§6). Returns when the next expiry is due.
    @discardableResult
    public func applyRetention(limits: RetentionLimits, now: Date) throws -> Date? {
        let context = makeContext()
        let candidates = try retentionCandidates(in: context)
        var victims = RetentionPlanner.planAge(existing: candidates, now: now, maxAge: limits.maxAge)
        victims += RetentionPlanner.planExpired(existing: candidates, now: now)
        victims += RetentionPlanner.planCountShrink(existing: candidates, maxCount: limits.maxCount)
        let unique = Array(Set(victims))
        if !unique.isEmpty {
            try saveOrRollback(context) { try deleteRecords(ids: unique, in: context) }
        }
        return RetentionPlanner.nextExpiry(existing: candidates.filter { !unique.contains($0.id) })
    }

    /// *Also delete N existing items from <App>* (§5.1): non-favorites only.
    @discardableResult
    public func deleteRecords(fromApp bundleID: String, opSeq: Int) throws -> Int {
        let context = makeContext()
        let app: String? = bundleID
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.lastSourceAppBundleID == app && !$0.isFavorite }
        ))
        for record in records { staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq) }
        let ids = records.map(\.id)
        try saveOrRollback(context) { try deleteRecords(ids: ids, in: context) }
        return ids.count
    }

    public func countRecords(fromApp bundleID: String) throws -> Int {
        let context = makeContext()
        let app: String? = bundleID
        return try context.fetchCount(FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.lastSourceAppBundleID == app && !$0.isFavorite }
        ))
    }

    // MARK: - Collections (§8.2)

    public func collections() throws -> [CollectionSummary] {
        let context = makeContext()
        let collections = try context.fetch(FetchDescriptor<CollectionModel>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
        let tags = try context.fetch(FetchDescriptor<RecordTag>())
        let counts = Dictionary(grouping: tags, by: \.collectionID).mapValues(\.count)
        return collections.map { CollectionSummary(id: $0.id, name: $0.name, count: counts[$0.id] ?? 0) }
    }

    @discardableResult
    public func createCollection(named name: String) throws -> UUID {
        let context = makeContext()
        let count = try context.fetchCount(FetchDescriptor<CollectionModel>())
        let collection = CollectionModel(name: name, sortOrder: count)
        context.insert(collection)
        try context.save()
        return collection.id
    }

    public func renameCollection(_ id: UUID, to name: String) throws {
        let context = makeContext()
        guard let collection = try context.fetch(FetchDescriptor<CollectionModel>(predicate: #Predicate { $0.id == id })).first else { return }
        collection.name = name
        try context.save()
    }

    /// Deletes the collection and its memberships; records stay (§6).
    public func deleteCollection(_ id: UUID) throws {
        let context = makeContext()
        try saveOrRollback(context) {
            try context.delete(model: RecordTag.self, where: #Predicate { $0.collectionID == id })
            try context.delete(model: CollectionModel.self, where: #Predicate { $0.id == id })
        }
    }

    public func setMembership(record recordID: UUID, collection collectionID: UUID, isMember: Bool) throws {
        let context = makeContext()
        let existing = try context.fetch(FetchDescriptor<RecordTag>(
            predicate: #Predicate { $0.recordID == recordID && $0.collectionID == collectionID }
        ))
        if isMember, existing.isEmpty {
            context.insert(RecordTag(recordID: recordID, collectionID: collectionID))
        } else if !isMember {
            existing.forEach { context.delete($0) }
        }
        try context.save()
    }

    // MARK: - Text recognition (§3.8)

    public func recognitionCandidates(limit: Int) throws -> [UUID] {
        let context = makeContext()
        let pending = RecognitionState.pending.rawValue
        var descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.ocrStateRaw == pending },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map(\.id)
    }

    /// The stored image or PDF for recognition.
    public func recognitionInput(for id: UUID) throws -> (data: Data, isPDF: Bool)? {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return nil }
        let imageTypes = Set(PasteboardType.rasterImagePreference.map(\.rawValue)).union([PasteboardType.pdf.rawValue])
        guard let row = record.representations.first(where: { imageTypes.contains($0.uti) }), let data = row.bytes else { return nil }
        return (data, row.uti == PasteboardType.pdf.rawValue)
    }

    /// Metadata-only update: timestamps, position and hash stay (§3.8).
    public func setRecognizedText(_ id: UUID, text: String?, state: RecognitionState) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        record.ocrText = text.map { TextDecoding.prefix($0, maxScalars: IngestEnrichment.searchScalars) }
        record.ocrStateRaw = state.rawValue
        record.searchText = Self.searchText(for: record)
        try context.save()
    }

    public func setRecognitionState(forApp bundleID: String?, enabled: Bool) throws {
        guard enabled else { return }
        let context = makeContext()
        let off = RecognitionState.off.rawValue
        let image = DisplayType.image.rawValue, pdf = DisplayType.pdf.rawValue
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.ocrStateRaw == off && ($0.displayTypeRaw == image || $0.displayTypeRaw == pdf) }
        ))
        for record in records where bundleID == nil || record.lastSourceAppBundleID == bundleID {
            record.ocrStateRaw = RecognitionState.pending.rawValue
        }
        try context.save()
    }

    // MARK: - Helpers

    private static let cardProperties: [PartialKeyPath<ClipboardRecord>] = [
        \.id, \.displayTypeRaw, \.cardPreview, \.customTitle, \.textLength, \.pixelWidth, \.pixelHeight,
        \.filePaths, \.colorHex, \.payloadSizeBytes, \.firstCopiedAt, \.lastCopiedAt, \.copyCount, \.isFavorite,
        \.lastSourceAppBundleID, \.lastSourceAppName, \.sourceURL, \.editedAt, \.expiresAt, \.ocrStateRaw,
        \.skippedTypes, \.hasThumbnail, \.codeLanguage,
    ]

    private static func card(_ record: ClipboardRecord) -> HistoryCard {
        HistoryCard(
            id: record.id,
            displayType: DisplayType(rawValue: record.displayTypeRaw) ?? .mixed,
            preview: record.cardPreview,
            customTitle: record.customTitle,
            textLength: record.textLength,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            filePaths: record.filePaths,
            colorHex: record.colorHex,
            payloadSizeBytes: record.payloadSizeBytes,
            firstCopiedAt: record.firstCopiedAt,
            lastCopiedAt: record.lastCopiedAt,
            copyCount: record.copyCount,
            isFavorite: record.isFavorite,
            sourceAppBundleID: record.lastSourceAppBundleID,
            sourceAppName: record.lastSourceAppName,
            sourceURL: record.sourceURL,
            isEdited: record.editedAt != nil,
            expiresAt: record.expiresAt,
            hasRecognizedText: record.ocrStateRaw == RecognitionState.done.rawValue,
            skippedTypes: record.skippedTypes,
            hasThumbnail: record.hasThumbnail,
            codeLanguage: record.codeLanguage
        )
    }

    private static func initialRecognitionState(for snapshot: OwnedSnapshot) -> RecognitionState {
        guard snapshot.settings.recognizeText, [.image, .pdf].contains(snapshot.displayType) else { return .off }
        return .pending
    }

    /// The single search field (§8.6).
    static func searchText(for record: ClipboardRecord) -> String {
        let fileNames = record.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let parts: [String?] = [
            record.customTitle, record.textIndex, record.ocrText, record.lastSourceAppName,
            record.sourceURL, record.sourceWindowTitle, fileNames.isEmpty ? nil : fileNames.joined(separator: "\n"),
        ]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func items(from rows: [PayloadRepresentation]) -> [CanonicalItem] {
        var items: [CanonicalItem] = []
        for row in rows {
            while items.count <= row.itemIndex { items.append(CanonicalItem([])) }
            let payload: CanonicalRepresentation.Payload = row.kindRaw == 1 ? .filePaths(row.paths ?? []) : .bytes(row.bytes ?? Data())
            items[row.itemIndex].representations.append(CanonicalRepresentation(type: PasteboardType(row.uti), payload: payload))
        }
        return items
    }

    private func insertRepresentations(of items: [CanonicalItem], for record: ClipboardRecord, in context: ModelContext) {
        for row in StoredRepresentation.rows(for: items) {
            let model: PayloadRepresentation
            switch row.payload {
            case .bytes(let data):
                model = PayloadRepresentation(itemIndex: row.itemIndex, repIndex: row.repIndex, uti: row.type.rawValue, kindRaw: 0, bytes: data, paths: nil, byteCount: row.byteCount)
            case .filePaths(let paths):
                model = PayloadRepresentation(itemIndex: row.itemIndex, repIndex: row.repIndex, uti: row.type.rawValue, kindRaw: 1, bytes: nil, paths: paths, byteCount: row.byteCount)
            }
            context.insert(model)
            model.record = record
        }
    }

    private func fetchRecord(_ id: UUID, in context: ModelContext) throws -> ClipboardRecord? {
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchRecord(withHash hash: String, in context: ModelContext) throws -> ClipboardRecord? {
        let scheme = MCS1.hashSchemeVersion
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.contentHash == hash && $0.hashSchemeVersion == scheme })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func retentionCandidates(in context: ModelContext) throws -> [RetentionCandidate] {
        var descriptor = FetchDescriptor<ClipboardRecord>()
        descriptor.propertiesToFetch = [\.id, \.isFavorite, \.lastCopiedAt, \.payloadSizeBytes, \.expiresAt]
        return try context.fetch(descriptor).map {
            RetentionCandidate(id: $0.id, isFavorite: $0.isFavorite, lastCopiedAt: $0.lastCopiedAt, payloadSizeBytes: $0.payloadSizeBytes, expiresAt: $0.expiresAt)
        }
    }

    /// Records, their representations and thumbnails (cascade) and memberships, in the caller's transaction.
    private func deleteRecords(ids: [UUID], in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))
        records.forEach { context.delete($0) }
        try context.delete(model: RecordTag.self, where: #Predicate { ids.contains($0.recordID) })
    }

    private func saveOrRollback(_ context: ModelContext, _ changes: () throws -> Void) throws {
        do {
            try changes()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func predicate(for query: HistoryQuery, in context: ModelContext) throws -> Predicate<ClipboardRecord>? {
        var result: Predicate<ClipboardRecord>?
        func and(_ next: Predicate<ClipboardRecord>) {
            if let current = result {
                result = #Predicate { current.evaluate($0) && next.evaluate($0) }
            } else {
                result = next
            }
        }
        switch query.scope {
        case .all:
            break
        case .favorites:
            and(#Predicate { $0.isFavorite })
        case .app(let bundleID):
            let app: String? = bundleID
            and(#Predicate { $0.lastSourceAppBundleID == app })
        case .type(let type):
            let raw = type.rawValue
            and(#Predicate { $0.displayTypeRaw == raw })
        case .collection(let collectionID):
            let ids = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.collectionID == collectionID })).map(\.recordID)
            and(#Predicate { ids.contains($0.id) })
        }
        for word in query.words {
            and(#Predicate { $0.searchText.localizedStandardContains(word) })
        }
        return result
    }

    private func metadata(of record: ClipboardRecord) -> RecordMetadata {
        RecordMetadata(
            firstCopiedAt: record.firstCopiedAt,
            lastCopiedAt: record.lastCopiedAt,
            copyCount: record.copyCount,
            isFavorite: record.isFavorite,
            lastSourceAppBundleID: record.lastSourceAppBundleID,
            lastSourceAppName: record.lastSourceAppName,
            sourceURL: record.sourceURL,
            sourceWindowTitle: record.sourceWindowTitle,
            expiresAt: record.expiresAt
        )
    }

    private func apply(_ metadata: RecordMetadata, to record: ClipboardRecord) {
        record.firstCopiedAt = metadata.firstCopiedAt
        record.lastCopiedAt = metadata.lastCopiedAt
        record.copyCount = metadata.copyCount
        record.isFavorite = metadata.isFavorite
        record.lastSourceAppBundleID = metadata.lastSourceAppBundleID
        record.lastSourceAppName = metadata.lastSourceAppName
        record.sourceURL = metadata.sourceURL
        record.sourceWindowTitle = metadata.sourceWindowTitle
        record.expiresAt = metadata.expiresAt
    }
}
