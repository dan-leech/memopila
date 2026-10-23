import Foundation
import SwiftData

/// One history card: metadata only; payload bytes live in `PayloadRepresentation` rows (PLAN §3.5, §7.2).
@Model
final class ClipboardRecord {
    #Index<ClipboardRecord>([\.contentHash], [\.lastCopiedAt], [\.isFavorite], [\.lastSourceAppBundleID], [\.displayTypeRaw], [\.expiresAt])

    var id: UUID
    var displayTypeRaw: String
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
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

enum StoreSchema {
    static let models: [any PersistentModel.Type] = [
        ClipboardRecord.self, PayloadRepresentation.self, RecordThumbnail.self, CollectionModel.self, RecordTag.self,
    ]
}
