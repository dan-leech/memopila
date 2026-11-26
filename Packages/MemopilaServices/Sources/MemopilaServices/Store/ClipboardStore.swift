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
        let schema = Schema(versionedSchema: StoreSchemaV4.self)
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        container = try Self.openContainer(schema: schema, configuration: configuration)
        // Seed FavoriteSlot / tag positions once after V2→V3 (lightweight migrate leaves positions at 0).
        let context = ModelContext(container)
        try? Self.seedPinboardOrderIfNeeded(in: context)
        try? context.save()
    }

    /// Staged `StoreMigrationPlan` first (V1→V4). If the on-disk model hash is unknown — typical after
    /// additive properties on shared `@Model` types changed every VersionedSchema checksum — fall back
    /// to inferred lightweight migration (no plan). A later launch with the plan then succeeds.
    private static func openContainer(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: [configuration])
        } catch {
            return try ModelContainer(for: schema, configurations: [configuration])
        }
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
        limits: RetentionLimits,
        protectingRecords: Set<UUID> = []
    ) -> IngestResult {
        // Canonicalize before address: MCS1 / soft-dedup must not trust client colour bytes (§8.5).
        let snapshot = ColorPayload.normalizedSnapshot(snapshot)
        var enrichment = enrichment
        if ColorPayload.identity(of: snapshot.items) != nil {
            enrichment = Self.enrichmentAligned(with: snapshot, base: enrichment)
        }
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
                // colorHex / preview are caches: a hard MCS1 hit must not leave them nil forever
                // (format picker / soft-dedup / swatch all trust the cache, not the payload).
                backfillColorMetadata(on: existing, from: enrichment, snapshot: snapshot)
                existing.searchText = Self.searchText(for: existing)
                try context.save()
                return .merged(existing.id)
            }

            // Same sRGB + paste format, different NSColor archive bytes (Color Picker vs #hex text).
            // Identity from payload after normalize — not displayType / enrichment alone.
            // Upgrade the survivor to the inbound canonical payload so Choose/MCS1 converge.
            if let identity = ColorPayload.identity(of: snapshot.items),
               let existing = try fetchColorDuplicate(
                identity: identity,
                excludingHash: snapshot.contentHash,
                excludingID: nil,
                in: context
               ) {
                apply(DedupMerge.merge(try metadata(of: existing, in: context), with: observation), to: existing)
                if let kind = snapshot.sensitiveKind { existing.sensitiveKind = kind.rawValue }
                if existing.contentHash != snapshot.contentHash {
                    staleGuard.recordTombstone(contentHash: existing.contentHash, opSeq: readerSeq)
                    try replaceColorPayload(of: existing, with: snapshot, enrichment: enrichment, in: context)
                } else {
                    backfillColorMetadata(on: existing, from: enrichment, snapshot: snapshot)
                    existing.searchText = Self.searchText(for: existing)
                    try context.save()
                }
                return .merged(existing.id)
            }

            // Undo-window / open-editor ids are treated as pinned so quota cannot erase them.
            let candidates = Self.pinProtected(try retentionCandidates(in: context), protectingRecords)
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
            // Payload SSOT: enrichment hex is a cache hint only.
            record.colorHex = Self.colorHexFromItems(snapshot.items)
                ?? Self.canonicalColorHex(enrichment.colorHex)
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
            // Two saves on purpose. External storage writes `UUID.interim` then renames; deleting
            // other external blobs in the *same* save races that rename. (Bare "Failed to clone
            // … .interim" with the final `UUID` file present is often spurious CoreData noise —
            // DTS; the dangerous case is insert+delete competing in one transaction.)
            try context.save()
            if !victims.isEmpty {
                try deleteRecords(ids: victims, in: context)
                try context.save()
            }
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
            sortBy: Self.sortDescriptors(for: query.sort)
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
                sortBy: Self.sortDescriptors(for: query.sort)
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
        let payloadItems = Self.items(from: rows)
        // Payload / caches that already mean colour — not `normalized` (that promotes lone CSS;
        // promotion belongs in ingest / promoteOrphan / editText, not open-details heal).
        let looksColour = DisplayType(rawValue: record.displayTypeRaw) == .color
            || record.colorHex != nil
            || record.storedTypes.contains(PasteboardType.color.rawValue)
            || payloadItems.contains { item in item.representations.contains { $0.type == .color } }
        if looksColour {
            try healColorMetadataIfNeeded(record, in: context)
        }
        // Only text rows are read, and none when no text is wanted: an image's payload stays on
        // disk (review finding: every open of a record loaded all of it).
        var text: String?
        if maxTextScalars > 0 {
            // Colour only: pastePlainText also returns ordinary utf8 for non-colour items — do not
            // steal rich-text HTML/RTF extraction. Trimmed CSS SSOT matches RestorePayload.text.
            if looksColour,
               let plain = ColorPayload.pastePlainText(of: payloadItems) {
                text = TextDecoding.prefix(plain, maxScalars: maxTextScalars)
            } else {
                let textTypes = Set(PasteboardType.plainTextTypes.union(PasteboardType.richTextTypes).union([.url]).map(\.rawValue))
                let items = Self.items(from: rows.filter { textTypes.contains($0.uti) })
                text = RichText.plainText(of: items).map { TextDecoding.prefix($0, maxScalars: maxTextScalars) }
            }
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

    /// Preview for Settings lowering `maxAge` / applying age retention: records + stale stacks + cascade.
    public func retentionCutPreview(maxAge: TimeInterval, now: Date = Date()) throws -> (records: Int, stacks: Int, cascade: Int) {
        let context = makeContext()
        let cutoff = now.addingTimeInterval(-maxAge)
        let stacked = try stackedRecordIDs(in: context)
        var recordDesc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { !$0.isFavorite && $0.lastCopiedAt < cutoff })
        recordDesc.propertiesToFetch = [\.id]
        let agedRecords = try context.fetch(recordDesc).map(\.id).filter { !stacked.contains($0) }

        let stacks = try context.fetch(FetchDescriptor<StackModel>())
        let members = try context.fetch(FetchDescriptor<StackMember>())
        let membersByStack = Dictionary(grouping: members, by: \.stackID)
        let recordIDs = Set(members.map(\.recordID))
        var lastCopied: [UUID: Date] = [:]
        if !recordIDs.isEmpty {
            let ids = Array(recordIDs)
            var desc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })
            desc.propertiesToFetch = [\.id, \.lastCopiedAt]
            for record in try context.fetch(desc) {
                lastCopied[record.id] = record.lastCopiedAt
            }
        }
        let staleStacks = stacks.filter { stack in
            guard !stack.isFavorite else { return false }
            let memberDates = (membersByStack[stack.id] ?? []).compactMap { lastCopied[$0.recordID] }
            let freshAt = RetentionPlanner.stackFreshAt(lastUsedAt: stack.lastUsedAt, memberLastCopiedAt: memberDates)
            return freshAt < cutoff
        }
        let staleStackIDs = Set(staleStacks.map(\.id))
        let formerMembers = Set(staleStacks.flatMap { membersByStack[$0.id]?.map(\.recordID) ?? [] })
        // After those stacks go, members still pinned elsewhere or favorite survive.
        let stillStackedElsewhere = Set(
            members.filter { !staleStackIDs.contains($0.stackID) }.map(\.recordID)
        )
        var cascade = 0
        if !formerMembers.isEmpty {
            let ids = Array(formerMembers)
            var desc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })
            desc.propertiesToFetch = [\.id, \.isFavorite]
            for record in try context.fetch(desc) {
                if !record.isFavorite && !stillStackedElsewhere.contains(record.id) {
                    cascade += 1
                }
            }
        }
        // Age-record count already excludes currently stacked; cascade members may overlap agedRecords
        // once stacks drop — report cascade separately for UI copy.
        return (agedRecords.count, staleStacks.count, cascade)
    }

    /// Every record that is a paste-stack member — pin SSOT for UI (not capped `allStacks`).
    public func stackedRecordIDs() throws -> Set<UUID> {
        try stackedRecordIDs(in: makeContext())
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

    /// Align colour `colorHex` / `cardPreview` / `displayType` to the payload (migration / details).
    /// Stale caches used to win over the colour UTI and rewrite channels on Choose. Returns how many changed.
    @discardableResult
    public func backfillMissingColorMetadata() throws -> Int {
        let ids = try colorHealCandidateIDs()
        var changed = 0
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let context = makeContext()
            let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { batch.contains($0.id) }))
            var batchChanged = 0
            for record in records {
                if try healColorMetadataIfNeeded(record, in: context, save: false) {
                    batchChanged += 1
                }
            }
            if batchChanged > 0 {
                try context.save()
                changed += batchChanged
            }
        }
        return changed
    }

    /// Colour displayType / colorHex / storedTypes, or a colour UTI row (stale empty storedTypes).
    /// Launch migration / coalesce — not a hot path.
    private func colorHealCandidateIDs() throws -> [UUID] {
        let type = DisplayType.color.rawValue
        let colorUTI = PasteboardType.color.rawValue
        let context = makeContext()
        var ids = Set<UUID>()
        var descriptor = FetchDescriptor<ClipboardRecord>()
        descriptor.propertiesToFetch = [\.id, \.displayTypeRaw, \.storedTypes, \.colorHex]
        for record in try context.fetch(descriptor) {
            if record.displayTypeRaw == type || record.colorHex != nil || record.storedTypes.contains(colorUTI) {
                ids.insert(record.id)
            }
        }
        // Payload SSOT: empty storedTypes used to hide colour UTI rows from migration forever.
        let repDescriptor = FetchDescriptor<PayloadRepresentation>(
            predicate: #Predicate { $0.uti == colorUTI }
        )
        for rep in try context.fetch(repDescriptor) {
            if let id = rep.record?.id { ids.insert(id) }
        }
        return Array(ids)
    }

    /// Persist colour caches + promote `displayType` / `storedTypes` from payload (SSOT).
    /// `save: false` batches several heals into one caller save.
    @discardableResult
    private func healColorMetadataIfNeeded(
        _ record: ClipboardRecord,
        in context: ModelContext,
        save: Bool = true
    ) throws -> Bool {
        let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        let items = Self.items(from: rows)
        // Payload colour UTI only — `normalized` would treat lone CSS as colour and flip
        // displayType without writing MCS1 colour bytes (that's promoteOrphanCSSColorTextRecords).
        let payloadHasColourUTI = items.contains { item in item.representations.contains { $0.type == .color } }
        let cacheSaysColour = DisplayType(rawValue: record.displayTypeRaw) == .color
            || record.colorHex != nil
            || record.storedTypes.contains(PasteboardType.color.rawValue)
        // Never run pastePlainText fallback on ordinary text — it would rewrite cardPreview.
        guard payloadHasColourUTI || cacheSaysColour else { return false }

        var did = false
        if let hex = resolvedColorHex(of: record), record.colorHex != hex {
            record.colorHex = hex
            did = true
        }
        // Colour paste SSOT only when a colour UTI exists; else keep colorHex / leave preview.
        let plain: String? = payloadHasColourUTI
            ? (ColorPayload.pastePlainText(of: items) ?? record.colorHex)
            : record.colorHex
        if let plain, !plain.isEmpty {
            let preview = record.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if preview != plain {
                record.cardPreview = TextDecoding.prefix(plain, maxScalars: IngestEnrichment.cardPreviewScalars)
                record.textIndex = TextDecoding.prefix(plain, maxScalars: IngestEnrichment.searchScalars)
                record.textLength = plain.count
                record.lineCount = 1
                did = true
            }
        }
        if payloadHasColourUTI {
            let types = Self.distinctTypes(of: items)
            if record.storedTypes != types {
                record.storedTypes = types
                did = true
            }
            if DisplayType(rawValue: record.displayTypeRaw) != .color {
                record.displayTypeRaw = DisplayType.color.rawValue
                did = true
            }
        } else if record.storedTypes.contains(PasteboardType.color.rawValue) {
            // Stale storedTypes claimed colour while rows do not — realign cache to payload.
            let types = Self.distinctTypes(of: items)
            if record.storedTypes != types {
                record.storedTypes = types
                did = true
            }
        }
        guard did else { return false }
        record.searchText = Self.searchText(for: record)
        if save { try context.save() }
        return true
    }

    /// Test seam: insert a text card without `ColorPayload.normalized` (pre-promote CSS orphans).
    func plantTextRecordForTesting(_ text: String, at observedAt: Date = Date(timeIntervalSince1970: 1_000)) throws -> UUID {
        let items = [CanonicalItem([.bytes(.utf8PlainText, Data(text.utf8))])]
        precondition(DisplayType.classify(items) == .text)
        let context = makeContext()
        let record = ClipboardRecord(
            displayTypeRaw: DisplayType.text.rawValue,
            firstCopiedAt: observedAt,
            lastCopiedAt: observedAt,
            copyCount: 1,
            contentHash: MCS1.contentHash(of: items),
            hashSchemeVersion: MCS1.hashSchemeVersion,
            storageFormatVersion: PayloadIntegrity.storageFormatVersion,
            payloadSizeBytes: MCS1.payloadSize(of: items)
        )
        record.cardPreview = TextDecoding.prefix(text, maxScalars: IngestEnrichment.cardPreviewScalars)
        record.textIndex = TextDecoding.prefix(text, maxScalars: IngestEnrichment.searchScalars)
        record.textLength = text.count
        record.lineCount = 1
        record.storedTypes = Self.distinctTypes(of: items)
        record.searchText = Self.searchText(for: record)
        context.insert(record)
        insertRepresentations(of: items, for: record, in: context)
        try context.save()
        return record.id
    }

    /// Test seam: leave colour payload but set a stale `displayType` (type-lag orphan).
    func corruptColorDisplayTypeForTesting(_ id: UUID, to type: DisplayType) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        record.displayTypeRaw = type.rawValue
        try context.save()
    }

    /// Test seam: clear colour caches while leaving colour UTI rows on disk.
    func corruptColorCachesForTesting(_ id: UUID, displayType: DisplayType, storedTypes: [String], colorHex: String?) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        record.displayTypeRaw = displayType.rawValue
        record.storedTypes = storedTypes
        record.colorHex = colorHex
        try context.save()
    }

    /// Test seam: insert a colour card without soft-merge so migration coalesce can plant MCS1 forks.
    func plantColorForkForTesting(_ snapshot: OwnedSnapshot, enrichment: IngestEnrichment) throws -> UUID {
        precondition(snapshot.displayType == .color)
        let context = makeContext()
        let observation = CaptureObservation(
            observedAt: snapshot.observedAt,
            sourceAppBundleID: snapshot.identity.bundleID,
            sourceAppName: enrichment.sourceAppName,
            sourceURL: snapshot.sourceURL,
            sourceWindowTitle: nil,
            retentionMinutes: snapshot.settings.retentionMinutes
        )
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
        record.lineCount = enrichment.lineCount
        record.colorHex = enrichment.colorHex
        record.storedTypes = Self.distinctTypes(of: snapshot.items)
        record.skippedTypes = snapshot.skippedTypes.map(\.rawValue)
        record.ocrStateRaw = Self.initialRecognitionState(for: snapshot).rawValue
        record.searchText = Self.searchText(for: record)
        context.insert(record)
        insertRepresentations(of: snapshot.items, for: record, in: context)
        try context.save()
        return record.id
    }

    /// Collapse colour cards that share the same sRGB hex + paste format but forked MCS1
    /// (legacy NSColor archives). Keeps one survivor per identity, upgrades it to `colorItems`.
    /// Includes type-lag orphans (colour UTI / colorHex with stale displayType) so they join the
    /// same identity bucket after heal promotes them — not only rows already marked `.color`.
    /// Returns how many duplicate cards were deleted.
    @discardableResult
    public func coalesceDuplicateColorRecords(opSeq: Int) throws -> Int {
        let ids = try colorHealCandidateIDs()
        guard ids.count > 1 else { return 0 }
        let context = makeContext()
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))

        var groups: [String: [ClipboardRecord]] = [:]
        for record in records {
            _ = try healColorMetadataIfNeeded(record, in: context, save: false)
            guard let identity = colorIdentity(of: record) else { continue }
            groups["\(identity.hex)|\(identity.format.rawValue)", default: []].append(record)
        }
        try context.save()

        var deleted = 0
        for (_, group) in groups where group.count > 1 {
            deleted += try coalesceColorGroup(group, opSeq: opSeq)
        }
        return deleted
    }

    /// One (hex, format) bucket: merge extras into a survivor and canonicalize its payload.
    private func coalesceColorGroup(_ group: [ClipboardRecord], opSeq: Int) throws -> Int {
        let context = makeContext()
        let ids = group.map(\.id)
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))
        guard records.count > 1 else { return 0 }

        guard let identity = records.lazy.compactMap({ self.colorIdentity(of: $0) }).first,
              let values = ColorValues(hex: identity.hex) else { return 0 }
        let format = identity.format
        let hex = identity.hex
        let canonical = PasteboardWriter.colorItems(values, textFormat: format)
        guard !canonical.isEmpty else { return 0 }
        let canonicalHash = MCS1.contentHash(of: canonical)

        // Prefer a card that already holds the canonical hash; else favorite; else earliest copy.
        let survivor = records.first { $0.contentHash == canonicalHash }
            ?? records.first(where: \.isFavorite)
            ?? records.sorted { a, b in
                if a.firstCopiedAt != b.firstCopiedAt { return a.firstCopiedAt < b.firstCopiedAt }
                return a.id.uuidString < b.id.uuidString
            }.first
        guard let survivor else { return 0 }
        let victims = records.filter { $0.id != survivor.id }
        guard !victims.isEmpty else { return 0 }

        try saveOrRollback(context) {
            for victim in victims {
                staleGuard.recordTombstone(contentHash: victim.contentHash, opSeq: opSeq)
                let victimUse = victim.useCount
                apply(
                    DedupMerge.mergeEdited(try metadata(of: victim, in: context), into: try metadata(of: survivor, in: context)),
                    to: survivor
                )
                survivor.useCount += victimUse
                if survivor.customTitle == nil { survivor.customTitle = victim.customTitle }
                let survivorID = survivor.id
                let victimID = victim.id
                let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == victimID }))
                let existing = Set(
                    try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == survivorID }))
                        .map(\.collectionID)
                )
                for tag in tags where !existing.contains(tag.collectionID) {
                    context.insert(RecordTag(recordID: survivorID, collectionID: tag.collectionID))
                }
                try retargetStackMembers(from: victimID, to: survivorID, in: context)
                try Self.retargetFavoriteSlot(from: victimID, to: survivorID, in: context)
                try Self.retargetCollectionSlots(from: victimID, to: survivorID, in: context)
            }
            try deleteRecords(ids: victims.map(\.id), in: context)
            survivor.colorHex = hex
            survivor.searchText = Self.searchText(for: survivor)
        }

        // Canonicalize the survivor (no-op when it already holds colorItems for this format).
        _ = try applyColorPasteFormat(survivor.id, format: format, opSeq: opSeq)
        return victims.count
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
                // Colour UTI / colorHex: text-only classify would demote to .text and leave a
                // type-lag orphan (Predicate Colors filter + looksLikeColor diverge from payload).
                let hasColourUTI = record.representations.contains { $0.uti == PasteboardType.color.rawValue }
                    || record.storedTypes.contains(PasteboardType.color.rawValue)
                if hasColourUTI || record.colorHex != nil {
                    if hasColourUTI, record.displayTypeRaw != DisplayType.color.rawValue {
                        record.displayTypeRaw = DisplayType.color.rawValue
                        changed += 1
                    }
                    continue
                }
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
            // Colour only: pastePlainText also returns ordinary utf8 (trimmed) for non-colour —
            // do not change plain-text Duplicate As whitespace for normal text cards.
            let isColour = items.contains { item in item.representations.contains { $0.type == .color } }
                || ColorPayload.identity(of: items) != nil
            let text = isColour
                ? (ColorPayload.pastePlainText(of: items) ?? RichText.plainText(of: items))
                : RichText.plainText(of: items)
            return RestorePayload(items: items, sourceBundleID: record.lastSourceAppBundleID, text: text)
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
        descriptor.propertiesToFetch = [\.displayTypeRaw, \.storedTypes, \.colorHex]
        let colorUTI = PasteboardType.color.rawValue
        var present = Set<DisplayType>()
        for record in try context.fetch(descriptor) {
            if let type = DisplayType(rawValue: record.displayTypeRaw) {
                present.insert(type)
            }
            // Type-lag orphans: Colors chip before launch heal promotes displayType.
            if record.colorHex != nil || record.storedTypes.contains(colorUTI) {
                present.insert(.color)
            }
        }
        return DisplayType.allCases.filter(present.contains)
    }

    // MARK: - Mutations

    /// After a confirmed Restore: move to the top, bump Choose `useCount`, `copyCount` unchanged (§3.4).
    public func markUsed(_ id: UUID, at date: Date) throws {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return }
        record.lastCopiedAt = max(record.lastCopiedAt, date)
        record.useCount += 1
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
    /// Returns ids deleted by this call (count-cap eviction and/or age of *this* record only).
    /// `protectingRecords` — Undo-window / open editor ids must not be collateral victims.
    @discardableResult
    public func setFavorite(
        _ id: UUID,
        _ isFavorite: Bool,
        limits: RetentionLimits,
        now: Date,
        protectingRecords: Set<UUID> = []
    ) throws -> Set<UUID> {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return [] }
        var deleted = Set<UUID>()
        try saveOrRollback(context) {
            record.isFavorite = isFavorite
            if isFavorite {
                record.expiresAt = nil
                try Self.insertFavoriteSlotFront(kind: .record, entryID: id, in: context)
                return
            }
            try Self.removeFavoriteSlot(kind: .record, entryID: id, in: context)
            let candidates = Self.pinProtected(try retentionCandidates(in: context), protectingRecords)
            var victims = RetentionPlanner.planUnfavorite(id, existing: candidates, maxCount: limits.maxCount)
            // Age-delete only the unfavorited record (UI asks for it) — never every aged non-pinned.
            let planned = Set(victims)
            victims += RetentionPlanner.planAge(existing: candidates, now: now, maxAge: limits.maxAge)
                .filter { $0 == id && !planned.contains($0) }
            if !victims.isEmpty {
                try deleteRecords(ids: victims, in: context)
                deleted = Set(victims)
            }
        }
        return deleted
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
        // displayType / storedTypes can lag empty while colour UTI rows remain — payload is SSOT.
        // Lone CSS *without* a colour UTI / colorHex stays editable so edit can promote via normalize.
        let editRows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        let editItems = Self.items(from: editRows)
        let hasColourUTI = record.storedTypes.contains(PasteboardType.color.rawValue)
            || editItems.contains { item in item.representations.contains { $0.type == .color } }
        if hasColourUTI || record.colorHex != nil {
            return .rejected("Colour records use the paste-format picker, not the text editor.")
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

        // Same choke as ingest: lone CSS text must become a Color card (else Color Picker forks MCS1).
        let items = ColorPayload.normalized([CanonicalItem(representations)])
        let size = MCS1.payloadSize(of: items)
        guard size <= maxBytes else { return .rejected("The text is larger than the item size limit.") }
        let hash = MCS1.contentHash(of: items)
        guard hash != record.contentHash else { return .updated }
        staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq)

        if let survivor = try fetchRecord(withHash: hash, in: context), survivor.id != id {
            try saveOrRollback(context) {
                let editedUseCount = record.useCount
                apply(DedupMerge.mergeEdited(try metadata(of: record, in: context), into: try metadata(of: survivor, in: context)), to: survivor)
                survivor.useCount += editedUseCount
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

        // Soft-merge into an existing Color card when edit promoted lone CSS to the same identity.
        if let identity = ColorPayload.identity(of: items),
           let soft = try fetchColorDuplicate(
            identity: identity, excludingHash: record.contentHash, excludingID: id, in: context
           ),
           soft.id != id {
            let survivorID = soft.id
            try saveOrRollback(context) {
                let editedUseCount = record.useCount
                apply(DedupMerge.mergeEdited(try metadata(of: record, in: context), into: try metadata(of: soft, in: context)), to: soft)
                soft.useCount += editedUseCount
                if soft.customTitle == nil { soft.customTitle = record.customTitle }
                soft.searchText = Self.searchText(for: soft)
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
            // Upgrade legacy survivor UTI to the edited canonical colour (no-op when already matching).
            _ = try applyColorPasteFormat(survivorID, format: identity.format, opSeq: opSeq)
            return .merged(into: survivorID)
        }

        // Stage new external blobs unlinked, then swap in a second save. Rules:
        // 1) Never insert+delete external storage in one save (interim/rename race).
        // 2) Every committed save must leave the record PayloadIntegrity-verifiable — so do not
        //    attach new rows or rewrite hash/size while obsolete rows still hang off the record.
        let obsolete = Array(record.representations)
        let staged = stageRepresentations(of: items, in: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        do {
            try saveOrRollback(context) {
                for row in obsolete { context.delete(row) }
                for model in staged {
                    model.record = record
                }
                record.contentHash = hash
                record.payloadSizeBytes = size
                // As for a copy: formatting that says nothing makes it text (`FormattingSignificance`);
                // lone CSS promotes to colour via ColorPayload.normalized above.
                let classified = DisplayType.classify(items)
                record.displayTypeRaw = classified.rawValue
                record.storedTypes = Self.distinctTypes(of: items)
                record.skippedTypes = []
                // Edited text is checked like a copy: a token typed in is masked, and expires under
                // *Delete after* (review findings).
                let secret = secretPolicy == .off ? nil : SecretDetector.detectMatch(text, kinds: secretKinds)
                if classified == .color, let identity = ColorPayload.identity(of: items) {
                    let plain = ColorPayload.pastePlainText(of: items) ?? identity.hex
                    record.cardPreview = TextDecoding.prefix(plain, maxScalars: IngestEnrichment.cardPreviewScalars)
                    record.textIndex = TextDecoding.prefix(plain, maxScalars: IngestEnrichment.searchScalars)
                    record.textLength = plain.count
                    record.lineCount = 1
                    record.colorHex = identity.hex
                    record.sensitiveKind = nil
                } else {
                    record.textIndex = TextDecoding.prefix(text, maxScalars: IngestEnrichment.searchScalars)
                    record.textLength = text.count
                    record.lineCount = TextStats.lineCount(text)
                    if let secret, secret.isEmbedded {
                        record.cardPreview = TextDecoding.prefix(secret.matched, maxScalars: IngestEnrichment.cardPreviewScalars)
                    } else {
                        record.cardPreview = TextDecoding.prefix(text, maxScalars: IngestEnrichment.cardPreviewScalars)
                    }
                    record.sensitiveKind = secret?.kind.rawValue
                    record.colorHex = nil
                }
                let pinned = try record.isFavorite || stackedRecordIDs(in: context).contains(id)
                if secret != nil, case .deleteAfter(let minutes) = secretPolicy, !pinned {
                    let expiry = now.addingTimeInterval(TimeInterval(minutes) * 60)
                    record.expiresAt = min(record.expiresAt ?? expiry, expiry)
                }
                record.editedAt = Date()
                record.searchText = Self.searchText(for: record)
            }
        } catch {
            // Save #1 already committed staged blobs; drop them so a failed swap does not leak.
            for model in staged where model.record == nil { context.delete(model) }
            try? context.save()
            throw error
        }
        return .updated
    }

    /// Persist canonical `colorItems` when the payload is (or promotes to) a colour, so clipboard
    /// writes match stored MCS1 (§1 / §8.5). Safe no-op for non-colour — callers need not gate on
    /// `displayType` (that cache lagged orphans and skipped canonicalize).
    /// Returns the live id (after soft-merge) and the items to put on the pasteboard.
    public func ensureCanonicalColorRecord(_ id: UUID, opSeq: Int) throws -> (id: UUID, items: [CanonicalItem], sourceBundleID: String?) {
        let payload = try payload(for: id)
        let normalized = ColorPayload.normalized(payload.items)
        guard let identity = ColorPayload.identity(of: normalized) else {
            return (id, payload.items, payload.sourceBundleID)
        }
        // Always apply: even when bytes already match, hash-noop must still heal displayType/caches.
        switch try applyColorPasteFormat(id, format: identity.format, opSeq: opSeq) {
        case .updated:
            let fresh = try self.payload(for: id)
            return (id, fresh.items, fresh.sourceBundleID)
        case .merged(let into):
            let fresh = try self.payload(for: into)
            return (into, fresh.items, fresh.sourceBundleID)
        case .rejected(let message):
            throw StoreError.unreadable(message)
        }
    }

    /// Change the CSS paste string on a Color card; rebuilds canonical `colorItems` (§8.5).
    /// Choose uses this so the card label and MCS1 stay aligned with what was written.
    public func applyColorPasteFormat(_ id: UUID, format: ColorPasteFormat, opSeq: Int) throws -> EditResult {
        let context = makeContext()
        guard let record = try fetchRecord(id, in: context) else { return .rejected("The record no longer exists.") }
        let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        let existingItems = Self.items(from: rows)
        let normalizedExisting = ColorPayload.normalized(existingItems)
        // Any looksLikeColor signal or promotable lone CSS — displayType alone missed colorHex /
        // colour-UTI type-lag while the format picker still treated the card as colour.
        let hasColourUTI = existingItems.contains { item in item.representations.contains { $0.type == .color } }
            || record.storedTypes.contains(PasteboardType.color.rawValue)
        let isColor = DisplayType(rawValue: record.displayTypeRaw) == .color
        let promotable = ColorPayload.identity(of: normalizedExisting) != nil
        guard isColor || promotable || record.colorHex != nil || hasColourUTI else {
            return .rejected("Only colour records have a paste format.")
        }
        // Payload hex wins; cache only when the UTI is unreadable (nil colorHex used to reject).
        let hex = resolvedColorHex(of: record)
            ?? ColorPayload.identity(of: normalizedExisting)?.hex
        guard let hex, let values = ColorValues(hex: hex) else {
            return .rejected("The colour could not be read.")
        }
        if record.colorHex != hex { record.colorHex = hex }
        // Always rebuild via colorItems: matching CSS with a legacy / reordered UTI still forked MCS1.
        let items = PasteboardWriter.colorItems(values, textFormat: format)
        guard !items.isEmpty else { return .rejected("The colour could not be written.") }
        let text = format.string(from: values)
        let hash = MCS1.contentHash(of: items)
        guard hash != record.contentHash else {
            // Bytes already canonical — still heal caches (orphan promote / empty storedTypes).
            if record.displayTypeRaw != DisplayType.color.rawValue {
                record.displayTypeRaw = DisplayType.color.rawValue
            }
            let types = Self.distinctTypes(of: items)
            if record.storedTypes != types { record.storedTypes = types }
            let preview = record.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if preview != text {
                record.cardPreview = TextDecoding.prefix(text, maxScalars: IngestEnrichment.cardPreviewScalars)
                record.textIndex = TextDecoding.prefix(text, maxScalars: IngestEnrichment.searchScalars)
                record.textLength = text.count
                record.lineCount = 1
            }
            record.searchText = Self.searchText(for: record)
            if context.hasChanges { try context.save() }
            return .updated
        }
        let size = MCS1.payloadSize(of: items)
        staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq)

        // Hard MCS1 hit, or another card with the same sRGB + paste format (legacy archive fork).
        let wantIdentity = ColorPayload.Identity(hex: hex, format: format)
        let survivor = try fetchRecord(withHash: hash, in: context).flatMap { $0.id != id ? $0 : nil }
            ?? {
                guard let soft = try? fetchColorDuplicate(
                    identity: wantIdentity, excludingHash: record.contentHash, excludingID: id, in: context
                ), soft.id != id else { return nil }
                return soft
            }()
        if let survivor {
            let survivorID = survivor.id
            let needsPayloadUpgrade = survivor.contentHash != hash
            try saveOrRollback(context) {
                let editedUseCount = record.useCount
                apply(DedupMerge.mergeEdited(try metadata(of: record, in: context), into: try metadata(of: survivor, in: context)), to: survivor)
                survivor.useCount += editedUseCount
                survivor.editedAt = Date()
                if survivor.customTitle == nil { survivor.customTitle = record.customTitle }
                survivor.searchText = Self.searchText(for: survivor)
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
            // Soft survivor may still hold a legacy UTI — upgrade it to the format we just chose.
            if needsPayloadUpgrade {
                let upgrade = try applyColorPasteFormat(survivorID, format: format, opSeq: opSeq)
                if case .merged(let into) = upgrade { return .merged(into: into) }
            }
            return .merged(into: survivorID)
        }

        let obsolete = Array(record.representations)
        let staged = stageRepresentations(of: items, in: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        do {
            try saveOrRollback(context) {
                for row in obsolete { context.delete(row) }
                for model in staged { model.record = record }
                record.contentHash = hash
                record.payloadSizeBytes = size
                record.cardPreview = TextDecoding.prefix(text, maxScalars: IngestEnrichment.cardPreviewScalars)
                record.textIndex = TextDecoding.prefix(text, maxScalars: IngestEnrichment.searchScalars)
                record.textLength = text.count
                record.lineCount = 1
                record.editedAt = Date()
                record.displayTypeRaw = DisplayType.color.rawValue
                record.storedTypes = Self.distinctTypes(of: items)
                record.skippedTypes = []
                record.searchText = Self.searchText(for: record)
            }
        } catch {
            for model in staged where model.record == nil { context.delete(model) }
            try? context.save()
            throw error
        }
        return .updated
    }

    /// Age, short retention and count cap (§6). Returns when the next expiry is due.
    /// Also age-deletes non-favorite stacks whose freshest activity is older than `maxAge`.
    /// `protectingStacks` — open editor / armed Choose must not vanish under the user.
    /// `protectingRecords` — Undo-window / open Edit Record ids must not be purged mid-window.
    @discardableResult
    public func applyRetention(
        limits: RetentionLimits,
        now: Date,
        protectingStacks: Set<UUID> = [],
        protectingRecords: Set<UUID> = []
    ) throws -> Date? {
        let context = makeContext()
        var next: Date?
        try saveOrRollback(context) {
            try ageDeleteStaleStacks(
                maxAge: limits.maxAge, now: now, protecting: protectingStacks, in: context
            )
            let candidates = Self.pinProtected(try retentionCandidates(in: context), protectingRecords)
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
                try deleteRecords(ids: Array(removed), in: context)
            }
            next = RetentionPlanner.nextExpiry(existing: candidates.filter { !removed.contains($0.id) })
        }
        return next
    }

    /// Undo / open-editor protection: same exclusion as favorites for victim planning.
    private static func pinProtected(
        _ candidates: [RetentionCandidate],
        _ protecting: Set<UUID>
    ) -> [RetentionCandidate] {
        guard !protecting.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard protecting.contains(candidate.id), !candidate.isPinned else { return candidate }
            return RetentionCandidate(
                id: candidate.id,
                isFavorite: candidate.isFavorite,
                lastCopiedAt: candidate.lastCopiedAt,
                payloadSizeBytes: candidate.payloadSizeBytes,
                expiresAt: candidate.expiresAt,
                isPinned: true
            )
        }
    }

    /// Non-favorite stacks with `freshAt < now - maxAge` go as a unit; cascade former members
    /// that are not favorite and not in any surviving stack.
    private func ageDeleteStaleStacks(
        maxAge: TimeInterval,
        now: Date,
        protecting: Set<UUID>,
        in context: ModelContext
    ) throws {
        let cutoff = now.addingTimeInterval(-maxAge)
        let stacks = try context.fetch(FetchDescriptor<StackModel>())
        guard !stacks.isEmpty else { return }
        let members = try context.fetch(FetchDescriptor<StackMember>())
        let membersByStack = Dictionary(grouping: members, by: \.stackID)
        let recordIDs = Set(members.map(\.recordID))
        var lastCopied: [UUID: Date] = [:]
        if !recordIDs.isEmpty {
            let ids = Array(recordIDs)
            var desc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })
            desc.propertiesToFetch = [\.id, \.lastCopiedAt]
            for record in try context.fetch(desc) {
                lastCopied[record.id] = record.lastCopiedAt
            }
        }

        let stale = stacks.filter { stack in
            guard !stack.isFavorite, !protecting.contains(stack.id) else { return false }
            let memberDates = (membersByStack[stack.id] ?? []).compactMap { lastCopied[$0.recordID] }
            let freshAt = RetentionPlanner.stackFreshAt(lastUsedAt: stack.lastUsedAt, memberLastCopiedAt: memberDates)
            return freshAt < cutoff
        }
        guard !stale.isEmpty else { return }

        let staleStackIDs = stale.map(\.id)
        let formerMemberIDs = Set(staleStackIDs.flatMap { membersByStack[$0]?.map(\.recordID) ?? [] })
        try deleteStackRows(ids: staleStackIDs, in: context)

        let stillStacked = try stackedRecordIDs(in: context)
        var cascade: [UUID] = []
        if !formerMemberIDs.isEmpty {
            let ids = Array(formerMemberIDs)
            var desc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) })
            desc.propertiesToFetch = [\.id, \.isFavorite]
            for record in try context.fetch(desc) {
                if !record.isFavorite && !stillStacked.contains(record.id) {
                    cascade.append(record.id)
                }
            }
        }
        if !cascade.isEmpty {
            try deleteRecords(ids: cascade, in: context)
        }
    }

    /// Stack entity + membership / tags / pinboard slots (not member records).
    private func deleteStackRows(ids: [UUID], in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        try context.delete(model: StackMember.self, where: #Predicate { ids.contains($0.stackID) })
        try context.delete(model: StackTag.self, where: #Predicate { ids.contains($0.stackID) })
        let kind = FavoriteSlotKind.stack.rawValue
        try context.delete(model: FavoriteSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
        try context.delete(model: CollectionSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
        try context.delete(model: StackModel.self, where: #Predicate { ids.contains($0.id) })
        try Self.compactFavoriteSlots(in: context)
        try Self.compactAllCollectionSlots(in: context)
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
        // Race with deleteCollection must not orphan RecordTag / CollectionSlot.
        if isMember, try fetchCollection(collectionID, in: context) == nil { return }
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

    /// Stacks matching `query`, hard-capped after filter (P22). Not a paged record fetch.
    /// `excluding` — Undo-hidden record ids; store recomputes face (same as `stackSnapshot`).
    public func stacks(
        _ query: HistoryQuery,
        limit: Int = 200,
        excluding: Set<UUID> = []
    ) throws -> [StackCard] {
        let context = makeContext()
        let models = try fetchStackModels(matching: query, in: context)
        let stackIDs = Set(models.map(\.id))
        let members = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { stackIDs.contains($0.stackID) }
        ))
        let tags = try context.fetch(FetchDescriptor<StackTag>(
            predicate: #Predicate { stackIDs.contains($0.stackID) }
        ))
        let visibleMembers = members.filter { !excluding.contains($0.recordID) }
        let membersByStack = Dictionary(grouping: visibleMembers, by: \.stackID)
        let tagsByStack = Dictionary(grouping: tags, by: \.stackID)
        let recordMeta = try stackRecordMeta(for: visibleMembers.map(\.recordID), in: context)

        let matched = models.compactMap { stack -> StackCard? in
            let card = Self.stackCard(
                stack,
                members: membersByStack[stack.id] ?? [],
                tags: tagsByStack[stack.id] ?? [],
                recordMeta: recordMeta
            )
            let liveMeta = (membersByStack[stack.id] ?? []).compactMap { recordMeta[$0.recordID] }
            guard stackMatches(card, members: liveMeta, query: query) else { return nil }
            return card
        }
        return Array(matched.prefix(limit))
    }

    /// One stack by id — never blind to the 200 most-recent cap.
    public func stack(_ id: UUID) throws -> StackCard? {
        let context = makeContext()
        guard let model = try fetchStack(id, in: context) else { return nil }
        let members = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == id },
            sortBy: [SortDescriptor(\.position)]
        ))
        let tags = try context.fetch(FetchDescriptor<StackTag>(predicate: #Predicate { $0.stackID == id }))
        let recordMeta = try stackRecordMeta(for: members.map(\.recordID), in: context)
        return Self.stackCard(model, members: members, tags: tags, recordMeta: recordMeta)
    }

    /// Atomic editor load: stack + ordered members + cards in one actor call.
    public func stackSnapshot(
        _ id: UUID,
        memberLimit: Int = 1_200,
        excluding: Set<UUID> = []
    ) throws -> (stack: StackCard, order: [UUID], members: [HistoryCard], totalVisible: Int)? {
        let context = makeContext()
        guard let model = try fetchStack(id, in: context) else { return nil }
        let rows = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == id },
            sortBy: [SortDescriptor(\.position)]
        ))
        var live: [UUID] = []
        var compacted = false
        for row in rows {
            if excluding.contains(row.recordID) { continue }
            if try fetchRecord(row.recordID, in: context) != nil {
                live.append(row.recordID)
            } else {
                context.delete(row)
                compacted = true
            }
        }
        if compacted {
            let ordered = try context.fetch(FetchDescriptor<StackMember>(
                predicate: #Predicate { $0.stackID == id },
                sortBy: [SortDescriptor(\.position)]
            ))
            for (index, member) in ordered.enumerated() where member.position != index {
                member.position = index
            }
        }
        if context.hasChanges { try context.save() }
        let tags = try context.fetch(FetchDescriptor<StackTag>(predicate: #Predicate { $0.stackID == id }))
        let recordMeta = try stackRecordMeta(for: live, in: context)
        let card = Self.stackCard(model, members: rows.filter { live.contains($0.recordID) }, tags: tags, recordMeta: recordMeta)
        let order = Array(live.prefix(memberLimit))
        let members = try cards(for: order, in: context)
        return (card, order, members, live.count)
    }

    /// Member record ids in UI order; orphans pruned.
    public func stackMemberIDs(_ stackID: UUID) throws -> [UUID] {
        let context = makeContext()
        let members = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID },
            sortBy: [SortDescriptor(\.position)]
        ))
        var result: [UUID] = []
        var compacted = false
        for member in members {
            if try fetchRecord(member.recordID, in: context) != nil {
                result.append(member.recordID)
            } else {
                context.delete(member)
                compacted = true
            }
        }
        if compacted {
            let ordered = try context.fetch(FetchDescriptor<StackMember>(
                predicate: #Predicate { $0.stackID == stackID },
                sortBy: [SortDescriptor(\.position)]
            ))
            for (index, member) in ordered.enumerated() where member.position != index {
                member.position = index
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
        loops: Bool = false,
        now: Date = Date()
    ) throws -> UUID {
        let context = makeContext()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Stack" : trimmed
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
        touchStackActivity(stack)
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
                // Favorites never aged; an unconfirmed ♥ off must not hand a stale stack (and its
                // sole members) to the next retention pass — the user just touched it.
                touchStackActivity(stack)
            }
        }
    }

    public func setStackDeal(_ id: UUID, dealMode: StackDealMode, loops: Bool) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        stack.dealModeRaw = dealMode.rawValue
        stack.loops = dealMode == .shuffleRandom ? false : loops
        touchStackActivity(stack)
        try context.save()
    }

    public func markStackUsed(_ id: UUID, at date: Date) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        stack.lastUsedAt = max(stack.lastUsedAt, date)
        stack.useCount += 1
        try context.save()
    }

    /// Open / edit in Stack Window — freshness only (does not bump Choose `useCount`).
    public func noteStackEdited(_ id: UUID, at date: Date = Date()) throws {
        let context = makeContext()
        guard let stack = try fetchStack(id, in: context) else { return }
        touchStackActivity(stack, at: date)
        try context.save()
    }

    public func deleteStacks(_ ids: [UUID]) throws {
        let context = makeContext()
        try saveOrRollback(context) { try deleteStackRows(ids: ids, in: context) }
    }

    /// Permute existing members by `orderedIDs` relative order. Unlisted current members keep
    /// their place (same splice as pinboard) — never adds, removes, or resurrects membership.
    public func reorderStackMembers(_ stackID: UUID, orderedIDs: [UUID]) throws {
        let context = makeContext()
        guard try fetchStack(stackID, in: context) != nil else { return }
        let rows = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID },
            sortBy: [SortDescriptor(\.position)]
        ))
        guard !rows.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.recordID, $0) })
        let current = rows.map(\.recordID)
        var seen = Set<UUID>()
        var queue: [UUID] = []
        for id in orderedIDs {
            guard byID[id] != nil, seen.insert(id).inserted else { continue }
            queue.append(id)
        }
        let visible = Set(queue)
        let merged = current.map { id -> UUID in
            if visible.contains(id), !queue.isEmpty { return queue.removeFirst() }
            return id
        }
        for (index, id) in merged.enumerated() {
            byID[id]?.position = index
        }
        if let stack = try fetchStack(stackID, in: context) {
            touchStackActivity(stack)
        }
        try context.save()
    }

    public func appendStackMember(_ stackID: UUID, recordID: UUID) throws {
        let context = makeContext()
        guard let stack = try fetchStack(stackID, in: context) else { return }
        guard let record = try fetchRecord(recordID, in: context) else { return }
        let existing = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID && $0.recordID == recordID }
        ))
        guard existing.isEmpty else { return }
        // `count` collides when positions have gaps after deletes; append after the densest end.
        let rows = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { $0.stackID == stackID }
        ))
        let nextPosition = (rows.map(\.position).max() ?? -1) + 1
        record.expiresAt = nil
        context.insert(StackMember(stackID: stackID, recordID: recordID, position: nextPosition))
        touchStackActivity(stack)
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
            // Materialize away from external-storage CoW: assigning the faulted `Data` directly
            // makes CoreData clone `UUID` → `UUID.interim` and can race the safeguard copy.
            let rep = PayloadRepresentation(
                itemIndex: row.itemIndex,
                repIndex: row.repIndex,
                uti: row.uti,
                kindRaw: row.kindRaw,
                bytes: row.bytes.map { Data($0) },
                paths: row.paths,
                byteCount: row.byteCount
            )
            context.insert(rep)
            rep.record = copy
        }
        // After UTI rows exist: heal so looksLikeColor / Colors see the duplicate (source caches
        // may have lagged while payload still held colour).
        _ = try healColorMetadataIfNeeded(copy, in: context, save: false)
        if let thumb = source.thumbnail {
            let model = RecordThumbnail(data: Data(thumb.data))
            context.insert(model)
            model.record = copy
            copy.hasThumbnail = true
        }

        // Use source.position, not array index — gaps after deletes make index ≠ position.
        let insertAt = members[index].position + 1
        for member in members where member.position >= insertAt {
            member.position += 1
        }
        context.insert(StackMember(stackID: stackID, recordID: copy.id, position: insertAt))
        if let stack = try fetchStack(stackID, in: context) {
            touchStackActivity(stack)
        }
        try context.save()
        return copy.id
    }

    /// Drop one member; compact UI positions. Does not restore `expiresAt` (§6 / P36).
    /// Removing the last member deletes the stack shell (favorites / collection slots included).
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
        if ordered.isEmpty {
            try deleteStackRows(ids: [stackID], in: context)
        } else {
            for (index, member) in ordered.enumerated() { member.position = index }
            if let stack = try fetchStack(stackID, in: context) {
                touchStackActivity(stack)
            }
        }
        try context.save()
    }

    public func setStackMembership(stack stackID: UUID, collection collectionID: UUID, isMember: Bool) throws {
        let context = makeContext()
        guard try fetchStack(stackID, in: context) != nil else { return }
        if isMember, try fetchCollection(collectionID, in: context) == nil { return }
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

        // Stack DTOs by slot IDs (not stacks(limit:) — same root as stack(id)).
        let stackIDs = orderedIDs.compactMap { id -> UUID? in
            if case .stack(let uuid) = id { return uuid }
            return nil
        }
        var stacksByID: [UUID: StackCard] = [:]
        if !stackIDs.isEmpty {
            let ids = stackIDs
            let models = try context.fetch(FetchDescriptor<StackModel>(predicate: #Predicate { ids.contains($0.id) }))
            let modelIDs = Set(models.map(\.id))
            let members = try context.fetch(FetchDescriptor<StackMember>(
                predicate: #Predicate { modelIDs.contains($0.stackID) }
            ))
            let tags = try context.fetch(FetchDescriptor<StackTag>(
                predicate: #Predicate { modelIDs.contains($0.stackID) }
            ))
            let membersByStack = Dictionary(grouping: members, by: \.stackID)
            let tagsByStack = Dictionary(grouping: tags, by: \.stackID)
            let recordMeta = try stackRecordMeta(for: members.map(\.recordID), in: context)
            let stackQuery = HistoryQuery(scope: query.scope, search: query.search, kinds: query.kinds, since: nil)
            for model in models {
                let card = Self.stackCard(
                    model,
                    members: membersByStack[model.id] ?? [],
                    tags: tagsByStack[model.id] ?? [],
                    recordMeta: recordMeta
                )
                let liveMeta = (membersByStack[model.id] ?? []).compactMap { recordMeta[$0.recordID] }
                guard stackMatches(card, members: liveMeta, query: stackQuery) else { continue }
                stacksByID[model.id] = card
            }
        }

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

    /// Permute existing FavoriteSlot rows by `orderedIDs` relative order (splice).
    /// Unlisted slots keep place — never adds/removes membership (same root as `reorderStackMembers`).
    public func reorderFavorites(_ orderedIDs: [HistoryEntry.ID]) throws {
        let context = makeContext()
        try saveOrRollback(context) {
            let slots = try context.fetch(FetchDescriptor<FavoriteSlot>(sortBy: [SortDescriptor(\.position)]))
            guard !slots.isEmpty else { return }
            let keyed: [(HistoryEntry.ID, FavoriteSlot)] = slots.compactMap { slot in
                guard let id = Self.entryID(from: slot.entryKindRaw, entryID: slot.entryID) else { return nil }
                return (id, slot)
            }
            let merged = Self.spliceEntryOrder(current: keyed.map(\.0), ordered: orderedIDs)
            let byID = Dictionary(uniqueKeysWithValues: keyed)
            for (index, id) in merged.enumerated() {
                byID[id]?.position = index
            }
        }
    }

    /// Permute existing CollectionSlot rows only. Never touches RecordTag / StackTag —
    /// a capped visible list must not drop membership beyond the display window.
    public func reorderCollection(_ collectionID: UUID, _ orderedIDs: [HistoryEntry.ID]) throws {
        let context = makeContext()
        try saveOrRollback(context) {
            guard try fetchCollection(collectionID, in: context) != nil else { return }
            let slots = try context.fetch(FetchDescriptor<CollectionSlot>(
                predicate: #Predicate { $0.collectionID == collectionID },
                sortBy: [SortDescriptor(\.position)]
            ))
            guard !slots.isEmpty else { return }
            let keyed: [(HistoryEntry.ID, CollectionSlot)] = slots.compactMap { slot in
                guard let id = Self.entryID(from: slot.entryKindRaw, entryID: slot.entryID) else { return nil }
                return (id, slot)
            }
            let merged = Self.spliceEntryOrder(current: keyed.map(\.0), ordered: orderedIDs)
            let byID = Dictionary(uniqueKeysWithValues: keyed)
            for (index, id) in merged.enumerated() {
                byID[id]?.position = index
            }
        }
    }

    private static func entryID(from kindRaw: String, entryID: UUID) -> HistoryEntry.ID? {
        switch FavoriteSlotKind(rawValue: kindRaw) {
        case .record: .record(entryID)
        case .stack: .stack(entryID)
        case nil: nil
        }
    }

    /// Apply `ordered` relative order onto `current`; ids not in `ordered` keep their slots.
    private static func spliceEntryOrder(
        current: [HistoryEntry.ID],
        ordered: [HistoryEntry.ID]
    ) -> [HistoryEntry.ID] {
        let currentSet = Set(current)
        var seen = Set<HistoryEntry.ID>()
        var queue: [HistoryEntry.ID] = []
        for id in ordered {
            guard currentSet.contains(id), seen.insert(id).inserted else { continue }
            queue.append(id)
        }
        let visible = Set(queue)
        return current.map { id in
            if visible.contains(id), !queue.isEmpty { return queue.removeFirst() }
            return id
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
        \.filePaths, \.colorHex, \.payloadSizeBytes, \.firstCopiedAt, \.lastCopiedAt, \.copyCount, \.useCount, \.isFavorite,
        \.lastSourceAppBundleID, \.lastSourceAppName, \.sourceURL, \.editedAt, \.expiresAt, \.ocrStateRaw,
        \.storedTypes, \.skippedTypes, \.hasThumbnail, \.codeLanguage,
        ]
    }

    private static func sortDescriptors(for mode: HistorySortMode) -> [SortDescriptor<ClipboardRecord>] {
        switch mode {
        case .recent:
            [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        case .mostUsed:
            [
                SortDescriptor(\.useCount, order: .reverse),
                SortDescriptor(\.lastCopiedAt, order: .reverse),
            ]
        }
    }

    private static func stackSortDescriptors(for mode: HistorySortMode) -> [SortDescriptor<StackModel>] {
        switch mode {
        case .recent:
            [SortDescriptor(\.lastUsedAt, order: .reverse)]
        case .mostUsed:
            [
                SortDescriptor(\.useCount, order: .reverse),
                SortDescriptor(\.lastUsedAt, order: .reverse),
            ]
        }
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
            useCount: record.useCount,
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
            record.sourceURL, record.sourceWindowTitle, record.colorHex,
            fileNames.isEmpty ? nil : fileNames.joined(separator: "\n"),
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
        for model in stageRepresentations(of: items, in: context) {
            model.record = record
        }
    }

    /// New payload rows with `record == nil` so a first save can write external blobs without
    /// changing an existing record's verifyable representation set.
    private func stageRepresentations(of items: [CanonicalItem], in context: ModelContext) -> [PayloadRepresentation] {
        StoredRepresentation.rows(for: items).map { row in
            let model: PayloadRepresentation
            switch row.payload {
            case .bytes(let data):
                model = PayloadRepresentation(
                    itemIndex: row.itemIndex, repIndex: row.repIndex, uti: row.type.rawValue,
                    kindRaw: 0, bytes: data, paths: nil, byteCount: row.byteCount
                )
            case .filePaths(let paths):
                model = PayloadRepresentation(
                    itemIndex: row.itemIndex, repIndex: row.repIndex, uti: row.type.rawValue,
                    kindRaw: 1, bytes: nil, paths: paths, byteCount: row.byteCount
                )
            }
            context.insert(model)
            return model
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

    /// Colour cards whose NSColor archives differ but sRGB + paste format match (§8.5 dedup).
    /// Also matches lone-CSS *text* orphans that promote to the same identity (pre-normalize history).
    /// No fetchLimit: missing a soft-merge past an arbitrary cap forks MCS1 again (colour sets stay small).
    private func fetchColorDuplicate(
        identity: ColorPayload.Identity,
        excludingHash: String,
        excludingID: UUID?,
        in context: ModelContext
    ) throws -> ClipboardRecord? {
        let colorType = DisplayType.color.rawValue
        let textType = DisplayType.text.rawValue
        let richType = DisplayType.richText.rawValue
        let wantHex = identity.hex
        let wantFormat = identity.format
        // Case-insensitive identity cannot be expressed in the predicate — filter in memory.
        // Include `colorHex != nil` so type-lag orphans soft-merge. Do **not** use
        // `storedTypes.contains` inside #Predicate — it SIGSEGVs SwiftData at runtime.
        let colorDescriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate {
                ($0.displayTypeRaw == colorType || $0.colorHex != nil)
                    && $0.contentHash != excludingHash
            }
        )
        if let hit = try context.fetch(colorDescriptor).first(where: { record in
            if let excludingID, record.id == excludingID { return false }
            guard let found = colorIdentity(of: record), found.hex == wantHex else { return false }
            if record.colorHex != wantHex { record.colorHex = wantHex }
            return found.format == wantFormat
        }) {
            return hit
        }
        // Colour UTI + nil colorHex + wrong displayType: Predicate cannot see storedTypes — scan.
        let colorUTI = PasteboardType.color.rawValue
        if let hit = try fetchColourUTITypeLagDuplicate(
            wantHex: wantHex,
            wantFormat: wantFormat,
            excludingHash: excludingHash,
            excludingID: excludingID,
            colorType: colorType,
            colorUTI: colorUTI,
            in: context
        ) {
            return hit
        }
        // Short text/richText: CSS paste strings are tiny; insignificant RTF+CSS promotes via normalize.
        let textDescriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate {
                ($0.displayTypeRaw == textType || $0.displayTypeRaw == richType)
                    && $0.contentHash != excludingHash
                    && $0.textLength != nil
            }
        )
        return try context.fetch(textDescriptor).first { record in
            guard Self.isColourTextLength(record) else { return false }
            if let excludingID, record.id == excludingID { return false }
            let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
            let normalized = ColorPayload.normalized(Self.items(from: rows))
            guard let found = ColorPayload.identity(of: normalized) else { return false }
            return found.hex == wantHex && found.format == wantFormat
        }
    }

    /// Lone CSS colour strings are tiny. Compared after the fetch: SwiftData before macOS 27 throws
    /// `unsupportedPredicate` for a force unwrap (`$0.textLength! <= 64`) inside `#Predicate`
    /// (macOS 15 CI runner), which broke colour soft-merge and CSS promotion there.
    private static func isColourTextLength(_ record: ClipboardRecord) -> Bool {
        (record.textLength ?? .max) <= 64
    }

    /// Type-lag orphans with a colour UTI row but nil `colorHex` / wrong displayType.
    /// Finds via `PayloadRepresentation.uti` — `storedTypes` may be empty while rows remain.
    private func fetchColourUTITypeLagDuplicate(
        wantHex: String,
        wantFormat: ColorPasteFormat,
        excludingHash: String,
        excludingID: UUID?,
        colorType: String,
        colorUTI: String,
        in context: ModelContext
    ) throws -> ClipboardRecord? {
        let repDescriptor = FetchDescriptor<PayloadRepresentation>(
            predicate: #Predicate { $0.uti == colorUTI }
        )
        var candidateIDs = Set<UUID>()
        for rep in try context.fetch(repDescriptor) {
            guard let record = rep.record else { continue }
            if let excludingID, record.id == excludingID { continue }
            guard record.contentHash != excludingHash else { continue }
            guard record.displayTypeRaw != colorType || record.colorHex == nil else { continue }
            candidateIDs.insert(record.id)
        }
        guard !candidateIDs.isEmpty else { return nil }
        let ids = Array(candidateIDs)
        return try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))
            .first { record in
                guard let found = colorIdentity(of: record), found.hex == wantHex else { return false }
                if record.colorHex != wantHex { record.colorHex = wantHex }
                return found.format == wantFormat
            }
    }

    /// Promote pre-normalize lone-CSS text/richText rows into Color cards, merging into an existing twin when present.
    /// Also materializes `.color` faces that still lack colour UTI bytes (older heal flipped displayType only).
    @discardableResult
    public func promoteOrphanCSSColorTextRecords(opSeq: Int) throws -> Int {
        let textType = DisplayType.text.rawValue
        let richType = DisplayType.richText.rawValue
        let colorType = DisplayType.color.rawValue
        let context = makeContext()
        let descriptor = FetchDescriptor<ClipboardRecord>(
            predicate: #Predicate {
                ($0.displayTypeRaw == textType || $0.displayTypeRaw == richType || $0.displayTypeRaw == colorType)
                    && $0.textLength != nil
            }
        )
        let records = try context.fetch(descriptor).filter(Self.isColourTextLength)
        var changed = 0
        for record in records {
            let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
            let items = Self.items(from: rows)
            let normalized = ColorPayload.normalized(items)
            guard let identity = ColorPayload.identity(of: normalized),
                  ColorPayload.identity(of: items) == nil else { continue }
            let hash = MCS1.contentHash(of: normalized)
            let size = MCS1.payloadSize(of: normalized)
            let enrichment = IngestEnrichment.make(for: normalized, sourceAppName: record.lastSourceAppName)
            if let twin = try fetchColorDuplicate(
                identity: identity, excludingHash: record.contentHash, excludingID: record.id, in: context
            ) {
                let twinID = twin.id
                let orphanID = record.id
                staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq)
                try saveOrRollback(context) {
                    apply(
                        DedupMerge.mergeEdited(try metadata(of: record, in: context), into: try metadata(of: twin, in: context)),
                        to: twin
                    )
                    twin.useCount += record.useCount
                    if twin.customTitle == nil { twin.customTitle = record.customTitle }
                    twin.searchText = Self.searchText(for: twin)
                    let tags = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == orphanID }))
                    let existing = Set(
                        try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.recordID == twinID }))
                            .map(\.collectionID)
                    )
                    for tag in tags where !existing.contains(tag.collectionID) {
                        context.insert(RecordTag(recordID: twinID, collectionID: tag.collectionID))
                    }
                    try retargetStackMembers(from: orphanID, to: twinID, in: context)
                    try Self.retargetFavoriteSlot(from: orphanID, to: twinID, in: context)
                    try Self.retargetCollectionSlots(from: orphanID, to: twinID, in: context)
                    try deleteRecords(ids: [orphanID], in: context)
                }
                if twin.contentHash != hash {
                    _ = try applyColorPasteFormat(twinID, format: identity.format, opSeq: opSeq)
                }
                changed += 1
                continue
            }
            let snap = OwnedSnapshot(
                changeCount: 0,
                observedAt: record.lastCopiedAt,
                identity: AppIdentity(bundleID: record.lastSourceAppBundleID, source: .frontmost),
                settings: ResolvedAppSettings(),
                items: normalized,
                contentHash: hash,
                payloadSizeBytes: size,
                displayType: .color,
                skippedTypes: [],
                sourceURL: record.sourceURL
            )
            staleGuard.recordTombstone(contentHash: record.contentHash, opSeq: opSeq)
            try replaceColorPayload(of: record, with: snap, enrichment: enrichment, in: context)
            changed += 1
        }
        return changed
    }

    /// `#RRGGBB[AA]` via `ColorValues.hex` — identity key, not the raw cache string.
    private static func canonicalColorHex(_ hex: String?) -> String? {
        guard let hex, let values = ColorValues(hex: hex) else { return nil }
        return values.hex
    }

    private static func colorHexFromItems(_ items: [CanonicalItem]) -> String? {
        ColorPayload.identity(of: items)?.hex
    }

    /// Align enrichment caches to the (already normalized) snapshot payload — payload is SSOT.
    private static func enrichmentAligned(with snapshot: OwnedSnapshot, base: IngestEnrichment) -> IngestEnrichment {
        var enrichment = base
        let fromItems = IngestEnrichment.make(
            for: snapshot.items,
            sourceAppName: base.sourceAppName,
            sourceWindowTitle: base.sourceWindowTitle
        )
        // Wrong caller hex must not stick: soft-merge / swatch trust this cache.
        enrichment.colorHex = fromItems.colorHex ?? canonicalColorHex(enrichment.colorHex)
        let previewBlank = enrichment.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let payloadPreview = fromItems.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if previewBlank || (!payloadPreview.isEmpty && enrichment.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines) != payloadPreview) {
            enrichment.cardPreview = fromItems.cardPreview
            enrichment.textIndex = fromItems.textIndex
            enrichment.textLength = fromItems.textLength
            enrichment.lineCount = fromItems.lineCount
        }
        return enrichment
    }

    /// Payload-first identity; caches only when paste text / hex missing.
    private func colorIdentity(of record: ClipboardRecord) -> ColorPayload.Identity? {
        let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        let items = Self.items(from: rows)
        if let identity = ColorPayload.identity(of: items) { return identity }
        guard let hex = resolvedColorHex(of: record) else { return nil }
        let preview = record.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = ColorPayload.pasteFormat(forPlainText: preview.isEmpty ? nil : preview)
        return ColorPayload.Identity(hex: hex, format: format)
    }

    /// Payload colour UTI first; `colorHex` cache only when the UTI is unreadable.
    private func resolvedColorHex(of record: ClipboardRecord) -> String? {
        if let hex = colorHexFromPayload(record) { return hex }
        return Self.canonicalColorHex(record.colorHex)
    }

    private func colorHexFromPayload(_ record: ClipboardRecord) -> String? {
        let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        guard let data = Self.items(from: rows)
            .flatMap(\.representations)
            .first(where: { $0.type == .color })?
            .bytes else { return nil }
        return ColorHex.string(fromPasteboardColor: data).flatMap(Self.canonicalColorHex)
    }

    private func colorPastePlainText(of record: ClipboardRecord) -> String? {
        let rows = record.representations.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        return ColorPayload.pastePlainText(of: Self.items(from: rows))
    }

    /// Align colour caches from payload (preferred) / enrichment without rewriting representations.
    private func backfillColorMetadata(on record: ClipboardRecord, from enrichment: IngestEnrichment, snapshot: OwnedSnapshot) {
        // Colour UTI / displayType — not `normalized` (would treat inbound lone CSS as colour caches
        // without requiring colour bytes; ingest already normalizes colour snapshots).
        let looksColour = snapshot.displayType == .color
            || DisplayType(rawValue: record.displayTypeRaw) == .color
            || record.colorHex != nil
            || snapshot.items.contains { item in item.representations.contains { $0.type == .color } }
        guard looksColour else { return }
        let hex = Self.colorHexFromItems(snapshot.items)
            ?? Self.canonicalColorHex(enrichment.colorHex)
            ?? Self.canonicalColorHex(record.colorHex)
            ?? colorHexFromPayload(record)
        if let hex, record.colorHex != hex {
            record.colorHex = hex
        }
        let wantPreview = ColorPayload.pastePlainText(of: snapshot.items)
            ?? {
                let trimmed = enrichment.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : enrichment.cardPreview
            }()
        if let wantPreview {
            let have = record.cardPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if have != wantPreview.trimmingCharacters(in: .whitespacesAndNewlines) {
                record.cardPreview = TextDecoding.prefix(wantPreview, maxScalars: IngestEnrichment.cardPreviewScalars)
                record.textIndex = TextDecoding.prefix(wantPreview, maxScalars: IngestEnrichment.searchScalars)
                record.textLength = wantPreview.count
                record.lineCount = 1
            }
        }
        if DisplayType(rawValue: record.displayTypeRaw) != .color {
            record.displayTypeRaw = DisplayType.color.rawValue
        }
        // Hard MCS1 hit must not leave empty/stale storedTypes — looksLikeColor / drag / Colors chip.
        let types = Self.distinctTypes(of: snapshot.items)
        if record.storedTypes != types {
            record.storedTypes = types
        }
    }

    /// Swap a colour record onto the inbound canonical items (two-phase save like edit/format).
    private func replaceColorPayload(
        of record: ClipboardRecord,
        with snapshot: OwnedSnapshot,
        enrichment: IngestEnrichment,
        in context: ModelContext
    ) throws {
        let obsolete = Array(record.representations)
        let staged = stageRepresentations(of: snapshot.items, in: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        do {
            try saveOrRollback(context) {
                for row in obsolete { context.delete(row) }
                for model in staged { model.record = record }
                record.contentHash = snapshot.contentHash
                record.payloadSizeBytes = snapshot.payloadSizeBytes
                record.cardPreview = enrichment.cardPreview
                record.textIndex = enrichment.textIndex
                record.textLength = enrichment.textLength
                record.lineCount = enrichment.lineCount ?? 1
                record.colorHex = Self.colorHexFromItems(snapshot.items)
                    ?? Self.canonicalColorHex(enrichment.colorHex)
                record.displayTypeRaw = snapshot.displayType.rawValue
                record.storedTypes = Self.distinctTypes(of: snapshot.items)
                record.skippedTypes = snapshot.skippedTypes.map(\.rawValue)
                record.searchText = Self.searchText(for: record)
            }
        } catch {
            for model in staged where model.record == nil { context.delete(model) }
            try? context.save()
            throw error
        }
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

    private func fetchCollection(_ id: UUID, in context: ModelContext) throws -> CollectionModel? {
        var descriptor = FetchDescriptor<CollectionModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Curated edits count as activity so age retention does not delete a stack you still work on.
    private func touchStackActivity(_ stack: StackModel, at date: Date = Date()) {
        stack.lastUsedAt = max(stack.lastUsedAt, date)
    }

    /// Dedup/edit merge: retarget membership. Never mutate `recordID` in place — `deleteRecords`
    /// cascades by old id and would wipe the retargeted row before save.
    private func retargetStackMembers(from oldID: UUID, to survivorID: UUID, in context: ModelContext) throws {
        let members = try context.fetch(FetchDescriptor<StackMember>(predicate: #Predicate { $0.recordID == oldID }))
        var affected = Set<UUID>()
        for member in members {
            let stackID = member.stackID
            affected.insert(stackID)
            let already = try context.fetch(FetchDescriptor<StackMember>(
                predicate: #Predicate { $0.stackID == stackID && $0.recordID == survivorID }
            ))
            if already.isEmpty {
                let position = member.position
                context.delete(member)
                context.insert(StackMember(stackID: stackID, recordID: survivorID, position: position))
            } else {
                context.delete(member)
            }
        }
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

    private typealias StackMemberMeta = (
        displayType: String,
        app: String?,
        search: String,
        preview: String,
        sensitive: String?,
        colorHex: String?,
        hasColourUTI: Bool
    )

    /// Scope / filter first, then caller applies `prefix(limit)` after `stackMatches`.
    private func fetchStackModels(matching query: HistoryQuery, in context: ModelContext) throws -> [StackModel] {
        let sort = Self.stackSortDescriptors(for: query.sort)
        switch query.scope {
        case .favorites:
            return try context.fetch(FetchDescriptor<StackModel>(
                predicate: #Predicate { $0.isFavorite },
                sortBy: sort
            ))
        case .collection(let collectionID):
            let tags = try context.fetch(FetchDescriptor<StackTag>(
                predicate: #Predicate { $0.collectionID == collectionID }
            ))
            let ids = Set(tags.map(\.stackID))
            guard !ids.isEmpty else { return [] }
            let models = try context.fetch(FetchDescriptor<StackModel>(
                predicate: #Predicate { ids.contains($0.id) },
                sortBy: sort
            ))
            return models
        case .stack:
            return []
        default:
            // Search/kinds need the full set before match; unfiltered grid may cap at fetch.
            var descriptor = FetchDescriptor<StackModel>(sortBy: sort)
            let needsBroadFetch = !query.search.isEmpty || !query.kinds.isEmpty || query.since != nil
            if !needsBroadFetch {
                descriptor.fetchLimit = 2_000
            }
            return try context.fetch(descriptor)
        }
    }

    private func stackRecordMeta(
        for recordIDs: [UUID],
        in context: ModelContext
    ) throws -> [UUID: StackMemberMeta] {
        let unique = Array(Set(recordIDs))
        guard !unique.isEmpty else { return [:] }
        var recordMeta: [UUID: StackMemberMeta] = [:]
        var recDesc = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { unique.contains($0.id) })
        recDesc.propertiesToFetch = [
            \.id, \.displayTypeRaw, \.lastSourceAppBundleID, \.searchText, \.cardPreview, \.sensitiveKind, \.colorHex,
            \.storedTypes,
        ]
        let colorUTI = PasteboardType.color.rawValue
        for record in try context.fetch(recDesc) {
            recordMeta[record.id] = (
                record.displayTypeRaw,
                record.lastSourceAppBundleID,
                record.searchText,
                record.cardPreview,
                record.sensitiveKind,
                record.colorHex,
                record.storedTypes.contains(colorUTI)
            )
        }
        return recordMeta
    }

    private static func stackCard(
        _ stack: StackModel,
        members: [StackMember],
        tags: [StackTag],
        recordMeta: [UUID: StackMemberMeta]
    ) -> StackCard {
        let ordered = members.sorted { $0.position < $1.position }
        let live = ordered.filter { recordMeta[$0.recordID] != nil }
        let memberIDs = live.map(\.recordID)
        return StackCard(
            id: stack.id,
            title: stack.title,
            isFavorite: stack.isFavorite,
            loops: stack.loops,
            dealMode: StackDealMode(rawValue: stack.dealModeRaw) ?? .sequential,
            createdAt: stack.createdAt,
            lastUsedAt: stack.lastUsedAt,
            useCount: stack.useCount,
            memberIDs: memberIDs,
            previewRecordID: memberIDs.first,
            memberCount: memberIDs.count,
            collectionIDs: Set(tags.map(\.collectionID)),
            sensitiveKind: memberIDs.first.flatMap { recordMeta[$0]?.sensitive },
            preview: memberIDs.first.flatMap { recordMeta[$0]?.preview } ?? ""
        )
    }

    private func stackMatches(
        _ card: StackCard,
        members: [StackMemberMeta],
        query: HistoryQuery
    ) -> Bool {
        switch query.scope {
        case .all: break
        case .favorites:
            guard card.isFavorite else { return false }
        case .app(let bundleID):
            guard members.contains(where: { $0.app == bundleID }) else { return false }
        case .type(let type):
            if type == .color {
                // Same denormalized signals as record Colors filter — displayType alone misses type-lag.
                guard members.contains(where: Self.memberLooksLikeColor) else { return false }
            } else {
                guard members.contains(where: { $0.displayType == type.rawValue }) else { return false }
            }
        case .collection(let collectionID):
            guard card.collectionIDs.contains(collectionID) else { return false }
        case .stack:
            // Drill-down shows members only — never nest stack cards in the grid.
            return false
        }
        if !query.kinds.isEmpty {
            if query.kinds == [.color] {
                guard members.contains(where: Self.memberLooksLikeColor) else { return false }
            } else {
                let raws = Set(query.kinds.map(\.rawValue))
                guard members.contains(where: { raws.contains($0.displayType) }) else { return false }
            }
        }
        if let since = query.since, card.lastUsedAt < since { return false }
        for word in query.words {
            let inTitle = card.title.localizedStandardContains(word)
            let inMembers = members.contains { $0.search.localizedStandardContains(word) }
            guard inTitle || inMembers else { return false }
        }
        return true
    }

    /// Stack member colour face — mirrors HistoryCard.looksLikeColor (displayType / colorHex / UTI).
    private static func memberLooksLikeColor(_ member: StackMemberMeta) -> Bool {
        member.displayType == DisplayType.color.rawValue
            || member.colorHex != nil
            || member.hasColourUTI
    }

    /// Records, their representations and thumbnails (cascade) and memberships, in the caller's transaction.
    /// Stacks that lose their last member here are removed (intentional empty stacks created via
    /// `createStack(recordIDs: [])` are untouched — they were never in `touchedStacks`).
    private func deleteRecords(ids: [UUID], in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let memberRows = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { ids.contains($0.recordID) }
        ))
        let touchedStacks = Set(memberRows.map(\.stackID))
        let records = try context.fetch(FetchDescriptor<ClipboardRecord>(predicate: #Predicate { ids.contains($0.id) }))
        records.forEach { context.delete($0) }
        try context.delete(model: RecordTag.self, where: #Predicate { ids.contains($0.recordID) })
        try context.delete(model: StackMember.self, where: #Predicate { ids.contains($0.recordID) })
        let kind = FavoriteSlotKind.record.rawValue
        try context.delete(model: FavoriteSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
        try context.delete(model: CollectionSlot.self, where: #Predicate { $0.entryKindRaw == kind && ids.contains($0.entryID) })
        try Self.compactFavoriteSlots(in: context)
        try Self.compactAllCollectionSlots(in: context)
        try pruneStacksIfEmpty(touchedStacks, in: context)
    }

    /// Drop stack shells that this mutation emptied — not globally (empty-by-create stays).
    private func pruneStacksIfEmpty(_ stackIDs: Set<UUID>, in context: ModelContext) throws {
        guard !stackIDs.isEmpty else { return }
        let ids = Array(stackIDs)
        let remaining = try context.fetch(FetchDescriptor<StackMember>(
            predicate: #Predicate { ids.contains($0.stackID) }
        ))
        let populated = Set(remaining.map(\.stackID))
        let empty = stackIDs.subtracting(populated)
        guard !empty.isEmpty else { return }
        try deleteStackRows(ids: Array(empty), in: context)
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
            if type == .color {
                // displayType / colorHex — `storedTypes.contains` in #Predicate crashes SwiftData.
                // Launch heal restores caches for UTI-only orphans.
                let colorType = DisplayType.color.rawValue
                and(#Predicate { $0.displayTypeRaw == colorType || $0.colorHex != nil })
            } else {
                let raw = type.rawValue
                and(#Predicate { $0.displayTypeRaw == raw })
            }
        case .collection(let collectionID):
            let ids = try context.fetch(FetchDescriptor<RecordTag>(predicate: #Predicate { $0.collectionID == collectionID })).map(\.recordID)
            and(#Predicate { ids.contains($0.id) })
        case .stack(let stackID):
            // Prefer `filteredStackMemberIDs` / `page` for order; predicate keeps ids()/count callers correct.
            let ids = try context.fetch(FetchDescriptor<StackMember>(predicate: #Predicate { $0.stackID == stackID })).map(\.recordID)
            and(#Predicate { ids.contains($0.id) })
        }
        if !query.kinds.isEmpty {
            let colorOnly = query.kinds == [.color]
            if colorOnly {
                let colorType = DisplayType.color.rawValue
                and(#Predicate { $0.displayTypeRaw == colorType || $0.colorHex != nil })
            } else {
                let raws = query.kinds.map(\.rawValue)
                and(#Predicate { raws.contains($0.displayTypeRaw) })
            }
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
            if query.kinds == [.color] {
                let isColor = DisplayType(rawValue: record.displayTypeRaw) == .color
                    || record.colorHex != nil
                    || record.storedTypes.contains(PasteboardType.color.rawValue)
                guard isColor else { return false }
            } else {
                let raws = query.kinds.map(\.rawValue)
                guard raws.contains(record.displayTypeRaw) else { return false }
            }
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

    /// Never mutate `entryID` in place — `deleteRecords` cascades by old id after retarget.
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
        } else {
            let position = old.position
            context.delete(old)
            context.insert(FavoriteSlot(entryKindRaw: kind, entryID: survivorID, position: position))
        }
        try compactFavoriteSlots(in: context)
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
                let position = old.position
                context.delete(old)
                context.insert(CollectionSlot(
                    collectionID: collectionID,
                    entryKindRaw: kind,
                    entryID: survivorID,
                    position: position
                ))
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
