import Foundation

/// Keyboard-layout remapping: same physical keys, different characters (PLAN layout convert).
/// Pure — maps are supplied by the App (UCKeyTranslate) or by tests (fixtures).
public enum LayoutConverter: Sendable {
    /// Hard cap per ⌥⌘B cycle (UTF-16). Longer selections toast and are left untouched.
    public static let maxConvertibleUTF16 = 120
    /// Minimum letter count before best-fit is trusted.
    public static let minimumLetters = 2
    /// Winner must cover at least this fraction of letters.
    public static let minimumCoverage = 0.8
    /// Winner must beat the runner-up by at least this margin (absolute coverage).
    public static let minimumLead = 0.15

    /// Whether `text` is within the convert length budget (UTF-16).
    public static func isConvertibleLength(_ text: String) -> Bool {
        (text as NSString).length <= maxConvertibleUTF16
    }

    /// Applies `map` character-by-character; unmapped characters stay unchanged.
    public static func apply(_ text: String, map: [Character: Character]) -> String {
        String(text.map { map[$0] ?? $0 })
    }

    /// Letter characters only (for coverage / best-fit).
    public static func letters(in text: String) -> [Character] {
        text.filter(\.isLetter)
    }

    /// Fraction of letters in `text` that appear as keys in `charset` (the layout's produced characters).
    public static func coverage(_ text: String, charset: Set<Character>) -> Double {
        let letters = letters(in: text)
        guard !letters.isEmpty else { return 0 }
        let hits = letters.filter { charset.contains($0) }.count
        return Double(hits) / Double(letters.count)
    }

    public struct Fit: Sendable, Equatable {
        public let layoutID: String
        public let coverage: Double

        public init(layoutID: String, coverage: Double) {
            self.layoutID = layoutID
            self.coverage = coverage
        }
    }

    public enum BestFitResult: Sendable, Equatable {
        case confident(Fit)
        case uncertain
    }

    /// Picks the layout whose charset best explains the letters in `text`.
    /// `layouts`: id → characters that layout can produce (from its key map values + keys).
    /// On a tie within `minimumLead`, prefers `preferredID` when it is among the tied leaders.
    public static func bestFit(
        text: String,
        layouts: [String: Set<Character>],
        preferredID: String?
    ) -> BestFitResult {
        let letterCount = letters(in: text).count
        guard letterCount >= minimumLetters, !layouts.isEmpty else { return .uncertain }

        let ranked = layouts.map { Fit(layoutID: $0.key, coverage: coverage(text, charset: $0.value)) }
            .sorted { lhs, rhs in
                if lhs.coverage != rhs.coverage { return lhs.coverage > rhs.coverage }
                return lhs.layoutID < rhs.layoutID
            }
        guard let winner = ranked.first else { return .uncertain }
        let second = ranked.dropFirst().first?.coverage ?? 0
        let lead = winner.coverage - second
        let leaders = ranked.filter { abs($0.coverage - winner.coverage) < 0.001 }

        // Prefer the current layout when it is among the top coverage tier.
        if let preferredID,
           let preferred = leaders.first(where: { $0.layoutID == preferredID }),
           preferred.coverage >= minimumCoverage {
            return .confident(preferred)
        }

        guard winner.coverage >= minimumCoverage else { return .uncertain }

        // Clear lead, sole layout, or several Latin (etc.) layouts that all fully explain the
        // letters — e.g. ABC + Spanish both score 1.0 on "ghbdtn". Requiring a lead here caused
        // a false "uncertain" with multiple QWERTY-family layouts enabled.
        if lead >= minimumLead || ranked.count == 1 || leaders.count > 1 {
            return .confident(winner)
        }
        return .uncertain
    }

    // MARK: Anchored cycle

    public struct CycleSession: Sendable, Equatable {
        public var original: String
        public var fromID: String
        public var targetIndex: Int
        public var lastOutput: String
        public var layoutIDs: [String]

        public init(original: String, fromID: String, targetIndex: Int, lastOutput: String, layoutIDs: [String]) {
            self.original = original
            self.fromID = fromID
            self.targetIndex = targetIndex
            self.lastOutput = lastOutput
            self.layoutIDs = layoutIDs
        }

        public var targetID: String { layoutIDs[targetIndex] }
    }

    public enum CycleStep: Sendable, Equatable {
        case output(text: String, targetID: String, session: CycleSession, isNewCycle: Bool)
        case failed(CycleFailure)
    }

    public enum CycleFailure: Sendable, Equatable {
        case needMoreLayouts
        case uncertainSource
        case emptyText
    }

