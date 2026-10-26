import Foundation
import MemopilaCore
import SwiftData

/// One history card: metadata only; payload bytes live in `PayloadRepresentation` rows (PLAN §3.5, §7.2).
@Model
final class ClipboardRecord {
    #Index<ClipboardRecord>([\.contentHash], [\.lastCopiedAt], [\.isFavorite], [\.lastSourceAppBundleID], [\.displayTypeRaw], [\.expiresAt], [\.useCount])

    var id: UUID
    var displayTypeRaw: String
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    /// Choose / Restore count (not capture `copyCount`).
    var useCount: Int = 0
    var isFavorite: Bool
    var lastSourceAppBundleID: String?
    var lastSourceAppName: String?
    var contentHash: String
    var hashSchemeVersion: Int
    var storageFormatVersion: Int
    var payloadSizeBytes: Int
    /// ≤ 300 Unicode scalars (§7.4).
    var cardPreview: String
    /// Decoded text, ≤ 10 000 scalars; part of `searchText`.
    var textIndex: String
    var textLength: Int?
    /// Lines of the full text, for the card footer.
    var lineCount: Int?
    /// `SecretKind` raw value when the text holds a credential (§3.10): the card masks it.
    var sensitiveKind: String?
    /// Everything search matches: text, title, recognized text, app, source page, file names (§8.6).
    var searchText: String
    var customTitle: String?
    var editedAt: Date?
    var expiresAt: Date?
    var ocrText: String?
    var ocrStateRaw: String
    var sourceURL: String?
    var sourceWindowTitle: String?
    var codeLanguage: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var colorHex: String?
    var filePaths: [String]
    /// Distinct stored types in order, for the format quick actions (§5.1) without loading payload rows.
    var storedTypes: [String] = []
    var skippedTypes: [String]
    var hasThumbnail: Bool

    @Relationship(deleteRule: .cascade, inverse: \PayloadRepresentation.record)
    var representations: [PayloadRepresentation] = []

    @Relationship(deleteRule: .cascade, inverse: \RecordThumbnail.record)
    var thumbnail: RecordThumbnail?

    init(
        id: UUID = UUID(),
        displayTypeRaw: String,
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        copyCount: Int,
        contentHash: String,
        hashSchemeVersion: Int,
        storageFormatVersion: Int,
        payloadSizeBytes: Int
    ) {
        self.id = id
        self.displayTypeRaw = displayTypeRaw
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.useCount = 0
        self.isFavorite = false
        self.contentHash = contentHash
        self.hashSchemeVersion = hashSchemeVersion
        self.storageFormatVersion = storageFormatVersion
        self.payloadSizeBytes = payloadSizeBytes
        self.cardPreview = ""
        self.textIndex = ""
        self.searchText = ""
        self.ocrStateRaw = RecognitionState.off.rawValue
        self.filePaths = []
        self.storedTypes = []
        self.skippedTypes = []
        self.hasThumbnail = false
    }
}

/// One stored representation (§3.5). `bytes` uses external storage so list queries never load it.
@Model
final class PayloadRepresentation {
    var itemIndex: Int
    var repIndex: Int
    var uti: String
    /// 0 = bytes, 1 = file paths.
    var kindRaw: Int
    @Attribute(.externalStorage) var bytes: Data?
    var paths: [String]?
    var byteCount: Int
    var record: ClipboardRecord?

    init(itemIndex: Int, repIndex: Int, uti: String, kindRaw: Int, bytes: Data?, paths: [String]?, byteCount: Int) {
        self.itemIndex = itemIndex
        self.repIndex = repIndex
        self.uti = uti
        self.kindRaw = kindRaw
        self.bytes = bytes
        self.paths = paths
        self.byteCount = byteCount
    }
}

/// Card thumbnail, ≤ 512 px (§3.5). Separate entity so card queries do not load it.
@Model
final class RecordThumbnail {
    @Attribute(.externalStorage) var data: Data
    var record: ClipboardRecord?

    init(data: Data) {
        self.data = data
    }
}

/// A collection (UI name for tags, §8.2).
@Model
final class CollectionModel {
    #Unique<CollectionModel>([\.id])

    var id: UUID
    var name: String
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

@Model
final class RecordTag {
    #Unique<RecordTag>([\.recordID, \.collectionID])

    var recordID: UUID
    var collectionID: UUID

    init(recordID: UUID, collectionID: UUID) {
        self.recordID = recordID
        self.collectionID = collectionID
    }
}

/// Favorites pinboard order for a record or stack. Membership stays `isFavorite`.
@Model
final class FavoriteSlot {
    #Unique<FavoriteSlot>([\.entryKindRaw, \.entryID])

