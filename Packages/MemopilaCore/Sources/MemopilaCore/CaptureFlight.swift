import Foundation

public enum PasteboardLeaseKind: Sendable, Equatable {
    case destructive
    case ownedWrite
}

public struct PasteboardLease: Sendable, Equatable {
    public let kind: PasteboardLeaseKind
    public let opSeq: Int

    public init(kind: PasteboardLeaseKind, opSeq: Int) {
        self.kind = kind
        self.opSeq = opSeq
    }
}

/// Pasteboard capture/mutate flight (not store-only destructive, not session advanceGate).
public enum CaptureFlight: Sendable, Equatable {
    case idle
    case reading(readerSeq: Int)
    case ingesting(changeCount: Int)
    case leased(PasteboardLease)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}