    /// One anchored cycle step — same order as system “Select next input source”:
    /// `from` = current layout, first target = next enabled source (skip letter-noop / redundant Latin).
    /// Maps always `original → target`, never chained from `lastOutput`.
    /// Mixed script (e.g. «отдаёт AX»): chars of `from` go `from→target`; chars of `target`
    /// go `target→from` so Latin islands are not left unmapped (logs: lat:2ch:same).
    public static func cycle(
        selection: String,
        layoutIDs: [String],
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>],
        currentID: String?,
        session: CycleSession?,
        preferredTargetID: String? = nil
    ) -> CycleStep {
        let trimmedLetters = letters(in: selection)
        guard !trimmedLetters.isEmpty else { return .failed(.emptyText) }
        guard layoutIDs.count >= 2 else { return .failed(.needMoreLayouts) }

        let continuing: CycleSession?
        if let session,
           session.layoutIDs == layoutIDs,
           selection == session.lastOutput || selection == session.original {
            continuing = session
        } else {
            continuing = nil
        }

        let base: CycleSession
        let isNew: Bool
        if let continuing {
            base = continuing
            isNew = false
        } else {
            // System-style: text was typed in the layout that is on now — no charset detection.
            guard let currentID, let fromIndex = layoutIDs.firstIndex(of: currentID) else {
                return .failed(.uncertainSource)
            }
            base = CycleSession(
                original: selection,
                fromID: currentID,
                targetIndex: fromIndex,
                lastOutput: selection,
                layoutIDs: layoutIDs
            )
            isNew = true
        }

        var nextIndex = (base.targetIndex + 1) % layoutIDs.count
        // Caret span: the first correctly typed letter names the intended layout (macOS flipped
        // back after it) — start the orbit there instead of at "next after current".
        if isNew, let preferredTargetID, preferredTargetID != base.fromID,
           let preferredIndex = layoutIDs.firstIndex(of: preferredTargetID) {
            nextIndex = preferredIndex
        }
        var targetID = layoutIDs[nextIndex]
        var output = remap(
            original: base.original, fromID: base.fromID, toID: targetID, maps: maps, charsets: charsets
        )
        var hops = 0
        while hops < layoutIDs.count {
            let useful = isUsefulOrbitStep(
                targetID: targetID, fromID: base.fromID, original: base.original, output: output
            )
            let redundant = isRedundantWithPreferredLatin(
                targetID: targetID,
                output: output,
                fromID: base.fromID,
                original: base.original,
                layoutIDs: layoutIDs,
                maps: maps,
                charsets: charsets
            )
            if useful, !redundant { break }
            nextIndex = (nextIndex + 1) % layoutIDs.count
            targetID = layoutIDs[nextIndex]
            output = remap(
                original: base.original, fromID: base.fromID, toID: targetID, maps: maps, charsets: charsets
            )
            hops += 1
        }

        var next = base
        next.targetIndex = nextIndex
        next.lastOutput = output
        return .output(text: output, targetID: targetID, session: next, isNewCycle: isNew)
    }

    /// Identity return to `fromID` is always useful. Other targets must change the *letters*
    /// (ABC→Spanish-ISO often differs only in punctuation / dead keys — skip those).
    private static func isUsefulOrbitStep(
        targetID: String,
        fromID: String,
        original: String,
        output: String
    ) -> Bool {
        if targetID == fromID { return true }
        return letters(in: output) != letters(in: original)
    }

    /// Spanish/French/… often remap Cyrillic mistypes to the same Latin letters as ABC.
    /// Prefer `com.apple.keylayout.ABC` (or US) when the letter output matches.
    private static func isRedundantWithPreferredLatin(
        targetID: String,
        output: String,
        fromID: String,
        original: String,
        layoutIDs: [String],
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>]
    ) -> Bool {
        if targetID == fromID { return false }
        if isPreferredLatin(targetID) { return false }
        let outKey = letterKey(output)
        guard !outKey.isEmpty else { return false }
        // Only compare against a *different* home Latin than the mistype source.
        for preferred in layoutIDs
            where preferred != targetID && preferred != fromID && isPreferredLatin(preferred) {
            let alt = remap(
                original: original, fromID: fromID, toID: preferred, maps: maps, charsets: charsets
            )
            if letterKey(alt) == outKey { return true }
            // Home Latin remaps the mistype → skip Spanish/French neighbors even if one glyph differs.
            if isUsefulOrbitStep(
                targetID: preferred, fromID: fromID, original: original, output: alt
            ) {
                return true
            }
        }
        return false
    }

    private static func letterKey(_ text: String) -> String {
        String(letters(in: text)).lowercased()
    }

    private static func isPreferredLatin(_ id: String) -> Bool {
        id == "com.apple.keylayout.ABC"
            || id == "com.apple.keylayout.US"
            || id.hasPrefix("com.apple.keylayout.US")
    }

    /// Uniform mistype: `from→to`. Mixed script (layout flipped mid-phrase): also map
    /// characters that belong to `to`'s charset via `to→from`, so «AX» is not left behind
    /// when `from` is Russian and `to` is ABC.
    ///
    /// Characters both layouts can type (`[ ] "` exist in Apple Russian *and* ABC) are
    /// ambiguous: they follow the majority of unambiguous characters in their word (else the
    /// whole text). Receiver logs: `[jhjij]` with Russian current became `~орошо`` ` because
    /// `[`/`]` were read as Russian keys — expected `хорошоъ`.
    static func remap(
        original: String,
        fromID: String,
        toID: String,
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>] = [:]
    ) -> String {
        if toID == fromID { return original }
        let forward = maps[fromID]?[toID] ?? [:]
        let backward = maps[toID]?[fromID] ?? [:]
        if backward.isEmpty {
            return apply(original, map: forward)
        }
        let fromSet = charsets[fromID] ?? []
        let toSet = charsets[toID] ?? []
        // Fast path when every letter is explained by `from` — no island swap needed.
        if !fromSet.isEmpty, letters(in: original).allSatisfy({ fromSet.contains($0) }) {
            return apply(original, map: forward)
        }

        enum Origin { case from, to, ambiguous }
        func origin(_ ch: Character) -> Origin {
            let inFrom = fromSet.isEmpty ? forward[ch] != nil : fromSet.contains(ch)
            let inTo = toSet.isEmpty ? backward[ch] != nil : toSet.contains(ch)
            switch (inFrom, inTo) {
            case (true, false): return .from
            case (false, true): return .to
            default: return .ambiguous
            }
        }
        func majority(_ chars: some Sequence<Character>) -> Origin {
            var fromCount = 0
            var toCount = 0
            for ch in chars where !ch.isWhitespace {
                switch origin(ch) {
                case .from: fromCount += 1
                case .to: toCount += 1
                case .ambiguous: break
                }
            }
            if fromCount == 0, toCount == 0 { return .ambiguous }
            return toCount > fromCount ? .to : .from
        }
        let global = majority(original)
        func map(_ ch: Character, as origin: Origin) -> Character {
            switch origin {
            case .from: return forward[ch] ?? ch
            case .to: return backward[ch] ?? ch
            case .ambiguous:
                // Old behavior: the key on `from` wins, then the target island.
                if let out = forward[ch] { return out }
                if toSet.isEmpty || toSet.contains(ch), let out = backward[ch] { return out }
                return ch
            }
        }

        var result = ""
        var word: [Character] = []
        func flushWord() {
            guard !word.isEmpty else { return }
            var wordOrigin = majority(word)
            if wordOrigin == .ambiguous { wordOrigin = global }
            for ch in word {
                let own = origin(ch)
                result.append(map(ch, as: own == .ambiguous ? wordOrigin : own))
            }
            word.removeAll(keepingCapacity: true)
        }
        for ch in original {
            if ch.isWhitespace {
                flushWord()
                result.append(ch)
            } else {
                word.append(ch)
            }
        }
        flushWord()
        return result
    }

    // MARK: Caret span (no selection)

    /// Spelling oracle: is `word` a valid word in the language of `layoutID`? `nil` = unknown
    /// (no dictionary for that layout) — the dictionary-free rules apply then.
    public typealias WordValidator = (_ word: String, _ layoutID: String) -> Bool?

    /// What to convert when nothing is selected, from the text between line start and caret.
    public struct CaretSpan: Sendable, Equatable {
        /// The characters to select and convert.
        public let text: String
        /// Preferred first target: the layout of the correctly typed letter left of the span
        /// (macOS typed it, then flipped back), or the layout the dictionary converts into.
        public let boundaryLayoutID: String?
        /// Layout that typed the span (convert *from* it). The current layout when it types the
        /// last character, else detected from the text — after our own TIS switch the current
        /// layout is often the *target* (logs: current Russian, line «Пhbdtn vbh» → nothing).
        public let sourceLayoutID: String
        /// Text between the span and the caret, left as typed («ghbdtn vtldtl bp| леса»).
        public let tail: String

        public init(text: String, boundaryLayoutID: String?, sourceLayoutID: String, tail: String = "") {
            self.text = text
            self.boundaryLayoutID = boundaryLayoutID
            self.sourceLayoutID = sourceLayoutID
            self.tail = tail
        }
    }

    /// No selection. Rules, in order:
    /// 1. The run typed in the source layout starts **inside a word** right after a letter only
    ///    another layout types («Пhbdtn vbh») — macOS flipped back after that letter: convert the
    ///    whole run.
    /// 2. With a dictionary: convert the last group of words that are misspelled as typed but
    ///    spelled right after conversion (`ghbdtn vtldtl bp ktcf` → all; `use React ghbdtn` →
    ///    `ghbdtn`). When the trailing run is all correct («… bp леса»), look at the run before it.
    /// 3. The dictionary judged the words and none is mistyped: the user is toggling correct
    ///    text on purpose — convert the whole run (logs: a correct Russian line in a card
    ///    converted only «леса»).
    /// 4. No dictionary verdict: the run back to a correctly typed letter, or the last word.
    public static func caretSpan(
        prefix: String,
        currentID: String,
        layoutIDs: [String],
        charsets: [String: Set<Character>],
        maps: [String: [String: [Character: Character]]] = [:],
        isValidWord: WordValidator? = nil
    ) -> CaretSpan? {
        let chars = Array(prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        guard let lastChar = chars.last(where: { !$0.isWhitespace }) else { return nil }

        // Source = the layout that typed the trailing word: current when it can, else the
        // layout covering most of that word (tie → orbit order).
        var sourceID = currentID
        if charsets[currentID]?.contains(lastChar) != true {
            var wordStart = chars.count
            while wordStart > 0, chars[wordStart - 1].isWhitespace { wordStart -= 1 }
            let wordEnd = wordStart
            while wordStart > 0, !chars[wordStart - 1].isWhitespace { wordStart -= 1 }
            guard let best = bestLayout(
                for: chars[wordStart..<wordEnd], containing: lastChar, among: layoutIDs, charsets: charsets
            ) else { return nil }
            sourceID = best
        }
        guard let sourceSet = charsets[sourceID], !sourceSet.isEmpty else { return nil }

        let run = sourceRun(chars, end: chars.count, set: sourceSet)
        let boundary: String? = run.stop.flatMap { stop in
            var wordStart = stop
            while wordStart > 0, !chars[wordStart - 1].isWhitespace { wordStart -= 1 }
            let foreign = chars[wordStart...stop].filter { !sourceSet.contains($0) }
            return bestLayout(
                for: ArraySlice(foreign), containing: chars[stop],
                among: layoutIDs.filter { $0 != sourceID }, charsets: charsets
            )
        }
        let midWord = run.stop != nil && run.start < chars.count && !chars[run.start].isWhitespace

        func make(_ start: Int, _ end: Int, target: String?, source: String) -> CaretSpan? {
            var spanChars = Array(chars[start..<end])
            while let first = spanChars.first, first.isWhitespace { spanChars.removeFirst() }
            // Cap: drop whole leading words until it fits.
            while (String(spanChars) as NSString).length > maxConvertibleUTF16 {
                guard let space = spanChars.firstIndex(where: \.isWhitespace) else { return nil }
                spanChars = Array(spanChars[(space + 1)...].drop(while: \.isWhitespace))
            }
            let text = String(spanChars)
            let set = charsets[source] ?? []
            guard text.contains(where: { !$0.isWhitespace && set.contains($0) }) else { return nil }
            return CaretSpan(
                text: text, boundaryLayoutID: target, sourceLayoutID: source, tail: String(chars[end...])
            )
        }

        if midWord, run.stop != nil {
            return make(run.start, chars.count, target: boundary, source: sourceID)
        }

        var judgedAllCorrect = false
        if let isValidWord {
            let others = layoutIDs.filter { $0 != sourceID }
            let targets = boundary.map { preferred in [preferred] + others.filter { $0 != preferred } } ?? others
            let verdict = dictionaryGroup(
                chars, start: run.start, end: chars.count, source: sourceID, targets: targets,
                maps: maps, charsets: charsets, isValidWord: isValidWord
            )
            if let group = verdict.group {
                return make(group.start, group.end, target: group.target, source: sourceID)
            }
            judgedAllCorrect = verdict.judged
            // Trailing words are right as typed («… bp леса»): the mistake is the run before.
            if let stop = run.stop, let boundary, let boundarySet = charsets[boundary] {
                let previous = sourceRun(chars, end: stop + 1, set: boundarySet)
                let backTargets = [sourceID] + layoutIDs.filter { $0 != sourceID && $0 != boundary }
                if let group = dictionaryGroup(
                    chars, start: previous.start, end: stop + 1, source: boundary, targets: backTargets,
                    maps: maps, charsets: charsets, isValidWord: isValidWord
                ).group {
                    return make(group.start, group.end, target: group.target, source: boundary)
                }
            }
        }

        if run.stop != nil || judgedAllCorrect {
            return make(run.start, chars.count, target: boundary, source: sourceID)
        }
        // Last word only (no dictionary verdict to separate a correct prefix).
        var i = chars.count
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        return make(i, chars.count, target: nil, source: sourceID)
    }

    /// Walks left from `end` over whitespace and characters of `set`. `stop` = index of the
    /// first character outside `set` (nil at line start).
    private static func sourceRun(_ chars: [Character], end: Int, set: Set<Character>) -> (start: Int, stop: Int?) {
        var index = end
        while index > 0 {
            let ch = chars[index - 1]
            if ch.isWhitespace || set.contains(ch) {
                index -= 1
                continue
            }
            return (index, index - 1)
        }
        return (0, nil)
    }

    /// Layout (among `ids`) that types `ch` and covers most of `word`; tie → order of `ids`.
    private static func bestLayout(
        for word: ArraySlice<Character>,
        containing ch: Character,
        among ids: [String],
        charsets: [String: Set<Character>]
    ) -> String? {
        var best: (id: String, hits: Int)?
        for id in ids {
            guard let set = charsets[id], set.contains(ch) else { continue }
            let hits = word.filter { set.contains($0) }.count
            if best == nil || hits > best!.hits { best = (id, hits) }
        }
        return best?.id
    }

    /// Last group of mistyped words in `chars[start..<end]` typed on `source`.
    /// wrong = misspelled as typed, right after conversion; maybe = right both ways («bp»/«из»);
    /// junk = wrong both ways; keep = right as typed only, or no letters. The group ends at the
    /// last wrong word (+ following maybes), extends left over anything but keep, and never starts
    /// with junk/maybe. Target = the layout yielding the most wrong words.
    private static func dictionaryGroup(
        _ chars: [Character],
        start: Int,
        end: Int,
        source: String,
        targets: [String],
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>],
        isValidWord: WordValidator
    ) -> (group: (start: Int, end: Int, target: String)?, judged: Bool) {
        enum Kind { case wrong, maybe, junk, keep }
        var words: [(start: Int, end: Int)] = []
        var i = start
        while i < end {
            while i < end, chars[i].isWhitespace { i += 1 }
            let s = i
            while i < end, !chars[i].isWhitespace { i += 1 }
            if s < i { words.append((s, i)) }
        }
        guard !words.isEmpty else { return (nil, false) }

        var best: (target: String, kinds: [Kind], wrong: Int)?
        for target in targets {
            var kinds: [Kind] = []
            var wrongCount = 0
            var known = true
            for word in words {
                let text = String(chars[word.start..<word.end])
                guard text.contains(where: \.isLetter) || text.contains(where: { charsets[source]?.contains($0) == true && !$0.isPunctuation }) else {
                    kinds.append(.keep)
                    continue
                }
                guard let typedOK = isValidWord(text, source) else { known = false; break }
                let converted = remap(original: text, fromID: source, toID: target, maps: maps, charsets: charsets)
                guard let convertedOK = isValidWord(converted, target) else { known = false; break }
                let kind: Kind = switch (typedOK, convertedOK) {
                case (false, true): .wrong
                case (true, true): .maybe
                case (false, false): .junk
                case (true, false): .keep
                }
                if kind == .wrong { wrongCount += 1 }
                kinds.append(kind)
            }
            guard known else { continue }
            if best == nil || wrongCount > best!.wrong { best = (target, kinds, wrongCount) }
        }
        // `judged`: a dictionary answered for every word and found nothing mistyped.
        guard let best else { return (nil, false) }
        guard best.wrong > 0, let last = best.kinds.lastIndex(of: .wrong) else {
            let hasLetterWords = words.contains { chars[$0.start..<$0.end].contains(where: \.isLetter) }
            return (nil, hasLetterWords)
        }
        var first = last
        while first > 0, best.kinds[first - 1] != .keep { first -= 1 }
        while best.kinds[first] == .junk || best.kinds[first] == .maybe { first += 1 }
        var stop = last
        while stop + 1 < best.kinds.count, best.kinds[stop + 1] == .maybe { stop += 1 }
        return ((words[first].start, words[stop].end, best.target), true)
    }
}