    /// `record` or `stack` — mirrors `HistoryEntry.ID`.
    var entryKindRaw: String
    var entryID: UUID
    /// 0 = top-left of the Favorites grid.
    var position: Int

    init(entryKindRaw: String, entryID: UUID, position: Int) {
        self.entryKindRaw = entryKindRaw
        self.entryID = entryID
        self.position = position
    }
}

/// Collection pinboard order (records ∪ stacks). Membership stays `RecordTag` / `StackTag`.
/// Separate entity so V2→V3 stays additive lightweight (no alter of existing tag tables).
@Model
final class CollectionSlot {
    #Unique<CollectionSlot>([\.collectionID, \.entryKindRaw, \.entryID])

    var collectionID: UUID
    var entryKindRaw: String
    var entryID: UUID
    var position: Int

    init(collectionID: UUID, entryKindRaw: String, entryID: UUID, position: Int) {
        self.collectionID = collectionID
        self.entryKindRaw = entryKindRaw
        self.entryID = entryID
        self.position = position
    }
}

/// A paste stack: reusable playlist of linked history records (PLAN §3.11).
@Model
final class StackModel {
    #Unique<StackModel>([\.id])

    var id: UUID
    var title: String
    var isFavorite: Bool
    var loops: Bool
    /// `StackDealMode.rawValue`.
    var dealModeRaw: String
    var createdAt: Date
    var lastUsedAt: Date
    /// Choose-stack count (not member captures).
    var useCount: Int = 0

    init(
        id: UUID = UUID(),
        title: String,
        isFavorite: Bool = false,
        loops: Bool = false,
        dealModeRaw: String = StackDealMode.sequential.rawValue,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.isFavorite = isFavorite
        self.loops = loops
        self.dealModeRaw = dealModeRaw
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = 0
    }
}

/// UI order of a stack member. Session deal order is not persisted (§3.11).
@Model
final class StackMember {
    #Unique<StackMember>([\.stackID, \.recordID])

    var stackID: UUID
    var recordID: UUID
    var position: Int

    init(stackID: UUID, recordID: UUID, position: Int) {
        self.stackID = stackID
        self.recordID = recordID
        self.position = position
    }
}

/// Stack ↔ collection membership (separate from `RecordTag`, §3.11).
@Model
final class StackTag {
    #Unique<StackTag>([\.stackID, \.collectionID])

    var stackID: UUID
    var collectionID: UUID

    init(stackID: UUID, collectionID: UUID) {
        self.stackID = stackID
        self.collectionID = collectionID
    }
}

enum StoreSchema {
    static var models: [any PersistentModel.Type] { StoreSchemaV4.models }
}

/// The first released history schema (PLAN §7.2).
enum StoreSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardRecord.self, PayloadRepresentation.self, RecordThumbnail.self, CollectionModel.self, RecordTag.self]
    }
}

/// Adds paste stacks (§3.11).
enum StoreSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            ClipboardRecord.self, PayloadRepresentation.self, RecordThumbnail.self,
            CollectionModel.self, RecordTag.self,
            StackModel.self, StackMember.self, StackTag.self,
        ]
    }
}

/// Pinboard order: `FavoriteSlot` + `CollectionSlot` (additive — safe V2 lightweight migrate).
enum StoreSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            ClipboardRecord.self, PayloadRepresentation.self, RecordThumbnail.self,
            CollectionModel.self, RecordTag.self, FavoriteSlot.self, CollectionSlot.self,
            StackModel.self, StackMember.self, StackTag.self,
        ]
    }
}

/// Empty row type so V4’s checksum differs from V3 (`Duplicate version checksums` otherwise).
/// Additive `useCount` on shared `@Model` types still invalidates older on-disk hashes — see
/// `ClipboardStore.openContainer` inferred fallback.
@Model
final class SchemaStampV4 {
    var id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Choose/Restore `useCount` on records and stacks (additive Int defaults).
enum StoreSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            ClipboardRecord.self, PayloadRepresentation.self, RecordThumbnail.self,
            CollectionModel.self, RecordTag.self, FavoriteSlot.self, CollectionSlot.self,
            StackModel.self, StackMember.self, StackTag.self,
            SchemaStampV4.self,
        ]
    }
}

enum StoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [StoreSchemaV1.self, StoreSchemaV2.self, StoreSchemaV3.self, StoreSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(fromVersion: StoreSchemaV1.self, toVersion: StoreSchemaV2.self),
            MigrationStage.lightweight(fromVersion: StoreSchemaV2.self, toVersion: StoreSchemaV3.self),
            MigrationStage.lightweight(fromVersion: StoreSchemaV3.self, toVersion: StoreSchemaV4.self),
        ]
    }
}
