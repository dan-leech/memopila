import Testing
@testable import MemopilaCore

@Suite("Changes before saving (§8.5)")
struct LineDiffTests {
    @Test func noChanges() {
        let diff = LineDiff.compare("a\nb", "a\nb")
        #expect(diff.isEmpty)
        #expect(diff.rows.isEmpty)
    }

    @Test func changedLineWithContext() {
        let diff = LineDiff.compare("a\nb\nc", "a\nB\nc")
        #expect(diff.removed == 1)
        #expect(diff.added == 1)
        #expect(diff.rows == [
            .line(.init(kind: .same, text: "a", oldNumber: 1, newNumber: 1)),
            .line(.init(kind: .removed, text: "b", oldNumber: 2, newNumber: nil)),
            .line(.init(kind: .added, text: "B", oldNumber: nil, newNumber: 2)),
            .line(.init(kind: .same, text: "c", oldNumber: 3, newNumber: 3)),
        ])
    }

    @Test func insertionAndDeletionNumbers() {
        let inserted = LineDiff.compare("a\nc", "a\nb\nc")
        #expect(inserted.added == 1 && inserted.removed == 0)
        #expect(inserted.rows.contains(.line(.init(kind: .added, text: "b", oldNumber: nil, newNumber: 2))))
        #expect(inserted.rows.last == .line(.init(kind: .same, text: "c", oldNumber: 2, newNumber: 3)))
        let deleted = LineDiff.compare("a\nb\nc", "a\nc")
        #expect(deleted.removed == 1 && deleted.added == 0)
        #expect(deleted.rows.contains(.line(.init(kind: .removed, text: "b", oldNumber: 2, newNumber: nil))))
    }

    @Test func distantUnchangedLinesAreSkipped() {
        let old = (1...40).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n20\n", with: "\ntwenty\n")
        let diff = LineDiff.compare(old, new, context: 2)
        // 17 skipped before, 2 + 2 context around the change, 18 skipped after.
        #expect(diff.rows.first == .skipped(17))
        #expect(diff.rows.last == .skipped(18))
        #expect(diff.rows.count == 1 + 2 + 2 + 2 + 1)
    }

    @Test func changesFarApartKeepTheGapBetween() {
        let old = (1...30).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n5\n", with: "\nfive\n").replacingOccurrences(of: "\n25\n", with: "\n25b\n")
        let diff = LineDiff.compare(old, new, context: 1)
        #expect(diff.removed == 2 && diff.added == 2)
        #expect(diff.rows.contains(.skipped(17)), "lines 7…23 between the two changes")
    }

    @Test func lineBreakStylesCountAsBreaks() {
        let diff = LineDiff.compare("a\r\nb", "a\nb")
        #expect(diff.isEmpty)
    }

    @Test func largeMiddleIsShownAsReplacedBlock() {
        let old = (1...50).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...50).map { "new \($0)" }.joined(separator: "\n")
        let diff = LineDiff.compare(old, new, maxCompared: 10, maxRows: 30)
        #expect(diff.removed == 50 && diff.added == 50)
        #expect(diff.isTruncated)
        #expect(diff.rows.count == 30)
        #expect(diff.rows.first == .line(.init(kind: .removed, text: "old 1", oldNumber: 1, newNumber: nil)))
    }
}

extension LineDiffTests {
    @Test func longLinesAreCut() {
        let diff = LineDiff.compare("short", String(repeating: "x", count: 50), maxLineLength: 10)
        #expect(diff.rows.last == .line(.init(kind: .added, text: String(repeating: "x", count: 10) + "…", oldNumber: nil, newNumber: 1)))
    }
}
