import Foundation

/// Kinds of credentials recognized in copied text (PLAN §3.10). Prefix-based patterns only, so
/// ordinary developer text (git SHAs, UUIDs, hashes) is never flagged.
public enum SecretKind: String, Sendable, Equatable, Codable, CaseIterable {
    case privateKey
    case jwt
    case githubToken
    case gitlabToken
    case awsAccessKey
    case slackToken
    case stripeKey
    case googleAPIKey
    case openAIKey
    case anthropicKey
    case npmToken
    case creditCard

    public var displayName: String {
        switch self {
        case .privateKey: "Private key"
        case .jwt: "JWT"
        case .githubToken: "GitHub token"
        case .gitlabToken: "GitLab token"
        case .awsAccessKey: "AWS access key"
        case .slackToken: "Slack token"
        case .stripeKey: "Stripe key"
        case .googleAPIKey: "Google API key"
        case .openAIKey: "OpenAI key"
        case .anthropicKey: "Anthropic key"
        case .npmToken: "npm token"
        case .creditCard: "Card number"
        }
    }
}

/// What to do with a change whose text contains a secret (PLAN §3.10).
public enum SecretPolicy: Sendable, Hashable, Codable {
    /// Save as usual.
    case off
    /// Mark handled without saving; no Current card.
    case dontSave
    /// Save, mask on cards, delete after the given minutes (favorites keep it).
    case deleteAfter(minutes: Int)

    public static let `default` = SecretPolicy.deleteAfter(minutes: 8 * 60)
}

/// A credential found in copied text (PLAN §3.10).
public struct SecretMatch: Sendable, Equatable {
    public let kind: SecretKind
    /// The matched token (or the whole trimmed text for a card number).
    public let matched: String
    /// True when the secret is only a part of a larger paste (.env, logs) — card title stays generic.
    public let isEmbedded: Bool

    public init(kind: SecretKind, matched: String, isEmbedded: Bool) {
        self.kind = kind
        self.matched = matched
        self.isEmbedded = isEmbedded
    }
}

public enum SecretDetector {
    /// Secrets are short; larger text is not scanned (keeps capture cheap).
    public static let maxScannedBytes = 256 * 1_024
    /// A card number counts only when it is (nearly) all the text, so IDs in logs are not flagged.
    static let maxCardTextLength = 64

    private static let patterns: [(SecretKind, String)] = [
        // Full PEM block — a lone key must not count as “embedded” (BEGIN-line-only would).
        (.privateKey, #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]+?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----"#),
        (.jwt, #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        (.githubToken, #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})"#),
        (.gitlabToken, #"\bglpat-[A-Za-z0-9_-]{20,}"#),
        (.awsAccessKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        (.slackToken, #"\bxox[abposr]-[A-Za-z0-9-]{10,}|https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}"#),
        (.stripeKey, #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}"#),
        (.googleAPIKey, #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        (.anthropicKey, #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
        (.openAIKey, #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,}"#),
        (.npmToken, #"\bnpm_[A-Za-z0-9]{36}\b"#),
    ]

    /// The first enabled secret kind found in `text`, or `nil`.
    public static func detect(_ text: String, kinds: Set<SecretKind> = Set(SecretKind.allCases)) -> SecretKind? {
        detectMatch(text, kinds: kinds)?.kind
    }

    /// First enabled secret in `text`, with the matched span (for card mask / embedded title).
    public static func detectMatch(
        _ text: String,
        kinds: Set<SecretKind> = Set(SecretKind.allCases)
    ) -> SecretMatch? {
        guard !kinds.isEmpty, text.utf8.count <= maxScannedBytes else { return nil }
        for (kind, pattern) in patterns where kinds.contains(kind) {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let matched = String(text[range])
                return SecretMatch(
                    kind: kind,
                    matched: matched,
                    isEmbedded: isEmbedded(matchLength: matched.count, hostLength: text.trimmingCharacters(in: .whitespacesAndNewlines).count)
                )
            }
        }
        if kinds.contains(.creditCard), isCardNumber(text) {
            let matched = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SecretMatch(kind: .creditCard, matched: matched, isEmbedded: false)
        }
        return nil
    }

    /// Match for a known kind inside already-stored preview text (card chrome).
    public static func match(of kind: SecretKind, in text: String) -> String? {
        if kind == .creditCard {
            return isCardNumber(text) ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        guard let pattern = patterns.first(where: { $0.0 == kind })?.1,
              let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Host paste is more than the credential (.env / dump). Ratio avoids treating a long JWT/PEM as embedded.
    public static func isEmbedded(matchLength: Int, hostLength: Int) -> Bool {
        guard matchLength > 0, hostLength > 0 else { return false }
        // ≥80% of the paste is the credential → the paste *is* the secret.
        return matchLength * 5 < hostLength * 4
    }

    public static func isEmbedded(match: String, in text: String) -> Bool {
        isEmbedded(
            matchLength: match.count,
            hostLength: text.trimmingCharacters(in: .whitespacesAndNewlines).count
        )
    }

    /// 13–19 digits (spaces or dashes allowed) with a known network prefix and a valid Luhn sum.
    static func isCardNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxCardTextLength else { return false }
        // ASCII digits only: `wholeNumberValue` is a numeral's value, and 京 is 10¹⁶ (review
        // finding: the prefix arithmetic overflowed and the app crashed on every capture of it).
        guard trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }) else { return false }
        let digits = trimmed.compactMap { $0.isNumber ? $0.asciiValue.map { Int($0) - 48 } : nil }
        guard (13...19).contains(digits.count) else { return false }
        let prefix2 = digits[0] * 10 + digits[1]
        let prefix4 = prefix2 * 100 + digits[2] * 10 + digits[3]
        let knownNetwork = digits[0] == 4 || (51...55).contains(prefix2) || (2221...2720).contains(prefix4)
            || prefix2 == 34 || prefix2 == 37 || prefix4 == 6011 || prefix2 == 65
        guard knownNetwork else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    /// Card text for a masked secret: the first characters and dots, never the whole value.
    /// Prefer the matched token when `kind` is known so a .env dump does not mask `DATABASE_URL=…`.
    public static func maskedPreview(
        of text: String,
        kind: SecretKind? = nil,
        visible: Int = 10
    ) -> String {
        let source = kind.flatMap { match(of: $0, in: text) } ?? text
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(visible).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return head + "••••••••"
    }
}
