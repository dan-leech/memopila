import Foundation

/// Languages the preview highlights (PLAN §8.5). Own lightweight tokenizer: no JavaScriptCore,
/// no grammar files, a few KB of memory, so it fits the preview budget (§7.3).
public enum CodeLanguage: String, CaseIterable, Sendable, Codable {
    case swift, javascript, typescript, python, json, shell, sql, html, css, yaml, go, rust, java, kotlin, c, cpp, csharp, ruby, php

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .json: "JSON"
        case .shell: "Shell"
        case .sql: "SQL"
        case .html: "HTML / XML"
        case .css: "CSS"
        case .yaml: "YAML"
        case .go: "Go"
        case .rust: "Rust"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .ruby: "Ruby"
        case .php: "PHP"
        }
    }
}

public struct CodeToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyword, string, comment, number, key, tag, attribute
    }

    public let range: Range<String.Index>
    public let kind: Kind
}

public enum CodeHighlighter {
    /// Editors and terminals: their copies are usually code, so detection is more permissive.
    public static let codeSourceApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
        "com.panic.Nova", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.macromates.TextMate", "dev.zed.Zed", "com.mitchellh.ghostty",
    ]

    // MARK: Detection

    /// `nil` when the text does not look like code.
    public static func detect(_ text: String, sourceBundleID: String? = nil) -> CodeLanguage? {
        let sample = String(text.prefix(4_000))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        if let first = trimmed.first, first == "{" || first == "[",
           let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return .json
        }
        if trimmed.hasPrefix("<?php") { return .php }
        if trimmed.hasPrefix("<"), trimmed.contains("</") || trimmed.contains("/>") { return .html }

        let fromCodeApp = sourceBundleID.map { codeSourceApps.contains($0) || $0.hasPrefix("com.jetbrains.") } ?? false
        var best: (language: CodeLanguage, score: Int)?
        for (language, signals) in detectionSignals {
            let score = signals.reduce(0) { $0 + (sample.range(of: $1.pattern, options: $1.options) != nil ? $1.weight : 0) }
            if score > (best?.score ?? 0) { best = (language, score) }
        }
        guard let best else { return nil }
        return best.score >= (fromCodeApp ? 2 : 4) ? best.language : nil
    }

    private struct Signal {
        let pattern: String
        let weight: Int
        var options: String.CompareOptions = .regularExpression
    }

    private static let detectionSignals: [(CodeLanguage, [Signal])] = [
        (.swift, [Signal(pattern: #"\bfunc \w+\("#, weight: 3), Signal(pattern: #"\b(let|var) \w+(: [A-Z]\w*)? ="#, weight: 2),
                  Signal(pattern: #"\bimport (SwiftUI|Foundation|AppKit|UIKit)\b"#, weight: 4), Signal(pattern: #"\bguard let\b"#, weight: 3),
                  Signal(pattern: #"\b(struct|enum|protocol|extension) \w+"#, weight: 2), Signal(pattern: #"@\w+\b"#, weight: 1)]),
        (.python, [Signal(pattern: #"\bdef \w+\(.*\):"#, weight: 4), Signal(pattern: #"(?m)^\s*(from \w+ )?import \w+"#, weight: 2),
                   Signal(pattern: #"\bself\."#, weight: 1), Signal(pattern: #"\belif\b"#, weight: 3), Signal(pattern: #"(?m):\s*$"#, weight: 1)]),
        (.javascript, [Signal(pattern: #"\b(const|let) \w+ = "#, weight: 2), Signal(pattern: #"\bfunction\b"#, weight: 2),
                       Signal(pattern: "=>", weight: 1, options: []), Signal(pattern: #"console\.log\("#, weight: 3),
                       Signal(pattern: #"\brequire\(['"]"#, weight: 3), Signal(pattern: #"import .* from ['"]"#, weight: 3)]),
        (.typescript, [Signal(pattern: #"\binterface \w+ \{"#, weight: 3), Signal(pattern: #": (string|number|boolean)\b"#, weight: 3),
                       Signal(pattern: #"\btype \w+ = "#, weight: 2), Signal(pattern: #"import .* from ['"]"#, weight: 2)]),
        (.shell, [Signal(pattern: #"(?m)^#!/(usr/)?bin/(env )?(ba|z)?sh"#, weight: 5), Signal(pattern: #"(?m)^\s*\$ "#, weight: 3),
                  Signal(pattern: #"(?m)^\s*(sudo|cd|ls|git|brew|npm|yarn|export|echo|curl|docker|kubectl|swift|xcodebuild) "#, weight: 3),
                  Signal(pattern: #"\|\s*(grep|awk|sed|xargs)\b"#, weight: 2), Signal(pattern: #"\s--?\w+"#, weight: 1)]),
        (.sql, [Signal(pattern: #"\bSELECT\b[\s\S]*\bFROM\b"#, weight: 5, options: [.regularExpression, .caseInsensitive]),
                Signal(pattern: #"\b(INSERT INTO|CREATE TABLE|UPDATE \w+ SET|DELETE FROM|ALTER TABLE)\b"#, weight: 5, options: [.regularExpression, .caseInsensitive])]),
        (.css, [Signal(pattern: #"(?m)^[.#]?[\w-]+\s*\{"#, weight: 2), Signal(pattern: #"(?m)^\s*[\w-]+:\s*[^;]+;\s*$"#, weight: 2),
                Signal(pattern: #"@media\b"#, weight: 3)]),
        (.yaml, [Signal(pattern: #"(?m)^---\s*$"#, weight: 2), Signal(pattern: #"(?m)^\s*[\w-]+:\s+\S"#, weight: 1), Signal(pattern: #"(?m)^\s*- [\w-]+:"#, weight: 2)]),
        (.go, [Signal(pattern: #"(?m)^package \w+"#, weight: 4), Signal(pattern: #"\bfunc (\(\w+ \*?\w+\) )?\w+\("#, weight: 2),
               Signal(pattern: ":=", weight: 2, options: []), Signal(pattern: #"\bfmt\.\w+"#, weight: 3)]),
        (.rust, [Signal(pattern: #"\bfn \w+"#, weight: 3), Signal(pattern: #"\blet mut\b"#, weight: 3), Signal(pattern: #"\bimpl\b"#, weight: 2),
                 Signal(pattern: #"\w+!\("#, weight: 2), Signal(pattern: "::", weight: 1, options: [])]),
        (.java, [Signal(pattern: #"\bpublic (static )?(class|void|final)\b"#, weight: 3), Signal(pattern: #"System\.out\.print"#, weight: 4)]),
        (.kotlin, [Signal(pattern: #"\bfun \w+\("#, weight: 3), Signal(pattern: #"\bval \w+"#, weight: 2)]),
        (.c, [Signal(pattern: #"#include\s*<\w+\.h>"#, weight: 4), Signal(pattern: #"\bint main\("#, weight: 3), Signal(pattern: #"\bprintf\("#, weight: 2)]),
        (.cpp, [Signal(pattern: #"#include\s*<\w+>"#, weight: 3), Signal(pattern: #"\bstd::"#, weight: 3), Signal(pattern: #"\btemplate\s*<"#, weight: 3)]),
        (.csharp, [Signal(pattern: #"\busing System\b"#, weight: 4), Signal(pattern: #"\bnamespace \w+"#, weight: 2), Signal(pattern: #"Console\.Write"#, weight: 4)]),
        (.ruby, [Signal(pattern: #"(?m)\bdef \w+[^:]*$"#, weight: 2), Signal(pattern: #"(?m)^\s*end\s*$"#, weight: 2), Signal(pattern: #"\bputs\b"#, weight: 2),
                 Signal(pattern: #"\brequire ['"]"#, weight: 2)]),
    ]

    // MARK: Tokenizing

    public static func tokenize(_ text: String, as language: CodeLanguage) -> [CodeToken] {
        let spec = LanguageSpec.spec(for: language)
        let scalars = text.unicodeScalars
        var tokens: [CodeToken] = []
        var index = scalars.startIndex

        func hasPrefix(_ prefix: String, at position: String.Index) -> Bool {
            var cursor = position
            for scalar in prefix.unicodeScalars {
                guard cursor < scalars.endIndex, scalars[cursor] == scalar else { return false }
                cursor = scalars.index(after: cursor)
            }
            return true
        }
        func advance(_ position: String.Index, by count: Int) -> String.Index {
            scalars.index(position, offsetBy: count, limitedBy: scalars.endIndex) ?? scalars.endIndex
        }
        func lineEnd(from position: String.Index) -> String.Index {
            var cursor = position
            while cursor < scalars.endIndex, scalars[cursor] != "\n" { cursor = scalars.index(after: cursor) }
            return cursor
        }
        func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || (spec.wordScalars.contains(scalar))
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]

            if spec.lineComments.contains(where: { hasPrefix($0, at: index) }),
               !spec.lineCommentNeedsBoundary || index == scalars.startIndex || CharacterSet.whitespacesAndNewlines.contains(scalars[scalars.index(before: index)]) {
                let end = lineEnd(from: index)
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                continue
            }
            if let (open, close) = spec.blockComment, hasPrefix(open, at: index) {
                var cursor = advance(index, by: open.unicodeScalars.count)
                while cursor < scalars.endIndex, !hasPrefix(close, at: cursor) { cursor = scalars.index(after: cursor) }
                let end = advance(cursor, by: close.unicodeScalars.count)
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                continue
            }
            if spec.stringDelimiters.contains(scalar) {
                let triple = String(repeating: String(scalar), count: 3)
                let isTriple = spec.tripleQuotes && hasPrefix(triple, at: index)
                var cursor = advance(index, by: isTriple ? 3 : 1)
                while cursor < scalars.endIndex {
                    if scalars[cursor] == "\\" {
                        cursor = advance(cursor, by: 2)
                        continue
                    }
                    if isTriple ? hasPrefix(triple, at: cursor) : scalars[cursor] == scalar {
                        cursor = advance(cursor, by: isTriple ? 3 : 1)
                        break
                    }
                    if !isTriple, scalars[cursor] == "\n", scalar != "`" { break }
                    cursor = scalars.index(after: cursor)
                }
                var kind = CodeToken.Kind.string
                if spec.keysBeforeColon {
                    var look = cursor
                    while look < scalars.endIndex, scalars[look] == " " { look = scalars.index(after: look) }
                    if look < scalars.endIndex, scalars[look] == ":" { kind = .key }
                }
                tokens.append(CodeToken(range: index..<cursor, kind: kind))
                index = cursor
                continue
            }
            if spec.markupTags, scalar == "<" {
                var cursor = scalars.index(after: index)
                if cursor < scalars.endIndex, scalars[cursor] == "/" || scalars[cursor] == "!" || scalars[cursor] == "?" { cursor = scalars.index(after: cursor) }
                let nameStart = cursor
                while cursor < scalars.endIndex, isWordScalar(scalars[cursor]) || scalars[cursor] == "-" || scalars[cursor] == ":" { cursor = scalars.index(after: cursor) }
                if cursor > nameStart {
                    tokens.append(CodeToken(range: index..<cursor, kind: .tag))
                    index = cursor
                    continue
                }
            }
            if CharacterSet.decimalDigits.contains(scalar),
               index == scalars.startIndex || !isWordScalar(scalars[scalars.index(before: index)]) {
                var cursor = index
                while cursor < scalars.endIndex, CharacterSet.alphanumerics.contains(scalars[cursor]) || scalars[cursor] == "." || scalars[cursor] == "_" {
                    cursor = scalars.index(after: cursor)
                }
                tokens.append(CodeToken(range: index..<cursor, kind: .number))
                index = cursor
                continue
            }
            if isWordScalar(scalar) {
                var cursor = index
                while cursor < scalars.endIndex, isWordScalar(scalars[cursor]) { cursor = scalars.index(after: cursor) }
                let word = String(scalars[index..<cursor])
                let lookup = spec.caseInsensitiveKeywords ? word.lowercased() : word
                if spec.keywords.contains(lookup) {
                    tokens.append(CodeToken(range: index..<cursor, kind: .keyword))
                } else if spec.keysBeforeColon || spec.markupTags {
                    var look = cursor
                    while look < scalars.endIndex, scalars[look] == " " { look = scalars.index(after: look) }
                    if look < scalars.endIndex {
                        if spec.keysBeforeColon, scalars[look] == ":", lineIsKeyPosition(scalars, index) {
                            tokens.append(CodeToken(range: index..<cursor, kind: .key))
                        } else if spec.markupTags, scalars[look] == "=" {
                            tokens.append(CodeToken(range: index..<cursor, kind: .attribute))
                        }
                    }
                }
                index = cursor
                continue
            }
            index = scalars.index(after: index)
        }
        return tokens
    }

    /// YAML / CSS keys start a line (after indentation or a list dash).
    private static func lineIsKeyPosition(_ scalars: String.UnicodeScalarView, _ index: String.Index) -> Bool {
        var cursor = index
        while cursor > scalars.startIndex {
            let previous = scalars.index(before: cursor)
            let scalar = scalars[previous]
            if scalar == "\n" || scalar == "{" || scalar == ";" { return true }
            if scalar != " " && scalar != "\t" && scalar != "-" { return false }
            cursor = previous
        }
        return true
    }
}

private struct LanguageSpec {
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false
    var lineComments: [String] = []
    var lineCommentNeedsBoundary = false
    var blockComment: (String, String)?
    var stringDelimiters: Set<Unicode.Scalar> = ["\"", "'"]
    var tripleQuotes = false
    var keysBeforeColon = false
    var markupTags = false
    var wordScalars: Set<Unicode.Scalar> = []

    static func spec(for language: CodeLanguage) -> LanguageSpec {
        let cLike = ["//"]
        let cBlock = ("/*", "*/")
        switch language {
        case .swift:
            return LanguageSpec(keywords: ["associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "let", "operator", "protocol", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try", "async", "await", "actor", "some", "any", "private", "public", "internal", "fileprivate", "static", "final", "override", "mutating", "lazy", "weak", "nonisolated", "rethrows", "open"], lineComments: cLike, blockComment: cBlock, stringDelimiters: ["\""], tripleQuotes: true, wordScalars: ["@", "#"])
        case .javascript, .typescript:
            var keywords: Set<String> = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "from", "in", "instanceof", "let", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield", "async", "await", "of", "static", "get", "set"]
            if language == .typescript { keywords.formUnion(["interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "string", "number", "boolean", "any", "unknown", "never", "as", "keyof"]) }
            return LanguageSpec(keywords: keywords, lineComments: cLike, blockComment: cBlock, stringDelimiters: ["\"", "'", "`"])
        case .python:
            return LanguageSpec(keywords: ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self"], lineComments: ["#"], tripleQuotes: true)
        case .json:
            return LanguageSpec(keywords: ["true", "false", "null"], stringDelimiters: ["\""], keysBeforeColon: true)
        case .shell:
            return LanguageSpec(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "sudo", "echo", "cd", "exit"], lineComments: ["#"], lineCommentNeedsBoundary: true, wordScalars: ["-", "$"])
        case .sql:
            return LanguageSpec(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "null", "is", "in", "like", "primary", "key", "foreign", "references", "index", "union", "all", "case", "when", "then", "else", "end", "asc", "desc", "count", "sum", "avg", "min", "max", "with", "returning", "default", "unique", "exists"], caseInsensitiveKeywords: true, lineComments: ["--"], blockComment: cBlock)
        case .html:
            return LanguageSpec(blockComment: ("<!--", "-->"), markupTags: true)
        case .css:
            return LanguageSpec(keywords: ["important", "media", "import", "from", "to"], blockComment: cBlock, keysBeforeColon: true, wordScalars: ["-"])
        case .yaml:
            return LanguageSpec(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], lineCommentNeedsBoundary: true, keysBeforeColon: true, wordScalars: ["-"])
        case .go:
            return LanguageSpec(keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "iota", "string", "int", "bool", "error"], lineComments: cLike, blockComment: cBlock, stringDelimiters: ["\"", "'", "`"])
        case .rust:
            return LanguageSpec(keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "Some", "None", "Ok", "Err"], lineComments: cLike, blockComment: cBlock, stringDelimiters: ["\""])
        case .java, .kotlin, .csharp:
            return LanguageSpec(keywords: ["abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "package", "private", "protected", "public", "return", "short", "static", "super", "switch", "this", "throw", "throws", "try", "void", "while", "true", "false", "null", "fun", "val", "var", "when", "object", "override", "using", "namespace", "string", "var", "async", "await"], lineComments: cLike, blockComment: cBlock, tripleQuotes: language == .kotlin)
        case .c, .cpp:
            return LanguageSpec(keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "new", "delete", "true", "false", "nullptr", "bool", "auto", "using", "#include", "#define", "#ifdef", "#ifndef", "#endif", "#if", "#else"], lineComments: cLike, blockComment: cBlock, wordScalars: ["#"])
        case .ruby:
            return LanguageSpec(keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "puts"], lineComments: ["#"])
        case .php:
            return LanguageSpec(keywords: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "extends", "final", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "list", "namespace", "new", "or", "print", "private", "protected", "public", "require", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "true", "false", "null", "fn", "match"], lineComments: ["//", "#"], blockComment: cBlock, wordScalars: ["$"])
        }
    }
}
