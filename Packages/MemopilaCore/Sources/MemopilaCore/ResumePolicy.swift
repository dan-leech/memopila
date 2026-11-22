import Foundation

public enum ResumeDecision: Sendable, Equatable {
    case leaveOpen
    case markHandled(changeCount: Int)
}

/// Pure resume peek policy (manual + timed pause end).
public enum ResumePolicy {
    public static func decide(_ peek: TypesPeek, changeCount: Int) -> ResumeDecision {
        switch peek {
        case .empty, .ephemeralPrivacy, .peekFailed:
            return .leaveOpen
        case .hasContent, .confidential:
            return .markHandled(changeCount: changeCount)
        }
    }
}
