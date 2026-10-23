import Foundation

/// The fixed v1 set of text actions (PLAN §3.9). Pure functions on `String`.
public enum TextAction: String, Sendable, CaseIterable, Codable {
    case trimWhitespace
    case removeLineBreaks
    case uppercase
    case lowercase
    case titleCase
    case sortLines
    case removeDuplicateLines
    case formatJSON
    case minifyJSON
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode

    /// `nil` when the action does not apply to this text (shown disabled in the UI).
    public func apply(to text: String) -> String? {
        switch self {
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLineBreaks:
            guard Self.isMultiline(text) else { return nil }
            return Self.lines(of: text)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            return text.capitalized
        case .sortLines:
            guard Self.isMultiline(text) else { return nil }
            return Self.mapLines(text) { lines in
                lines.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }
            }
        case .removeDuplicateLines:
            guard Self.isMultiline(text) else { return nil }
            return Self.mapLines(text) { lines in
                var seen: Set<String> = []
                return lines.filter { seen.insert($0).inserted }
            }
        case .formatJSON:
            return JSONText.format(text, pretty: true)
        case .minifyJSON:
            return JSONText.format(text, pretty: false)
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved)
        case .urlDecode:
            guard text.contains("%"), let decoded = text.removingPercentEncoding else { return nil }
            return decoded
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let compact = text.filter { !$0.isWhitespace }
            guard !compact.isEmpty, let data = Data(base64Encoded: compact) else { return nil }
            return String(validating: data, as: UTF8.self)
        }
    }

    public func isAvailable(for text: String) -> Bool { apply(to: text) != nil }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded.
    private static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func isMultiline(_ text: String) -> Bool {
        text.contains(where: \.isNewline)
    }

    private static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// Applies `transform` to the lines; a trailing line break is preserved, line breaks become `\n`.
    private static func mapLines(_ text: String, _ transform: ([String]) -> [String]) -> String {
        var lines = Self.lines(of: text)
        let hadTrailingBreak = text.last?.isNewline == true
        if hadTrailingBreak { lines.removeLast() }
        let result = transform(lines).joined(separator: "\n")
        return hadTrailingBreak ? result + "\n" : result
    }
}

/// Order-preserving JSON re-formatter: validates with `JSONSerialization`, then re-indents tokens
/// without parsing into dictionaries, so key order and number spelling are kept.
enum JSONText {
    static func format(_ text: String, pretty: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }

        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        let characters = Array(trimmed)
        var index = 0

        func newline() {
            output.append("\n")
            output.append(String(repeating: "  ", count: depth))
        }

        while index < characters.count {
            let character = characters[index]
            defer { index += 1 }

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                let closing: Character = character == "{" ? "}" : "]"
                if let next = nextSignificant(characters, after: index), characters[next] == closing {
                    output.append(closing)
                    index = next
                } else {
                    depth += 1
                    if pretty { newline() }
                }
            case "}", "]":
                depth -= 1
                if pretty { newline() }
                output.append(character)
            case ",":
                output.append(character)
                if pretty { newline() }
            case ":":
                output.append(pretty ? ": " : ":")
            case _ where character.isWhitespace:
                break
            default:
                output.append(character)
            }
        }
        return output
    }

    private static func nextSignificant(_ characters: [Character], after index: Int) -> Int? {
        var next = index + 1
        while next < characters.count, characters[next].isWhitespace { next += 1 }
        return next < characters.count ? next : nil
    }
}
