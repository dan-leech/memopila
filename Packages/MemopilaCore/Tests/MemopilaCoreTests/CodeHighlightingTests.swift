import Testing
@testable import MemopilaCore

@Suite("Code highlighting (§8.5)")
struct CodeHighlightingTests {
    private func kinds(_ text: String, _ language: CodeLanguage) -> [(String, CodeToken.Kind)] {
        CodeHighlighter.tokenize(text, as: language).map { (String(text[$0.range]), $0.kind) }
    }

    @Test(arguments: [
        (#"{"name": "Memopila", "count": 3}"#, CodeLanguage.json),
        ("import SwiftUI\n\nstruct Card: View {\n    let title: String\n}", .swift),
        ("def greet(name):\n    if name:\n        return f\"hi {name}\"", .python),
        ("SELECT id, name FROM users WHERE id = 1;", .sql),
        ("#!/bin/bash\nset -e\necho \"hi\"", .shell),
        ("git commit -m \"Fix\" && git push", .shell),
        ("<div class=\"card\"><p>Hi</p></div>", .html),
        ("package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}", .go),
        ("const sum = (a, b) => a + b;\nconsole.log(sum(1, 2));", .javascript),
    ])
    func detection(_ text: String, _ expected: CodeLanguage) {
        #expect(CodeHighlighter.detect(text) == expected)
    }

    @Test(arguments: [
        "Hello, can we meet tomorrow at 10? I will bring the documents.",
        "Участники, удостоенные специальных дипломов",
        "docs/PLAN.md",
        "http://127.0.0.1:8088/page103",
    ])
    func proseIsNotCode(_ text: String) {
        #expect(CodeHighlighter.detect(text) == nil)
    }

    @Test func sourceAppLowersTheThreshold() {
        let snippet = "let x = 1"
        #expect(CodeHighlighter.detect(snippet) == nil)
        #expect(CodeHighlighter.detect(snippet, sourceBundleID: "com.apple.dt.Xcode") == .swift)
    }

    @Test func swiftTokens() {
        let tokens = kinds("let name = \"a // b\" // note\nreturn 42", .swift)
        #expect(tokens.map(\.0) == ["let", "\"a // b\"", "// note", "return", "42"])
        #expect(tokens.map(\.1) == [.keyword, .string, .comment, .keyword, .number])
    }

    @Test func jsonKeysAndValues() {
        let tokens = kinds(#"{"a": "b", "n": 1.5, "t": true}"#, .json)
        #expect(tokens.map(\.1) == [.key, .string, .key, .number, .key, .keyword])
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        #expect(kinds("select * FROM t -- x", .sql).map(\.1) == [.keyword, .keyword, .comment])
    }

    @Test func markupTagsAndAttributes() {
        let tokens = kinds(#"<a href="x">y</a><!-- c -->"#, .html)
        #expect(tokens.map(\.0) == ["<a", "href", "\"x\"", "</a", "<!-- c -->"])
        #expect(tokens.map(\.1) == [.tag, .attribute, .string, .tag, .comment])
    }

    @Test func pythonTripleQuotesAndComments() {
        let tokens = kinds("x = \"\"\"doc\nmore\"\"\"  # end", .python)
        #expect(tokens.map(\.1) == [.string, .comment])
    }

    @Test func shellHashInsideWordIsNotAComment() {
        let tokens = kinds("echo a#b # real", .shell)
        #expect(tokens.last?.1 == .comment)
        #expect(tokens.filter { $0.1 == .comment }.count == 1)
    }

    @Test func unicodeStaysAligned() {
        let text = "let ё = \"привет\" // 🙂"
        let tokens = CodeHighlighter.tokenize(text, as: .swift)
        #expect(tokens.map { String(text[$0.range]) } == ["let", "\"привет\"", "// 🙂"])
    }
}
