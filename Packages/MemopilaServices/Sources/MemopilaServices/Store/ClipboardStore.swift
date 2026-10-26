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

    /// Hard cap for Favorites / Collections pinboard feeds (not paged History).
    public static let maxPinboardEntries = 200

    /// Persistent store at `url`; `nil` keeps everything in memory (tests).
    public init(url: URL?) throws {
        let schema = Schema(versionedSchema: StoreSchemaV3.self)
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: [configuration])
        // Seed FavoriteSlot / tag positions once after V2→V3 (lightweight migrate leaves positions at 0).
        let context = ModelContext(container)
        try? Self.seedPinboardOrderIfNeeded(in: context)
        try? context.save()
    }

    /// Opens the store at `url`. If it cannot be opened, its files move to a dated folder next to
    /// it and an empty store starts in their place: history is set aside, never deleted (PLAN §7.2).
    /// When an empty store cannot be opened either, the files were not the problem (a full disk,
    /// no permission): they go back where they were and the first error is thrown (review finding:
    /// the history was set aside, and on the next launch nothing said where it went).
    public static func openRecovering(at url: URL, now: Date = Date()) throws -> (store: ClipboardStore, movedTo: URL?) {
        let firstError: any Error
        do {
            return (try ClipboardStore(url: url), nil)
        } catch {
            firstError = error
        }
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        // The store, its -shm / -wal journals and SwiftData's external storage folder.
        let name = url.lastPathComponent
        let support = ".\(url.deletingPathExtension().lastPathComponent)_SUPPORT"
        func storeFiles() -> [URL] {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.lastPathComponent.hasPrefix(name) || $0.lastPathComponent == support }
        }
        let originals = storeFiles()
        guard !originals.isEmpty else { throw firstError }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let backup = folder.appending(path: "Unreadable History \(formatter.string(from: now))", directoryHint: .isDirectory)
        var moved: [String] = []
        do {
            try manager.createDirectory(at: backup, withIntermediateDirectories: true)
            for file in originals {
                try manager.moveItem(at: file, to: backup.appending(path: file.lastPathComponent))
                moved.append(file.lastPathComponent)
            }
            return (try ClipboardStore(url: url), backup)
        } catch {
            // Files the failed open created in place of moved ones (or new ones) go first; originals
            // that were not moved stay untouched.
            let originalNames = Set(originals.map(\.lastPathComponent))
            for file in storeFiles() where moved.contains(file.lastPathComponent) || !originalNames.contains(file.lastPathComponent) {
                try? manager.removeItem(at: file)
            }
            for fileName in moved {
                try? manager.moveItem(at: backup.appending(path: fileName), to: folder.appending(path: fileName))
            }
            if ((try? manager.contentsOfDirectory(atPath: backup.path)) ?? []).isEmpty {
                try? manager.removeItem(at: backup)
            }
            throw firstError
        }
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
            sourceWindowTitle: snapshot.settings.recordSourcePage ? enrichment.sourceWindowTitle : nil,
            retentionMinutes: snapshot.settings.retentionMinutes
        )
        do {
            if let existing = try fetchRecord(withHash: snapshot.contentHash, in: context) {
                apply(DedupMerge.merge(try metadata(of: existing, in: context), with: observation), to: existing)
                if let kind = snapshot.sensitiveKind { existing.sensitiveKind = kind.rawValue }
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
            // Face the matched token when a secret is embedded in a larger paste (.env) so the
            // mask is not `DATABASE_URL=…` while the label names Stripe (§3.10).
            if let kind = snapshot.sensitiveKind,
               let text = RichText.plainText(of: snapshot.items),
               let match = SecretDetector.detectMatch(text, kinds: [kind]),
               match.isEmbedded {
                record.cardPreview = TextDecoding.prefix(match.matched, maxScalars: IngestEnrichment.cardPreviewScalars)
            } else {
                record.cardPreview = enrichment.cardPreview
            }
            record.textIndex = enrichment.textIndex
            record.textLength = enrichment.textLength
            record.lineCount = enrichment.lineCount
            record.sensitiveKind = snapshot.sensitiveKind?.rawValue
            record.pixelWidth = enrichment.pixelWidth
            record.pixelHeight = enrichment.pixelHeight
            record.colorHex = enrichment.colorHex
            record.filePaths = enrichment.filePaths
            record.storedTypes = Self.distinctTypes(of: snapshot.items)
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
        if case .stack(let stackID) = query.scope {
            let ordered = try filteredStackMemberIDs(stackID, query: query, in: context)
            let slice = Array(ordered.dropFirst(offset).prefix(limit))
            return try cards(for: slice, in: context)
        }
        var descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: try predicate(for: query, in: context),
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = Self.cardProperties
        return try context.fetch(descriptor).map(Self.card)
    }

    /// Everything a query finds (§8.2), pinned apart: for deleting all that is shown, from an
    /// app or in a collection. Identifiers only. Keep-bucket = favorite ∨ stack member (P32).
    public func ids(_ query: HistoryQuery) throws -> (others: [UUID], favorites: [UUID]) {
        let context = makeContext()
        let stacked = try stackedRecordIDs(in: context)
        let records: [(id: UUID, isFavorite: Bool)]
        if case .stack(let stackID) = query.scope {
            let ordered = try filteredStackMemberIDs(stackID, query: query, in: context)
            var byID: [UUID: Bool] = [:]
            if !ordered.isEmpty {
                var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ordered.contains($0.id) })
                descriptor.propertiesToFetch = [\.id, \.isFavorite]
                for record in try context.fetch(descriptor) {
                    byID[record.id] = record.isFavorite
                }
            }
            records = ordered.map { ($0, byID[$0] ?? false) }
        } else {
            var descriptor = FetchDescriptor<ClipboardRecord>(
                predicate: try predicate(for: query, in: context),
                sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
            )
            descriptor.propertiesToFetch = [\.id, \.isFavorite]
            records = try context.fetch(descriptor).map { ($0.id, $0.isFavorite) }
        }
        var others: [UUID] = []
        var favorites: [UUID] = []
        for record in records {
            if record.isFavorite || stacked.contains(record.id) {
                favorites.append(record.id)
            } else {
                others.append(record.id)
            }
        }
        return (others, favorites)
    }

    public func count(_ query: HistoryQuery) throws -> Int {
        let context = makeContext()
        if case .stack(let stackID) = query.scope {
            return try filteredStackMemberIDs(stackID, query: query, in: context).count
        }
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
        // Only text rows are read, and none when no text is wanted: an image's payload stays on
        // disk (review finding: every open of a record loaded all of it).
        var text: String?
        if maxTextScalars > 0 {
            let textTypes = Set(PasteboardType.plainTextTypes.union(PasteboardType.richTextTypes).union([.url]).map(\.rawValue))
            let items = Self.items(from: rows.filter { textTypes.contains($0.uti) })
            text = RichText.plainText(of: items).map { TextDecoding.prefix($0, maxScalars: maxTextScalars) }
        }
        let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == id }))
        return RecordDetails(
            card: Self.card(record),
            text: text,
            recognizedText: record.ocrText,
            recognitionState: RecognitionState(rawValue: record.ocrStateRaw) ?? .off,
            storedTypes: rows.map(\.uti),
            sourceWindowTitle: record.sourceWindowTitle,
            collectionIDs: Set(tags.map(\.collectionID)),
            linkTitle: rows.first { $0.uti == PasteboardType.urlName.rawValue }?.bytes
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Non-pinned last copied before `date`: what a lower count or age limit would delete (§6 / P32).
    public func countNonFavorites(copiedBefore date: Date = .distantFuture) throws -> Int {
        let context = makeContext()
        let stacked = try stackedRecordIDs(in: context)
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { !$0.isFavorite && $0.lastCopiedAt < date })
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).filter { !stacked.contains($0.id) }.count
    }

    /// The formatted text of a record's first item for its card (§8.2): same priority as the
    /// record window (`PasteboardType.richDisplayPriority`), so the card and editor do not disagree.
    /// Oversized or unreadable rows are skipped (`continue`); only that row is read.
    public func richPreviewSource(for id: UUID, maxBytes: Int = 512 * 1_024) throws -> (type: PasteboardType, data: Data)? {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return nil }
        let rows = record.representations.filter { $0.itemIndex == 0 }
        for type in PasteboardType.richDisplayPriority {
            guard let row = rows.first(where: { $0.uti == type.rawValue }) else { continue }
            guard row.byteCount <= maxBytes, let data = row.bytes else { continue }
            return (type, data)
        }
        return nil
    }

    /// Records stored as rich text whose formatting says nothing (one font in one colour) become
    /// text or links, as new copies are classified (owner feedback); run once after the update.
    /// Only the text rows are read, a few records at a time. Returns how many changed.
    @discardableResult
    public func reclassifyRichText() throws -> Int {
        let rich = DisplayType.richText.rawValue
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.displayTypeRaw == rich })
        descriptor.propertiesToFetch = [\.id]
        let ids = try makeContext().fetch(descriptor).map(\.id)
        let textTypes = Set(PasteboardType.plainTextTypes.union(PasteboardType.richTextTypes).union([.url]).map(\.rawValue))
        var changed = 0
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let context = makeContext()
            let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { batch.contains($0.id) }))
            for record in records {
                let rows = record.representations
                    .filter { textTypes.contains($0.uti) }
                    .sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
                let type = DisplayType.classify(Self.items(from: rows))
                guard type != .richText else { continue }
                record.displayTypeRaw = type.rawValue
                changed += 1
            }
            try context.save()
        }
        return changed
    }

    /// How many pasteboard items the record holds (several bookmarks or notes in one copy).
    public func itemCount(_ id: UUID) throws -> Int {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return 0 }
        return Set(record.representations.map(\.itemIndex)).count
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

    public func usage() throws -> HistoryUsage {
        let context = makeContext()
        let candidates = try retentionCandidates(in: context)
        return HistoryUsage(
            count: candidates.count,
            favorites: candidates.filter(\.isFavorite).count,
            payloadBytes: candidates.reduce(0) { $0 + $1.payloadSizeBytes }
        )
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
        let ids: [UUID]
        switch scope {
        case .all:
            var descriptor = FetchDescriptor<ClipboardRecord>()
            descriptor.propertiesToFetch = [\.id]
            ids = try context.fetch(descriptor).map(\.id)
        case .nonFavorites:
            // Neither favorite nor stack member (P32).
            let stacked = try stackedRecordIDs(in: context)
            var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { !$0.isFavorite })
            descriptor.propertiesToFetch = [\.id]
            ids = try context.fetch(descriptor).map(\.id).filter { !stacked.contains($0) }
        }
        try saveOrRollback(context) {
            try deleteRecords(ids: ids, in: context)
            if scope == .all {
                // Empty stack shells after Clear.all (v1).
                try pruneEmptyStacks(in: context)
            }
        }
        staleGuard.recordClear(opSeq: opSeq)
    }

    /// Favorite on / off with the count cap and age rules of §6. Favorites pinboard: join at front.
    public func setFavorite(_ id: UUID, _ isFavorite: Bool, limits: RetentionLimits, now: Date) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        try saveOrRollback(context) {
            record.isFavorite = isFavorite
            if isFavorite {
                record.expiresAt = nil
                try Self.insertFavoriteSlotFront(kind: .record, entryID: id, in: context)
                return
            }
            try Self.removeFavoriteSlot(kind: .record, entryID: id, in: context)
            let candidates = try retentionCandidates(in: context)
            var victims = RetentionPlanner.planUnfavorite(id, existing: candidates, maxCount: limits.maxCount)
            // Older than History keeps, the record goes too, as the next cleanup would delete it
            // anyway; the app asks before unfavoriting such a record.
            let planned = Set(victims)
            victims += RetentionPlanner.planAge(existing: candidates, now: now, maxAge: limits.maxAge).filter { !planned.contains($0) }
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

    /// Edit text (§3.6): in-place replacement with one item — the formatted text when `rich` is
    /// given, always the plain text — and merge on collision. A secret typed in is masked and,
    /// under *Delete after*, expires as a copied one does (§3.10).
    public func editText(
        _ id: UUID,
        text: String,
        rich: RichContent? = nil,
        opSeq: Int,
        maxBytes: Int,
        secretPolicy: SecretPolicy = .off,
        secretKinds: Set<SecretKind> = Set(SecretKind.allCases),
        now: Date = Date()
    ) throws -> EditResult {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return .rejected("The record no longer exists.") }
        guard let type = DisplayType(rawValue: record.displayTypeRaw), [.text, .richText, .url].contains(type) else {
            return .rejected("Only text records can be edited.")
        }
        guard !text.isEmpty else { return .rejected("The text is empty.") }
        // The editor shows the first item's text: saving would drop the others (review finding).
        guard Set(record.representations.map(\.itemIndex)).count <= 1 else {
            return .rejected("Records with several items can't be edited.")
        }
        let data = Data(text.utf8)
        var representations: [CanonicalRepresentation] = []
        if let rich {
            representations.append(.bytes(rich.type, rich.data))
            if let html = rich.html { representations.append(.bytes(.html, html)) }
        }
        representations.append(.bytes(.utf8PlainText, data))
        let size = representations.reduce(0) { $0 + $1.byteCount }
        guard size <= maxBytes else { return .rejected("The text is larger than the item size limit.") }

        let items = [CanonicalItem(representations)]
        let hash = MCS1.contentHash(of: items)
        guard hash != record.contentHash else { return .updated }
        staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq)

        if let survivor = try fetchRecord(withHash: hash, in: context), survivor.id != id {
            try saveOrRollback(context) {
                apply(DedupMerge.mergeEdited(try metadata(of: record, in: context), into: try metadata(of: survivor, in: context)), to: survivor)
                if survivor.customTitle == nil { survivor.customTitle = record.customTitle }
                survivor.searchText = Self.searchText(for: survivor)
                let survivorID = survivor.id
                let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == id }))
                let existing = Set(try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == survivorID })).map(\.collectionID))
                for tag in tags where !existing.contains(tag.collectionID) {
                    context.insert(RecordTag(recordID: survivorID, collectionID: tag.collectionID))
                }
                try retargetStackMembers(from: id, to: survivorID, in: context)
                try Self.retargetFavoriteSlot(from: id, to: survivorID, in: context)
                try Self.retargetCollectionSlots(from: id, to: survivorID, in: context)
                try deleteRecords(ids: [id], in: context)
            }
            return .merged(into: survivor.id)
        }

        try saveOrRollback(context) {
            for row in record.representations { context.delete(row) }
            record.representations = []
            insertRepresentations(of: items, for: record, in: context)
            record.contentHash = hash
            record.payloadSizeBytes = size
            // As for a copy: formatting that says nothing makes it text (`FormattingSignificance`).
            record.displayTypeRaw = DisplayType.classify(items).rawValue
            record.textIndex = TextDecoding.prefix(text, maxScalars: IngestEnrichment.searchScalars)
            record.textLength = text.count
            record.lineCount = TextStats.lineCount(text)
            // Edited text is checked like a copy: a token typed in is masked, and expires under
            // *Delete after* (review findings).
            let secret = secretPolicy == .off ? nil : SecretDetector.detectMatch(text, kinds: secretKinds)
            if let secret, secret.isEmbedded {
                record.cardPreview = TextDecoding.prefix(secret.matched, maxScalars: IngestEnrichment.cardPreviewScalars)
            } else {
                record.cardPreview = TextDecoding.prefix(text, maxScalars: IngestEnrichment.cardPreviewScalars)
            }
            record.sensitiveKind = secret?.kind.rawValue
            let pinned = try record.isFavorite || stackedRecordIDs(in: context).contains(id)
            if secret != nil, case .deleteAfter(let minutes) = secretPolicy, !pinned {
                let expiry = now.addingTimeInterval(TimeInterval(minutes) * 60)
                record.expiresAt = min(record.expiresAt ?? expiry, expiry)
            }
            record.editedAt = Date()
            record.storedTypes = representations.map(\.type.rawValue)
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
        // The count and the storage limit apply to what is left, not to records already going.
        var planned = Set(victims)
        victims += RetentionPlanner.planCountShrink(existing: candidates.filter { !planned.contains($0.id) }, maxCount: limits.maxCount)
        planned = Set(victims)
        victims += RetentionPlanner.planStorageShrink(
            existing: candidates.filter { !planned.contains($0.id) },
            maxStorageBytes: limits.maxStorageBytes
        )
        let removed = Set(victims)
        if !removed.isEmpty {
            try saveOrRollback(context) { try deleteRecords(ids: Array(removed), in: context) }
        }
        return RetentionPlanner.nextExpiry(existing: candidates.filter { !removed.contains($0.id) })
    }

    /// *Also delete N existing items from <App>* (§5.1): non-pinned only (P32).
    @discardableResult
    public func deleteRecords(fromApp bundleID: String, opSeq: Int) throws -> Int {
        let context = makeContext()
        let app: String? = bundleID
        let stacked = try stackedRecordIDs(in: context)
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.lastSourceAppBundleID == app && !$0.isFavorite }
        )).filter { !stacked.contains($0.id) }
        for record in records { staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq) }
        let ids = records.map(\.id)
        try saveOrRollback(context) { try deleteRecords(ids: ids, in: context) }
        return ids.count
    }

    public func countRecords(fromApp bundleID: String) throws -> Int {
        let context = makeContext()
        let app: String? = bundleID
        let stacked = try stackedRecordIDs(in: context)
        return try context.fetch(FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.lastSourceAppBundleID == app && !$0.isFavorite }
        )).filter { !stacked.contains($0.id) }.count
    }

    // MARK: - Collections (§8.2)

    public func collections() throws -> [CollectionSummary] {
        let context = makeContext()
        let collections = try context.fetch(FetchDescriptor<CollectionModel>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
        let tags = try context.fetch(FetchDescriptor<RecordTag>())
        let stackTags = try context.fetch(FetchDescriptor<StackTag>())
        var counts: [UUID: Int] = Dictionary(grouping: tags, by: \.collectionID).mapValues(\.count)
        for tag in stackTags { counts[tag.collectionID, default: 0] += 1 }
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
            try context.delete(model: StackTag.self, where: #Predicate { $0.collectionID == id })
            try context.delete(model: CollectionSlot.self, where: #Predicate { $0.collectionID == id })
            try context.delete(model: CollectionModel.self, where: #Predicate { $0.id == id })
        }
    }

    /// Collections of each listed record (card menus, §8.4).
    public func memberships(of recordIDs: [UUID]) throws -> [UUID: Set<UUID>] {
        guard !recordIDs.isEmpty else { return [:] }
        let context = makeContext()
        let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { recordIDs.contains($0.recordID) }))
        return Dictionary(grouping: tags, by: \.recordID).mapValues { Set($0.map(\.collectionID)) }
    }

    public func setMembership(record recordID: UUID, collection collectionID: UUID, isMember: Bool) throws {
        let context = makeContext()
        // A record deleted meanwhile (expiry, retention) must not leave a tag behind.
        if isMember, try fetchRecord(recordID, in: context) == nil { return }
        let existing = try context.fetch(FetchDescriptor<RecordTag>(
            predicate: #Predicate { $0.recordID == recordID && $0.collectionID == collectionID }
        ))
        if isMember, existing.isEmpty {
            context.insert(RecordTag(recordID: recordID, collectionID: collectionID))
            try Self.insertCollectionSlotFront(
                collectionID: collectionID, kind: .record, entryID: recordID, in: context
            )
        } else if !isMember {
            existing.forEach { context.delete($0) }
            try Self.removeCollectionSlot(
                collectionID: collectionID, kind: .record, entryID: recordID, in: context
            )
        }
        try context.save()
    }

    // MARK: - Paste stacks (§3.11)

    /// Stacks matching `query`, hard-capped (P22). Not a paged record fetch.
    public func stacks(_ query: HistoryQuery, limit: Int = 200) throws -> [StackCard] {
        let context = makeContext()
        var descriptor = FetchDescriptor<StackModel>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let models = try context.fetch(descriptor)
        let members = try context.fetch(FetchDescriptor<StackMember>())
        let tags = try context.fetch(FetchDescriptor<StackTag>())
        let membersByStack = Dictionary(grouping: members, by: \.stackID)
        let tagsByStack = Dictionary(grouping: tags, by: \.stackID)
        let recordIDs = Set(members.map(\.recordID))
        var recordMeta: [UUID: (displayType: String, app: String?, search: String, preview: String, sensitive: String?)] = [:]
        if !recordIDs.isEmpty {
            let ids = Array(recordIDs)
            var recDesc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })
            recDesc.propertiesToFetch = [\.id, \.displayTypeRaw, \.lastSourceAppBundleID, \.searchText, \.cardPreview, \.sensitiveKind]
            for record in try context.fetch(recDesc) {
                recordMeta[record.id] = (
                    record.displayTypeRaw,
                    record.lastSourceAppBundleID,
                    record.searchText,
                    record.cardPreview,
                    record.sensitiveKind
                )
            }
        }

        return models.compactMap { stack -> StackCard? in
            let ordered = (membersByStack[stack.id] ?? []).sorted { $0.position < $1.position }
            // Drop orphan members whose record is gone.
            let live = ordered.filter { recordMeta[$0.recordID] != nil }
            let memberIDs = live.map(\.recordID)
            let collectionIDs = Set((tagsByStack[stack.id] ?? []).map(\.collectionID))
            let card = StackCard(
                id: stack.id,
                title: stack.title,
                isFavorite: stack.isFavorite,
                loops: stack.loops,
                dealMode: StackDealMode(rawValue: stack.dealModeRaw) ?? .sequential,
                createdAt: stack.createdAt,
                lastUsedAt: stack.lastUsedAt,
                memberIDs: memberIDs,
                previewRecordID: memberIDs.first,
                memberCount: memberIDs.count,
                collectionIDs: collectionIDs,
                sensitiveKind: memberIDs.first.flatMap { recordMeta[$0]?.sensitive },
                preview: memberIDs.first.flatMap { recordMeta[$0]?.preview } ?? ""
            )
            guard stackMatches(card, members: live.compactMap { recordMeta[$0.recordID] }, query: query) else { return nil }
            return card
        }
    }

    public func stack(_ id: UUID) throws -> StackCard? {
        try stacks(HistoryQuery()).first { $0.id == id }
    }

    /// Member record ids in UI order; orphans pruned.
    public func stackMemberIDs(_ stackID: UUID) throws -> [UUID] {
        let context = makeContext()
        let members = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID },
            sortBy: [SortDescriptor(\.position)]
        ))
        var result: [UUID] = []
        for member in members {
            if try fetchRecord(member.recordID, in: context) != nil {
                result.append(member.recordID)
            } else {
                context.delete(member)
            }
        }
        if context.hasChanges { try context.save() }
        return result
    }

    @discardableResult
    public func createStack(
        title: String,
        recordIDs: [UUID],
        dealMode: StackDealMode = .sequential,
        loops: Bool = false
    ) throws -> UUID {
        let context = makeContext()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Stack" : trimmed
        let now = Date()
        let stack = StackModel(
            title: name,
            loops: loops && dealMode != .shuffleRandom,
            dealModeRaw: dealMode.rawValue,
            createdAt: now,
            lastUsedAt: now
        )
        context.insert(stack)
        var seen = Set<UUID>()
        var position = 0
        for recordID in recordIDs {
            guard seen.insert(recordID).inserted else { continue }
            guard let record = try fetchRecord(recordID, in: context) else { continue }
            record.expiresAt = nil
            context.insert(StackMember(stackID: stack.id, recordID: recordID, position: position))
            position += 1
        }
        try context.save()
        return stack.id
    }

    public func renameStack(_ id: UUID, title: String) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        stack.title = trimmed.isEmpty ? "Stack" : trimmed
        try context.save()
    }

    public func setStackFavorite(_ id: UUID, _ isFavorite: Bool) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        try saveOrRollback(context) {
            stack.isFavorite = isFavorite
            if isFavorite {
                try Self.insertFavoriteSlotFront(kind: .stack, entryID: id, in: context)
            } else {
                try Self.removeFavoriteSlot(kind: .stack, entryID: id, in: context)
            }
        }
    }

    public func setStackDeal(_ id: UUID, dealMode: StackDealMode, loops: Bool) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        stack.dealModeRaw = dealMode.rawValue
        stack.loops = dealMode == .shuffleRandom ? false : loops
        try context.save()
    }

    public func markStackUsed(_ id: UUID, at date: Date) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        stack.lastUsedAt = max(stack.lastUsedAt, date)
        try context.save()
    }

    public func deleteStacks(_ ids: [UUID]) throws {
        let context = makeContext()
        try saveOrRollback(context) {
            try context.delete(model: StackMember.self, where: #Predicate { ids.contains($0.stackID) })
            try context.delete(model: StackTag.self, where: #Predicate { ids.contains($0.stackID) })
            let kind = FavoriteSlotKind.stack.rawValue
            try context.delete(model: FavoriteSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
            try context.delete(model: CollectionSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
            try context.delete(model: StackModel.self, where: #Predicate { ids.contains($0.id) })
            try Self.compactFavoriteSlots(in: context)
            try Self.compactAllCollectionSlots(in: context)
        }
    }

    /// Replace UI order. Clears `expiresAt` on newly joined members (P36).
    public func setStackMembers(_ stackID: UUID, recordIDs: [UUID]) throws {
        let context = makeContext()
        guard try fetchStack(stackID, in: context) != nil else { return }
        let previous = Set(try context.fetch(FetchDescriptor<StackMember>(predicate: #Predicate { $0.stackID == stackID })).map(\.recordID))
        try context.delete(model: StackMember.self, where: #Predicate { $0.stackID == stackID })
        var seen = Set<UUID>()
        var position = 0
        for recordID in recordIDs {
            guard seen.insert(recordID).inserted else { continue }
            guard let record = try fetchRecord(recordID, in: context) else { continue }
            if !previous.contains(recordID) { record.expiresAt = nil }
            context.insert(StackMember(stackID: stackID, recordID: recordID, position: position))
            position += 1
        }
        try context.save()
    }

    public func appendStackMember(_ stackID: UUID, recordID: UUID) throws {
        let context = makeContext()
        guard try fetchStack(stackID, in: context) != nil else { return }
        guard let record = try fetchRecord(recordID, in: context) else { return }
        let existing = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID && $0.recordID == recordID }
        ))
        guard existing.isEmpty else { return }
        let count = try context.fetchCount(FetchDescriptor<StackMember>(predicate: #Predicate { $0.stackID == stackID }))
        record.expiresAt = nil
        context.insert(StackMember(stackID: stackID, recordID: recordID, position: count))
        try context.save()
    }

    /// Independent copy of a stack member (same payload / MCS1 hash) inserted **after** it.
    /// Same hash keeps Restore integrity; editing the copy diverges the hash. Dedup on a later
    /// capture may merge siblings — intentional until the copy is edited.
    @discardableResult
    public func duplicateInStack(recordID: UUID, stackID: UUID, now: Date = Date()) throws -> UUID {
        let context = makeContext()
        guard try fetchStack(stackID, in: context) != nil else { throw StoreError.notFound }
        guard let source = try fetchRecord(recordID, in: context) else { throw StoreError.notFound }
        let members = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID },
            sortBy: [SortDescriptor(\.position)]
        ))
        guard let index = members.firstIndex(where: { $0.recordID == recordID }) else {
            throw StoreError.notFound
        }

        let copy = ClipboardRecord(
            displayTypeRaw: source.displayTypeRaw,
            firstCopiedAt: now,
            lastCopiedAt: now,
            copyCount: 1,
            contentHash: source.contentHash,
            hashSchemeVersion: source.hashSchemeVersion,
            storageFormatVersion: source.storageFormatVersion,
            payloadSizeBytes: source.payloadSizeBytes
        )
        copy.cardPreview = source.cardPreview
        copy.textIndex = source.textIndex
        copy.textLength = source.textLength
        copy.lineCount = source.lineCount
        copy.sensitiveKind = source.sensitiveKind
        copy.searchText = source.searchText
        copy.customTitle = source.customTitle
        copy.ocrText = source.ocrText
        copy.ocrStateRaw = source.ocrStateRaw
        copy.sourceURL = source.sourceURL
        copy.sourceWindowTitle = source.sourceWindowTitle
        copy.codeLanguage = source.codeLanguage
        copy.pixelWidth = source.pixelWidth
        copy.pixelHeight = source.pixelHeight
        copy.colorHex = source.colorHex
        copy.filePaths = source.filePaths
        copy.storedTypes = source.storedTypes
        copy.skippedTypes = source.skippedTypes
        copy.lastSourceAppBundleID = source.lastSourceAppBundleID
        copy.lastSourceAppName = source.lastSourceAppName
        copy.editedAt = source.editedAt
        context.insert(copy)

        for row in source.representations {
            let rep = PayloadRepresentation(
                itemIndex: row.itemIndex,
                repIndex: row.repIndex,
                uti: row.uti,
                kindRaw: row.kindRaw,
                bytes: row.bytes,
                paths: row.paths,
                byteCount: row.byteCount
            )
            context.insert(rep)
            rep.record = copy
        }
        if let thumb = source.thumbnail {
            let model = RecordThumbnail(data: thumb.data)
            context.insert(model)
            model.record = copy
            copy.hasThumbnail = true
        }

        let insertAt = index + 1
        for member in members where member.position >= insertAt {
            member.position += 1
        }
        context.insert(StackMember(stackID: stackID, recordID: copy.id, position: insertAt))
        try context.save()
        return copy.id
    }

    /// Drop one member; compact UI positions. Does not restore `expiresAt` (§6 / P36).
    public func removeStackMember(_ stackID: UUID, recordID: UUID) throws {
        let context = makeContext()
        let rows = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID && $0.recordID == recordID }
        ))
        guard !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        let ordered = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID },
            sortBy: [SortDescriptor(\.position)]
        ))
        for (index, member) in ordered.enumerated() { member.position = index }
        try context.save()
    }

    public func setStackMembership(stack stackID: UUID, collection collectionID: UUID, isMember: Bool) throws {
        let context = makeContext()
        guard try fetchStack(stackID, in: context) != nil else { return }
        let existing = try context.fetch(FetchDescriptor<StackTag>(
            predicate: #Predicate { $0.stackID == stackID && $0.collectionID == collectionID }
        ))
        if isMember, existing.isEmpty {
            context.insert(StackTag(stackID: stackID, collectionID: collectionID))
            try Self.insertCollectionSlotFront(
                collectionID: collectionID, kind: .stack, entryID: stackID, in: context
            )
        } else if !isMember {
            existing.forEach { context.delete($0) }
            try Self.removeCollectionSlot(
                collectionID: collectionID, kind: .stack, entryID: stackID, in: context
            )
        }
        try context.save()
    }

    // MARK: - Pinboard order (Favorites / Collections)

    /// Unified ordered feed for Favorites or a Collection. Ignores `query.since`. Not paged.
    public func pinboardEntries(_ query: HistoryQuery, limit: Int = ClipboardStore.maxPinboardEntries) throws -> [HistoryEntry] {
        guard query.scope.isPinboard else { return [] }
        let context = makeContext()
        try Self.seedPinboardOrderIfNeeded(in: context)
        try context.save()

        let orderedIDs: [HistoryEntry.ID]
        switch query.scope {
        case .favorites:
            orderedIDs = try Self.favoriteEntryIDs(in: context)
        case .collection(let collectionID):
            orderedIDs = try Self.collectionEntryIDs(collectionID: collectionID, in: context)
        default:
            return []
        }

        // Filter kinds/search without period; materialize only what we keep (cap after filter).
        var filterQuery = query
        filterQuery.since = nil
        var result: [HistoryEntry] = []
        result.reserveCapacity(min(limit, orderedIDs.count))

        let recordIDs = orderedIDs.compactMap { id -> UUID? in
            if case .record(let uuid) = id { return uuid }
            return nil
        }
        var recordsByID: [UUID: ClipboardRecord] = [:]
        if !recordIDs.isEmpty {
            let ids = recordIDs
            for record in try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })) {
                recordsByID[record.id] = record
            }
        }

        // Stack DTOs matching scope + kinds + search (period ignored). Lookup only — board order is slots.
        let stackCards = try stacks(
            HistoryQuery(scope: query.scope, search: query.search, kinds: query.kinds, since: nil),
            limit: Self.maxPinboardEntries
        )
        let stacksByID = Dictionary(uniqueKeysWithValues: stackCards.map { ($0.id, $0) })

        for entryID in orderedIDs {
            guard result.count < limit else { break }
            switch entryID {
            case .record(let id):
                guard let record = recordsByID[id],
                      Self.recordMatchesPinboardFilters(record, query: filterQuery) else { continue }
                result.append(.record(Self.card(record)))
            case .stack(let id):
                guard let card = stacksByID[id] else { continue }
                result.append(.stack(card))
            }
        }
        return result
    }

    /// Rewrite Favorites pinboard order (full unfiltered list). Positions become 0..<n.
    public func reorderFavorites(_ entryIDs: [HistoryEntry.ID]) throws {
        let context = makeContext()
        try saveOrRollback(context) {
            for slot in try context.fetch(FetchDescriptor<FavoriteSlot>()) {
                context.delete(slot)
            }
            var position = 0
            var seen = Set<HistoryEntry.ID>()
            for entryID in entryIDs {
                guard seen.insert(entryID).inserted else { continue }
                switch entryID {
                case .record(let id):
                    guard let record = try fetchRecord(id, in: context), record.isFavorite else { continue }
                    context.insert(FavoriteSlot(entryKindRaw: FavoriteSlotKind.record.rawValue, entryID: id, position: position))
                    position += 1
                case .stack(let id):
                    guard let stack = try fetchStack(id, in: context), stack.isFavorite else { continue }
                    context.insert(FavoriteSlot(entryKindRaw: FavoriteSlotKind.stack.rawValue, entryID: id, position: position))
                    position += 1
                }
            }
        }
    }

    /// Rewrite one collection's pinboard order (records ∪ stacks). Keeps membership tags in sync.
    public func reorderCollection(_ collectionID: UUID, _ entryIDs: [HistoryEntry.ID]) throws {
        let context = makeContext()
        try saveOrRollback(context) {
            try context.delete(model: CollectionSlot.self, where: #Predicate { $0.collectionID == collectionID })
            try context.delete(model: RecordTag.self, where: #Predicate { $0.collectionID == collectionID })
            try context.delete(model: StackTag.self, where: #Predicate { $0.collectionID == collectionID })
            var position = 0
            var seen = Set<HistoryEntry.ID>()
            for entryID in entryIDs {
                guard seen.insert(entryID).inserted else { continue }
                switch entryID {
                case .record(let id):
                    guard try fetchRecord(id, in: context) != nil else { continue }
                    context.insert(RecordTag(recordID: id, collectionID: collectionID))
                    context.insert(CollectionSlot(
                        collectionID: collectionID,
                        entryKindRaw: FavoriteSlotKind.record.rawValue,
                        entryID: id,
                        position: position
                    ))
                    position += 1
                case .stack(let id):
                    guard try fetchStack(id, in: context) != nil else { continue }
                    context.insert(StackTag(stackID: id, collectionID: collectionID))
                    context.insert(CollectionSlot(
                        collectionID: collectionID,
                        entryKindRaw: FavoriteSlotKind.stack.rawValue,
                        entryID: id,
                        position: position
                    ))
                    position += 1
                }
            }
        }
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
        // A PDF record's PDF, else the most compact common raster first: the relationship has no
        // order, and a multi-megabyte TIFF was sometimes read instead of the PNG.
        let preference: [PasteboardType] = record.displayTypeRaw == DisplayType.pdf.rawValue
            ? [.pdf, .png, .jpeg, .heic, .tiff, .gif]
            : [.png, .jpeg, .heic, .tiff, .gif, .pdf]
        let rows = record.representations
        guard let row = preference.lazy.compactMap({ type in rows.first { $0.uti == type.rawValue } }).first,
              let data = row.bytes else { return nil }
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

    /// Live member IDs in UI order that also match kind/period/search (position preserved).
    private func filteredStackMemberIDs(_ stackID: UUID, query: HistoryQuery, in context: ModelContext) throws -> [UUID] {
        let members = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID },
            sortBy: [SortDescriptor(\.position)]
        ))
        var ordered: [UUID] = []
        var orphaned = false
        for member in members {
            if try fetchRecord(member.recordID, in: context) != nil {
                ordered.append(member.recordID)
            } else {
                context.delete(member)
                orphaned = true
            }
        }
        if orphaned { try context.save() }
        guard !ordered.isEmpty else { return [] }
        // Predicate includes stack membership + kinds/since/search; re-apply UI order.
        guard let filter = try predicate(for: query, in: context) else { return ordered }
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: filter)
        descriptor.propertiesToFetch = [\.id]
        let matching = Set(try context.fetch(descriptor).map(\.id))
        return ordered.filter { matching.contains($0) }
    }

    private func cards(for ids: [UUID], in context: ModelContext) throws -> [HistoryCard] {
        guard !ids.isEmpty else { return [] }
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = Self.cardProperties
        let byID = Dictionary(uniqueKeysWithValues: try context.fetch(descriptor).map { ($0.id, Self.card($0)) })
        return ids.compactMap { byID[$0] }
    }

    private static var cardProperties: [PartialKeyPath<ClipboardRecord>] {
        [
        \.id, \.displayTypeRaw, \.cardPreview, \.customTitle, \.textLength, \.lineCount, \.sensitiveKind, \.pixelWidth, \.pixelHeight,
        \.filePaths, \.colorHex, \.payloadSizeBytes, \.firstCopiedAt, \.lastCopiedAt, \.copyCount, \.isFavorite,
        \.lastSourceAppBundleID, \.lastSourceAppName, \.sourceURL, \.editedAt, \.expiresAt, \.ocrStateRaw,
        \.storedTypes, \.skippedTypes, \.hasThumbnail, \.codeLanguage,
        ]
    }

    private static func card(_ record: ClipboardRecord) -> HistoryCard {
        HistoryCard(
            id: record.id,
            displayType: DisplayType(rawValue: record.displayTypeRaw) ?? .mixed,
            preview: record.cardPreview,
            customTitle: record.customTitle,
            textLength: record.textLength,
            lineCount: record.lineCount,
            sensitiveKind: record.sensitiveKind,
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
            storedTypes: record.storedTypes,
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

    private static func distinctTypes(of items: [CanonicalItem]) -> [String] {
        var seen: Set<String> = []
        return items.flatMap(\.representations).map(\.type.rawValue).filter { seen.insert($0).inserted }
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
        let stacked = try stackedRecordIDs(in: context)
        var descriptor = FetchDescriptor<ClipboardRecord>()
        descriptor.propertiesToFetch = [\.id, \.isFavorite, \.lastCopiedAt, \.payloadSizeBytes, \.expiresAt]
        return try context.fetch(descriptor).map {
            RetentionCandidate(
                id: $0.id,
                isFavorite: $0.isFavorite,
                lastCopiedAt: $0.lastCopiedAt,
                payloadSizeBytes: $0.payloadSizeBytes,
                expiresAt: $0.expiresAt,
                isPinned: $0.isFavorite || stacked.contains($0.id)
            )
        }
    }

    private func stackedRecordIDs(in context: ModelContext) throws -> Set<UUID> {
        var descriptor = FetchDescriptor<StackMember>()
        descriptor.propertiesToFetch = [\.recordID]
        return Set(try context.fetch(descriptor).map(\.recordID))
    }

    private func fetchStack(_ id: UUID, in context: ModelContext) throws -> StackModel? {
        var descriptor = FetchDescriptor<StackModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Dedup/edit merge: retarget membership; drop duplicate rows in the same stack and compact.
    private func retargetStackMembers(from oldID: UUID, to survivorID: UUID, in context: ModelContext) throws {
        let members = try context.fetch(FetchDescriptor<StackMember>(predicate: #Predicate { $0.recordID == oldID }))
        for member in members {
            let stackID = member.stackID
            let already = try context.fetch(FetchDescriptor<StackMember>(
                predicate: #Predicate { $0.stackID == stackID && $0.recordID == survivorID }
            ))
            if already.isEmpty {
                member.recordID = survivorID
            } else {
                context.delete(member)
            }
        }
        let affected = Set(members.map(\.stackID))
        for stackID in affected {
            let ordered = try context.fetch(FetchDescriptor<StackMember>(
                predicate: #Predicate { $0.stackID == stackID },
                sortBy: [SortDescriptor(\.position)]
            ))
            for (index, member) in ordered.enumerated() { member.position = index }
        }
    }

    private func pruneEmptyStacks(in context: ModelContext) throws {
        let stacks = try context.fetch(FetchDescriptor<StackModel>())
        let members = try context.fetch(FetchDescriptor<StackMember>())
        let populated = Set(members.map(\.stackID))
        let empty = stacks.filter { !populated.contains($0.id) }.map(\.id)
        guard !empty.isEmpty else { return }
        try context.delete(model: StackTag.self, where: #Predicate { empty.contains($0.stackID) })
        let kind = FavoriteSlotKind.stack.rawValue
        try context.delete(model: FavoriteSlot.self, where: #Predicate { $0.entryKindRaw == kind && empty.contains($0.entryID) })
        try context.delete(model: CollectionSlot.self, where: #Predicate { $0.entryKindRaw == kind && empty.contains($0.entryID) })
        try context.delete(model: StackModel.self, where: #Predicate { empty.contains($0.id) })
        try Self.compactFavoriteSlots(in: context)
        try Self.compactAllCollectionSlots(in: context)
    }

    private func stackMatches(
        _ card: StackCard,
        members: [(displayType: String, app: String?, search: String, preview: String, sensitive: String?)],
        query: HistoryQuery
    ) -> Bool {
        switch query.scope {
        case .all: break
        case .favorites:
            guard card.isFavorite else { return false }
        case .app(let bundleID):
            guard members.contains(where: { $0.app == bundleID }) else { return false }
        case .type(let type):
            guard members.contains(where: { $0.displayType == type.rawValue }) else { return false }
        case .collection(let collectionID):
            guard card.collectionIDs.contains(collectionID) else { return false }
        case .stack:
            // Drill-down shows members only — never nest stack cards in the grid.
            return false
        }
        if !query.kinds.isEmpty {
            let raws = Set(query.kinds.map(\.rawValue))
            guard members.contains(where: { raws.contains($0.displayType) }) else { return false }
        }
        if let since = query.since, card.lastUsedAt < since { return false }
        for word in query.words {
            let inTitle = card.title.localizedStandardContains(word)
            let inMembers = members.contains { $0.search.localizedStandardContains(word) }
            guard inTitle || inMembers else { return false }
        }
        return true
    }

    /// Records, their representations and thumbnails (cascade) and memberships, in the caller's transaction.
    private func deleteRecords(ids: [UUID], in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))
        records.forEach { context.delete($0) }
        try context.delete(model: RecordTag.self, where: #Predicate { ids.contains($0.recordID) })
        try context.delete(model: StackMember.self, where: #Predicate { ids.contains($0.recordID) })
        let kind = FavoriteSlotKind.record.rawValue
        try context.delete(model: FavoriteSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
        try context.delete(model: CollectionSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
        try Self.compactFavoriteSlots(in: context)
        try Self.compactAllCollectionSlots(in: context)
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
        case .stack(let stackID):
            // Prefer `filteredStackMemberIDs` / `page` for order; predicate keeps ids()/count callers correct.
            let ids = try context.fetch(FetchDescriptor<StackMember>(predicate: #Predicate { $0.stackID == stackID })).map(\.recordID)
            and(#Predicate { ids.contains($0.id) })
        }
        if !query.kinds.isEmpty {
            let raws = query.kinds.map(\.rawValue)
            and(#Predicate { raws.contains($0.displayTypeRaw) })
        }
        if let since = query.since {
            and(#Predicate { $0.lastCopiedAt >= since })
        }
        for word in query.words {
            and(#Predicate { $0.searchText.localizedStandardContains(word) })
        }
        return result
    }

    private func metadata(of record: ClipboardRecord, in context: ModelContext) throws -> RecordMetadata {
        let stacked = try stackedRecordIDs(in: context)
        return RecordMetadata(
            firstCopiedAt: record.firstCopiedAt,
            lastCopiedAt: record.lastCopiedAt,
            copyCount: record.copyCount,
            isFavorite: record.isFavorite,
            isPinned: record.isFavorite || stacked.contains(record.id),
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

    // MARK: - Pinboard helpers

    private static func recordMatchesPinboardFilters(_ record: ClipboardRecord, query: HistoryQuery) -> Bool {
        if !query.kinds.isEmpty {
            let raws = query.kinds.map(\.rawValue)
            guard raws.contains(record.displayTypeRaw) else { return false }
        }
        for word in query.words {
            guard record.searchText.localizedStandardContains(word) else { return false }
        }
        return true
    }

    private static func favoriteEntryIDs(in context: ModelContext) throws -> [HistoryEntry.ID] {
        let slots = try context.fetch(FetchDescriptor<FavoriteSlot>(sortBy: [SortDescriptor(\.position)]))
        return slots.compactMap { slot -> HistoryEntry.ID? in
            switch FavoriteSlotKind(rawValue: slot.entryKindRaw) {
            case .record: .record(slot.entryID)
            case .stack: .stack(slot.entryID)
            case nil: nil
            }
        }
    }

    private static func collectionEntryIDs(collectionID: UUID, in context: ModelContext) throws -> [HistoryEntry.ID] {
        let slots = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate { $0.collectionID == collectionID },
            sortBy: [SortDescriptor(\.position)]
        ))
        return slots.compactMap { slot -> HistoryEntry.ID? in
            switch FavoriteSlotKind(rawValue: slot.entryKindRaw) {
            case .record: .record(slot.entryID)
            case .stack: .stack(slot.entryID)
            case nil: nil
            }
        }
    }

    fileprivate static func insertFavoriteSlotFront(kind: FavoriteSlotKind, entryID: UUID, in context: ModelContext) throws {
        let kindRaw = kind.rawValue
        let existing = try context.fetch(FetchDescriptor<FavoriteSlot>(
            predicate: #Predicate { $0.entryKindRaw == kindRaw && $0.entryID == entryID }
        ))
        if !existing.isEmpty { return }
        for slot in try context.fetch(FetchDescriptor<FavoriteSlot>()) {
            slot.position += 1
        }
        context.insert(FavoriteSlot(entryKindRaw: kindRaw, entryID: entryID, position: 0))
    }

    fileprivate static func removeFavoriteSlot(kind: FavoriteSlotKind, entryID: UUID, in context: ModelContext) throws {
        let kindRaw = kind.rawValue
        let rows = try context.fetch(FetchDescriptor<FavoriteSlot>(
            predicate: #Predicate { $0.entryKindRaw == kindRaw && $0.entryID == entryID }
        ))
        guard !rows.isEmpty else { return }
        rows.forEach { context.delete($0) }
        try compactFavoriteSlots(in: context)
    }

    fileprivate static func compactFavoriteSlots(in context: ModelContext) throws {
        let ordered = try context.fetch(FetchDescriptor<FavoriteSlot>(sortBy: [SortDescriptor(\.position)]))
        for (index, slot) in ordered.enumerated() { slot.position = index }
    }

    fileprivate static func insertCollectionSlotFront(
        collectionID: UUID,
        kind: FavoriteSlotKind,
        entryID: UUID,
        in context: ModelContext
    ) throws {
        let kindRaw = kind.rawValue
        let existing = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate {
                $0.collectionID == collectionID && $0.entryKindRaw == kindRaw && $0.entryID == entryID
            }
        ))
        if !existing.isEmpty { return }
        let siblings = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate { $0.collectionID == collectionID }
        ))
        for slot in siblings { slot.position += 1 }
        context.insert(CollectionSlot(
            collectionID: collectionID,
            entryKindRaw: kindRaw,
            entryID: entryID,
            position: 0
        ))
    }

    fileprivate static func removeCollectionSlot(
        collectionID: UUID,
        kind: FavoriteSlotKind,
        entryID: UUID,
        in context: ModelContext
    ) throws {
        let kindRaw = kind.rawValue
        let rows = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate {
                $0.collectionID == collectionID && $0.entryKindRaw == kindRaw && $0.entryID == entryID
            }
        ))
        guard !rows.isEmpty else { return }
        rows.forEach { context.delete($0) }
        try compactCollectionSlots(collectionID: collectionID, in: context)
    }

    fileprivate static func compactCollectionSlots(collectionID: UUID, in context: ModelContext) throws {
        let ordered = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate { $0.collectionID == collectionID },
            sortBy: [SortDescriptor(\.position)]
        ))
        for (index, slot) in ordered.enumerated() { slot.position = index }
    }

    fileprivate static func compactAllCollectionSlots(in context: ModelContext) throws {
        let slots = try context.fetch(FetchDescriptor<CollectionSlot>())
        let byCollection = Dictionary(grouping: slots, by: \.collectionID)
        for (collectionID, _) in byCollection {
            try compactCollectionSlots(collectionID: collectionID, in: context)
        }
    }

    fileprivate static func retargetFavoriteSlot(from oldID: UUID, to survivorID: UUID, in context: ModelContext) throws {
        let kind = FavoriteSlotKind.record.rawValue
        let oldSlots = try context.fetch(FetchDescriptor<FavoriteSlot>(
            predicate: #Predicate { $0.entryKindRaw == kind && $0.entryID == oldID }
        ))
        guard let old = oldSlots.first else { return }
        let survivorSlots = try context.fetch(FetchDescriptor<FavoriteSlot>(
            predicate: #Predicate { $0.entryKindRaw == kind && $0.entryID == survivorID }
        ))
        if let kept = survivorSlots.first {
            kept.position = min(kept.position, old.position)
            context.delete(old)
            try compactFavoriteSlots(in: context)
        } else {
            old.entryID = survivorID
        }
    }

    fileprivate static func retargetCollectionSlots(from oldID: UUID, to survivorID: UUID, in context: ModelContext) throws {
        let kind = FavoriteSlotKind.record.rawValue
        let oldSlots = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate { $0.entryKindRaw == kind && $0.entryID == oldID }
        ))
        for old in oldSlots {
            let collectionID = old.collectionID
            let survivorSlots = try context.fetch(FetchDescriptor<CollectionSlot>(
                predicate: #Predicate {
                    $0.collectionID == collectionID && $0.entryKindRaw == kind && $0.entryID == survivorID
                }
            ))
            if let kept = survivorSlots.first {
                kept.position = min(kept.position, old.position)
                context.delete(old)
            } else {
                old.entryID = survivorID
            }
            try compactCollectionSlots(collectionID: collectionID, in: context)
        }
    }

    /// After V2→V3 or when slots are missing: assign positions from recency once.
    fileprivate static func seedPinboardOrderIfNeeded(in context: ModelContext) throws {
        try seedFavoriteSlotsIfNeeded(in: context)
        try seedCollectionSlotsIfNeeded(in: context)
    }

    private static func seedFavoriteSlotsIfNeeded(in context: ModelContext) throws {
        let slotCount = try context.fetchCount(FetchDescriptor<FavoriteSlot>())
        let favoriteRecords = try context.fetch(FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        ))
        let favoriteStacks = try context.fetch(FetchDescriptor<StackModel>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        ))
        guard slotCount == 0, !favoriteRecords.isEmpty || !favoriteStacks.isEmpty else {
            // Drop orphan slots / ensure every favorite has a slot.
            try reconcileFavoriteSlots(records: favoriteRecords, stacks: favoriteStacks, in: context)
            return
        }
        var ranked: [(kind: FavoriteSlotKind, id: UUID, date: Date)] = favoriteRecords.map {
            (.record, $0.id, $0.lastCopiedAt)
        }
        ranked += favoriteStacks.map { (.stack, $0.id, $0.lastUsedAt) }
        ranked.sort { $0.date > $1.date }
        for (index, item) in ranked.enumerated() {
            context.insert(FavoriteSlot(entryKindRaw: item.kind.rawValue, entryID: item.id, position: index))
        }
    }

    private static func reconcileFavoriteSlots(
        records: [ClipboardRecord],
        stacks: [StackModel],
        in context: ModelContext
    ) throws {
        let expectedRecords = Set(records.map(\.id))
        let expectedStacks = Set(stacks.map(\.id))
        let slots = try context.fetch(FetchDescriptor<FavoriteSlot>())
        var changed = false
        for slot in slots {
            switch FavoriteSlotKind(rawValue: slot.entryKindRaw) {
            case .record:
                if !expectedRecords.contains(slot.entryID) {
                    context.delete(slot)
                    changed = true
                }
            case .stack:
                if !expectedStacks.contains(slot.entryID) {
                    context.delete(slot)
                    changed = true
                }
            case nil:
                context.delete(slot)
                changed = true
            }
        }
        let remaining = try context.fetch(FetchDescriptor<FavoriteSlot>())
        let haveRecords = Set(remaining.filter { $0.entryKindRaw == FavoriteSlotKind.record.rawValue }.map(\.entryID))
        let haveStacks = Set(remaining.filter { $0.entryKindRaw == FavoriteSlotKind.stack.rawValue }.map(\.entryID))
        var next = remaining.map(\.position).max().map { $0 + 1 } ?? 0
        for record in records where !haveRecords.contains(record.id) {
            context.insert(FavoriteSlot(entryKindRaw: FavoriteSlotKind.record.rawValue, entryID: record.id, position: next))
            next += 1
            changed = true
        }
        for stack in stacks where !haveStacks.contains(stack.id) {
            context.insert(FavoriteSlot(entryKindRaw: FavoriteSlotKind.stack.rawValue, entryID: stack.id, position: next))
            next += 1
            changed = true
        }
        if changed { try compactFavoriteSlots(in: context) }
    }

    private static func seedCollectionSlotsIfNeeded(in context: ModelContext) throws {
        let collections = try context.fetch(FetchDescriptor<CollectionModel>())
        for collection in collections {
            let id = collection.id
            let slotCount = try context.fetchCount(FetchDescriptor<CollectionSlot>(
                predicate: #Predicate { $0.collectionID == id }
            ))
            let recordTags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.collectionID == id }))
            let stackTags = try context.fetch(FetchDescriptor<StackTag>(predicate: #Predicate { $0.collectionID == id }))
            guard slotCount == 0, !recordTags.isEmpty || !stackTags.isEmpty else {
                try reconcileCollectionSlots(
                    collectionID: id,
                    recordTags: recordTags,
                    stackTags: stackTags,
                    in: context
                )
                continue
            }
            var ranked: [(kind: FavoriteSlotKind, id: UUID, date: Date)] = []
            for tag in recordTags {
                let recordID = tag.recordID
                let date = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.id == recordID })).first?.lastCopiedAt
                    ?? .distantPast
                ranked.append((.record, recordID, date))
            }
            for tag in stackTags {
                let stackID = tag.stackID
                let date = try context.fetch(FetchDescriptor<StackModel>(predicate: #Predicate { $0.id == stackID })).first?.lastUsedAt
                    ?? .distantPast
                ranked.append((.stack, stackID, date))
            }
            ranked.sort { $0.date > $1.date }
            for (index, item) in ranked.enumerated() {
                context.insert(CollectionSlot(
                    collectionID: id,
                    entryKindRaw: item.kind.rawValue,
                    entryID: item.id,
                    position: index
                ))
            }
        }
    }

    private static func reconcileCollectionSlots(
        collectionID: UUID,
        recordTags: [RecordTag],
        stackTags: [StackTag],
        in context: ModelContext
    ) throws {
        let expectedRecords = Set(recordTags.map(\.recordID))
        let expectedStacks = Set(stackTags.map(\.stackID))
        let slots = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate { $0.collectionID == collectionID }
        ))
        var changed = false
        for slot in slots {
            switch FavoriteSlotKind(rawValue: slot.entryKindRaw) {
            case .record:
                if !expectedRecords.contains(slot.entryID) {
                    context.delete(slot)
                    changed = true
                }
            case .stack:
                if !expectedStacks.contains(slot.entryID) {
                    context.delete(slot)
                    changed = true
                }
            case nil:
                context.delete(slot)
                changed = true
            }
        }
        let remaining = try context.fetch(FetchDescriptor<CollectionSlot>(
            predicate: #Predicate { $0.collectionID == collectionID }
        ))
        let haveRecords = Set(remaining.filter { $0.entryKindRaw == FavoriteSlotKind.record.rawValue }.map(\.entryID))
        let haveStacks = Set(remaining.filter { $0.entryKindRaw == FavoriteSlotKind.stack.rawValue }.map(\.entryID))
        var next = remaining.map(\.position).max().map { $0 + 1 } ?? 0
        for id in expectedRecords where !haveRecords.contains(id) {
            context.insert(CollectionSlot(
                collectionID: collectionID,
                entryKindRaw: FavoriteSlotKind.record.rawValue,
                entryID: id,
                position: next
            ))
            next += 1
            changed = true
        }
        for id in expectedStacks where !haveStacks.contains(id) {
            context.insert(CollectionSlot(
                collectionID: collectionID,
                entryKindRaw: FavoriteSlotKind.stack.rawValue,
                entryID: id,
                position: next
            ))
            next += 1
            changed = true
        }
        if changed { try compactCollectionSlots(collectionID: collectionID, in: context) }
    }
}

enum FavoriteSlotKind: String {
    case record
    case stack
}
