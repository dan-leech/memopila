import Foundation

/// Line by line changes between the saved and the edited text, for *Changes* in the record window
/// (PLAN §8.5). Kept small whatever the text: the common start and end are skipped without
/// comparing, only up to `maxCompared` differing lines per side are matched line by line (beyond
/// that the middle shows as removed, then added), at most `maxRows` rows are produced, and a line
/// longer than `maxLineLength` characters is cut.
public struct LineDiff: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case same, removed, added
    }

    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String
        /// 1-based, in the saved text; `nil` for an added line.
        public let oldNumber: Int?
        /// 1-based, in the edited text; `nil` for a removed line.
        public let newNumber: Int?
    }

    public enum Row: Sendable, Equatable {
        case line(Line)
        /// Unchanged lines left out between changes.
        case skipped(Int)
    }

    public let rows: [Row]
    public let added: Int
    public let removed: Int
    /// More rows than `maxRows`: the rest is left out.
    public let isTruncated: Bool

    public var isEmpty: Bool { added == 0 && removed == 0 }

    /// `context` unchanged lines are shown around each change.
    public static func compare(
        _ old: String,
        _ new: String,
        context: Int = 3,
        maxCompared: Int = 500,
        maxRows: Int = 2_000,
        maxLineLength: Int = 1_000
    ) -> LineDiff {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = prefix..<(oldLines.count - suffix)
        let newMiddle = prefix..<(newLines.count - suffix)

        // The whole text as runs of unchanged lines and single changed ones.
        var segments: [Segment] = [.same(old: 0, new: 0, count: prefix)]
        if oldMiddle.count <= maxCompared, newMiddle.count <= maxCompared {
            let difference = Array(newLines[newMiddle]).difference(from: Array(oldLines[oldMiddle]))
            var isRemoved = [Bool](repeating: false, count: oldMiddle.count)
            var isInserted = [Bool](repeating: false, count: newMiddle.count)
            for change in difference {
                switch change {
                case .remove(let offset, _, _): isRemoved[offset] = true
                case .insert(let offset, _, _): isInserted[offset] = true
                }
            }
            var i = 0
            var j = 0
            while i < oldMiddle.count || j < newMiddle.count {
                if i < oldMiddle.count, isRemoved[i] {
                    segments.append(.removed(prefix + i))
                    i += 1
                } else if j < newMiddle.count, isInserted[j] {
                    segments.append(.added(prefix + j))
                    j += 1
                } else {
                    if case .same(let o, let n, let count) = segments.last, o + count == prefix + i, n + count == prefix + j {
                        segments[segments.count - 1] = .same(old: o, new: n, count: count + 1)
                    } else {
                        segments.append(.same(old: prefix + i, new: prefix + j, count: 1))
                    }
                    i += 1
                    j += 1
                }
            }
        } else {
            segments += oldMiddle.map(Segment.removed)
            segments += newMiddle.map(Segment.added)
        }
        segments.append(.same(old: oldMiddle.upperBound, new: newMiddle.upperBound, count: suffix))

        let unchanged = segments.reduce(0) { $0 + $1.unchangedCount }
        let removed = oldLines.count - unchanged
        let added = newLines.count - unchanged
        guard let firstChange = segments.firstIndex(where: \.isChange),
              let lastChange = segments.lastIndex(where: \.isChange) else {
            return LineDiff(rows: [], added: 0, removed: 0, isTruncated: false)
        }

        var rows: [Row] = []
        var lineRows = 0
        var changesShown = 0
        func clip(_ line: Substring) -> String {
            guard let end = line.index(line.startIndex, offsetBy: maxLineLength, limitedBy: line.endIndex), end < line.endIndex else {
                return String(line)
            }
            return String(line[..<end]) + "…"
        }
        func appendSame(_ old: Int, _ new: Int) {
            rows.append(.line(Line(kind: .same, text: clip(oldLines[old]), oldNumber: old + 1, newNumber: new + 1)))
            lineRows += 1
        }
        for (index, segment) in segments.enumerated() where lineRows < maxRows {
            switch segment {
            case .removed(let old):
                rows.append(.line(Line(kind: .removed, text: clip(oldLines[old]), oldNumber: old + 1, newNumber: nil)))
                lineRows += 1
                changesShown += 1
            case .added(let new):
                rows.append(.line(Line(kind: .added, text: clip(newLines[new]), oldNumber: nil, newNumber: new + 1)))
                lineRows += 1
                changesShown += 1
            case .same(let old, let new, let count) where count > 0:
                // Before the first change only the lines leading to it, after the last only the
                // lines following it, in between both sides of the gap.
                let head = index < firstChange ? 0 : min(context, count)
                let tail = index > lastChange ? 0 : min(context, count - head)
                for offset in 0..<head { appendSame(old + offset, new + offset) }
                if count - head - tail > 0 { rows.append(.skipped(count - head - tail)) }
                for offset in (count - tail)..<count { appendSame(old + offset, new + offset) }
            case .same:
                break
            }
        }
        return LineDiff(rows: rows, added: added, removed: removed, isTruncated: changesShown < added + removed)
    }

    private enum Segment {
        case same(old: Int, new: Int, count: Int)
        case removed(Int)
        case added(Int)

        var isChange: Bool {
            switch self {
            case .same: false
            case .removed, .added: true
            }
        }

        var unchangedCount: Int {
            switch self {
            case .same(_, _, let count): count
            case .removed, .added: 0
            }
        }
    }

    /// Lines without their breaks; `\r\n`, `\r` and `\n` all end a line.
    private static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }
}
