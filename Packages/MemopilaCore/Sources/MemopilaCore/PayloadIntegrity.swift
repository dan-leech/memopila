/// One stored `PayloadRepresentation` row as loaded for Restore (PLAN §3.5).
public struct StoredRepresentation: Sendable, Equatable {
    public var itemIndex: Int
    public var repIndex: Int
    public var type: PasteboardType
    public var payload: CanonicalRepresentation.Payload
    public var byteCount: Int

    public init(itemIndex: Int, repIndex: Int, type: PasteboardType, payload: CanonicalRepresentation.Payload, byteCount: Int) {
        self.itemIndex = itemIndex
        self.repIndex = repIndex
        self.type = type
        self.payload = payload
        self.byteCount = byteCount
    }

    /// Rows for a captured snapshot, in canonical order.
    public static func rows(for items: [CanonicalItem]) -> [StoredRepresentation] {
        items.enumerated().flatMap { itemIndex, item in
            item.representations.enumerated().map { repIndex, representation in
                StoredRepresentation(
                    itemIndex: itemIndex,
                    repIndex: repIndex,
                    type: representation.type,
                    payload: representation.payload,
                    byteCount: representation.byteCount
                )
            }
        }
    }
}

public enum IntegrityError: Error, Sendable, Equatable {
    case unsupportedHashScheme(Int)
    case unsupportedStorageFormat(Int)
    case empty
    case nonContiguousRows
    case byteCountMismatch(itemIndex: Int, repIndex: Int)
    case payloadSizeMismatch(expected: Int, actual: Int)
    case invalidPath(itemIndex: Int, repIndex: Int)
    case hashMismatch
}

/// Mandatory checks before Restore touches the pasteboard (PLAN §3.5). No file reads.
public enum PayloadIntegrity {
    public static let storageFormatVersion = 1

    public static func verify(
        rows: [StoredRepresentation],
        payloadSizeBytes: Int,
        contentHash: String,
        hashSchemeVersion: Int,
        storageFormatVersion: Int
    ) throws(IntegrityError) -> [CanonicalItem] {
        guard hashSchemeVersion == MCS1.hashSchemeVersion else { throw .unsupportedHashScheme(hashSchemeVersion) }
        guard storageFormatVersion == Self.storageFormatVersion else { throw .unsupportedStorageFormat(storageFormatVersion) }
        guard !rows.isEmpty else { throw .empty }

        let sorted = rows.sorted { ($0.itemIndex, $0.repIndex) < ($1.itemIndex, $1.repIndex) }
        var items: [CanonicalItem] = []
        var total = 0
        for row in sorted {
            if row.itemIndex == items.count {
                guard row.repIndex == 0 else { throw .nonContiguousRows }
                items.append(CanonicalItem([]))
            } else {
                guard row.itemIndex == items.count - 1,
                      row.repIndex == items[items.count - 1].representations.count else { throw .nonContiguousRows }
            }
            let representation = CanonicalRepresentation(type: row.type, payload: row.payload)
            guard representation.byteCount == row.byteCount else {
                throw .byteCountMismatch(itemIndex: row.itemIndex, repIndex: row.repIndex)
            }
            if case .filePaths(let paths) = row.payload,
               paths.isEmpty || !paths.allSatisfy(FilePathNormalizer.isValidStoredPath) {
                throw .invalidPath(itemIndex: row.itemIndex, repIndex: row.repIndex)
            }
            total += row.byteCount
            items[items.count - 1].representations.append(representation)
        }
        guard total == payloadSizeBytes else { throw .payloadSizeMismatch(expected: payloadSizeBytes, actual: total) }
        guard MCS1.contentHash(of: items) == contentHash else { throw .hashMismatch }
        return items
    }
}
