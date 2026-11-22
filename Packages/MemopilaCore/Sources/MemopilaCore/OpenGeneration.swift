import Foundation

public enum EmptyDisposition: Sendable, Equatable {
    /// hits < 2: Nap heat
    case provisional(hits: Int)
    /// hits ≥ 2: still unhandled; cheap re-peek; no Nap heat
    case quietOpen
}

public enum ConfidentialDisposition: Sendable, Equatable {
    case progress(hits: Int)
    case stable(PasteboardType)
}

/// Leave-open machines for empty and confidential peeks on one changeCount (SSOT).
public struct OpenGeneration: Sendable, Equatable {
    public private(set) var changeCount: Int?
    public private(set) var emptyHits = 0
    public private(set) var confidentialHits = 0
    public private(set) var confidentialType: PasteboardType?

    public init() {}

    public var hasProvisionalHeat: Bool {
        guard changeCount != nil else { return false }
        return emptyHits > 0 && emptyHits < 2
    }

    /// Only when Skip is not armed. Idempotent once quietOpen for the same N.
    public mutating func noteEmpty(_ n: Int) -> EmptyDisposition {
        if changeCount != n {
            reset(keepingCount: n)
        }
        if emptyHits >= 2 { return .quietOpen }
        emptyHits += 1
        confidentialHits = 0
        confidentialType = nil
        return emptyHits < 2 ? .provisional(hits: emptyHits) : .quietOpen
    }

    public mutating func noteConfidential(_ n: Int, type: PasteboardType) -> ConfidentialDisposition {
        if changeCount != n || confidentialType != type {
            changeCount = n
            emptyHits = 0
            confidentialHits = 0
            confidentialType = type
        }
        confidentialHits += 1
        emptyHits = 0
        if confidentialHits >= 2 { return .stable(type) }
        return .progress(hits: confidentialHits)
    }

    public mutating func reset() {
        changeCount = nil
        emptyHits = 0
        confidentialHits = 0
        confidentialType = nil
    }

    private mutating func reset(keepingCount n: Int) {
        changeCount = n
        emptyHits = 0
        confidentialHits = 0
        confidentialType = nil
    }
}
