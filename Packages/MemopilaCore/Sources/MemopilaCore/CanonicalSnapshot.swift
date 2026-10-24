import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One stored representation in canonical order (PLAN §3.3, §4).
public struct CanonicalRepresentation: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case bytes(Data)
        /// Normalized paths (§3.3.1); hashed as `CanonicalFileListV1`.
        case filePaths([String])
    }

    public var type: PasteboardType
    public var payload: Payload

    public init(type: PasteboardType, payload: Payload) {
        self.type = type
        self.payload = payload
    }

    public static func bytes(_ type: PasteboardType, _ data: Data) -> Self {
        Self(type: type, payload: .bytes(data))
    }

    public static func files(_ type: PasteboardType, _ paths: [String]) -> Self {
        Self(type: type, payload: .filePaths(paths))
    }

    /// Bytes counted against the size budget and `payloadSizeBytes`.
    public var byteCount: Int {
        switch payload {
        case .bytes(let data): data.count
        case .filePaths(let paths): paths.reduce(0) { $0 + $1.utf8.count }
        }
    }

    public var bytes: Data? {
        if case .bytes(let data) = payload { return data }
        return nil
    }
}

public struct CanonicalItem: Sendable, Equatable {
    public var representations: [CanonicalRepresentation]

    public init(_ representations: [CanonicalRepresentation]) {
        self.representations = representations
    }
}

/// Memopila Canonical Snapshot v1 (PLAN §4): the identity of clipboard content.
public enum MCS1 {
    public static let hashSchemeVersion = 1

    /// Lowercase hex SHA-256 of `CanonicalSnapshotEncodingV1`, fed field by field (no concatenated buffer).
    public static func contentHash(of items: [CanonicalItem]) -> String {
        var sink = HashSink()
        write(items, to: &sink)
        return hex(sink.hasher.finalize())
    }

    /// The full encoding; for golden tests and diagnostics only.
    public static func encode(_ items: [CanonicalItem]) -> Data {
        var sink = DataSink()
        write(items, to: &sink)
        return sink.data
    }

    /// `CanonicalFileListV1` on its own.
    public static func encodeFileList(_ paths: [String]) -> Data {
        var sink = DataSink()
        writeFileList(paths, to: &sink)
        return sink.data
    }

    public static func payloadSize(of items: [CanonicalItem]) -> Int {
        items.reduce(0) { total, item in item.representations.reduce(total) { $0 + $1.byteCount } }
    }

    private static func write(_ items: [CanonicalItem], to sink: inout some ByteSink) {
        sink.append(Data("MCS1".utf8))
        let retained = items.filter { !$0.representations.isEmpty }
        sink.append(uint64: retained.count)
        for item in retained {
            sink.append(uint64: item.representations.count)
            for representation in item.representations {
                let typeBytes = Data(representation.type.rawValue.utf8)
                sink.append(uint64: typeBytes.count)
                sink.append(typeBytes)
                switch representation.payload {
                case .bytes(let data):
                    sink.append(uint64: data.count)
                    sink.append(data)
                case .filePaths(let paths):
                    sink.append(uint64: fileListLength(paths))
                    writeFileList(paths, to: &sink)
                }
            }
        }
    }

    private static func writeFileList(_ paths: [String], to sink: inout some ByteSink) {
        sink.append(uint64: paths.count)
        for path in paths {
            let bytes = Data(path.utf8)
            sink.append(uint64: bytes.count)
            sink.append(bytes)
        }
    }

    private static func fileListLength(_ paths: [String]) -> Int {
        8 + paths.reduce(0) { $0 + 8 + $1.utf8.count }
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

private protocol ByteSink {
    mutating func append(_ data: Data)
}

extension ByteSink {
    mutating func append(uint64 value: Int) {
        let bigEndian = UInt64(value).bigEndian
        append(withUnsafeBytes(of: bigEndian) { Data($0) })
    }
}

private struct HashSink: ByteSink {
    var hasher = SHA256()
    mutating func append(_ data: Data) { hasher.update(data: data) }
}

private struct DataSink: ByteSink {
    var data = Data()
    mutating func append(_ data: Data) { self.data.append(data) }
}
