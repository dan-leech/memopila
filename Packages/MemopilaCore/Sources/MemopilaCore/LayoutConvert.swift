import Foundation

/// Keyboard-layout remapping: same physical keys, different characters (PLAN layout convert).
/// Pure — maps are supplied by the App (UCKeyTranslate) or by tests (fixtures).
public enum LayoutConverter: Sendable {
    /// Minimum letter count before best-fit is trusted.
    public static let minimumLetters = 2
    /// Winner must cover at least this fraction of letters.
    public static let minimumCoverage = 0.8
    /// Winner must beat the runner-up by at least this margin (absolute coverage).
    public static let minimumLead = 0.15

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

        if let preferredID,
           let preferred = ranked.first(where: { $0.layoutID == preferredID }),
           abs(preferred.coverage - winner.coverage) <= minimumLead,
           preferred.coverage >= minimumCoverage {
            return .confident(preferred)
        }

        guard winner.coverage >= minimumCoverage, lead >= minimumLead || ranked.count == 1 else {
            return .uncertain
        }
        return .confident(winner)
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

    /// One anchored cycle step. Maps always `original → target`, never chained from `lastOutput`.
    /// `maps[fromID][toID]` must hold the character map (or nil when from == to → identity).
    public static func cycle(
        selection: String,
        layoutIDs: [String],
        maps: [String: [String: [Character: Character]]],
        charsets: [String: Set<Character>],
        currentID: String?,
        session: CycleSession?
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
            switch bestFit(text: selection, layouts: charsets, preferredID: currentID) {
            case .uncertain:
                return .failed(.uncertainSource)
            case .confident(let fit):
                guard let fromIndex = layoutIDs.firstIndex(of: fit.layoutID) else {
                    return .failed(.uncertainSource)
                }
                base = CycleSession(
                    original: selection,
                    fromID: fit.layoutID,
                    targetIndex: fromIndex,
                    lastOutput: selection,
                    layoutIDs: layoutIDs
                )
                isNew = true
            }
        }

        let nextIndex = (base.targetIndex + 1) % layoutIDs.count
        let targetID = layoutIDs[nextIndex]
        let output: String
        if targetID == base.fromID {
            output = base.original
        } else if let map = maps[base.fromID]?[targetID] {
            output = apply(base.original, map: map)
        } else {
            output = base.original
        }

        var next = base
        next.targetIndex = nextIndex
        next.lastOutput = output
        return .output(text: output, targetID: targetID, session: next, isNewCycle: isNew)
    }
}

// MARK: - Test / fallback fixtures (US QWERTY ↔ Russian PC)

public enum LayoutConvertFixtures: Sendable {
    public static let usID = "fixture.us"
    public static let ruID = "fixture.ru"
    public static let uaID = "fixture.ua"

    /// US QWERTY ↔ Russian PC (ЙЦУКЕН), letters + common punctuation on letter keys.
    public static let usToRu: [Character: Character] = {
        let pairs: [(Character, Character)] = [
            ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"), ("y", "н"), ("u", "г"),
            ("i", "ш"), ("o", "щ"), ("p", "з"), ("[", "х"), ("]", "ъ"),
            ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"), ("h", "р"), ("j", "о"),
            ("k", "л"), ("l", "д"), (";", "ж"), ("'", "э"),
            ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"), ("m", "ь"),
            (",", "б"), (".", "ю"), ("`", "ё"),
            ("Q", "Й"), ("W", "Ц"), ("E", "У"), ("R", "К"), ("T", "Е"), ("Y", "Н"), ("U", "Г"),
            ("I", "Ш"), ("O", "Щ"), ("P", "З"), ("{", "Х"), ("}", "Ъ"),
            ("A", "Ф"), ("S", "Ы"), ("D", "В"), ("F", "А"), ("G", "П"), ("H", "Р"), ("J", "О"),
            ("K", "Л"), ("L", "Д"), (":", "Ж"), ("\"", "Э"),
            ("Z", "Я"), ("X", "Ч"), ("C", "С"), ("V", "М"), ("B", "И"), ("N", "Т"), ("M", "Ь"),
            ("<", "Б"), (">", "Ю"), ("~", "Ё"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs)
    }()

    public static let ruToUs: [Character: Character] = {
        Dictionary(uniqueKeysWithValues: usToRu.map { ($0.value, $0.key) })
    }()

    /// Simplified UA map for non-associativity tests: same as RU but `и`/`І` style swap on `b`/`B` → `и` stays;
    /// use `s`→`і` instead of `ы` to differ from RU.
    public static let usToUa: [Character: Character] = {
        var map = usToRu
        map["s"] = "і"
        map["S"] = "І"
        map["]"] = "ї"
        map["}"] = "Ї"
        map["'"] = "є"
        map["\""] = "Є"
        // Keep ` / ~ → ё like RU so reverse map stays injective for tests.
        return map
    }()

    public static let uaToUs: [Character: Character] = {
        var reverse: [Character: Character] = [:]
        for (us, ua) in usToUa {
            reverse[ua] = us
        }
        return reverse
    }()

    public static func charset(for map: [Character: Character]) -> Set<Character> {
        Set(map.keys).union(map.values)
    }

    public static var fixtureCharsets: [String: Set<Character>] {
        [
            usID: charset(for: usToRu).union(charset(for: usToUa)),
            ruID: Set(usToRu.values).union(Set(usToRu.keys)),
            uaID: Set(usToUa.values).union(Set(usToUa.keys)),
        ]
    }

    /// Charsets that correctly separate Latin vs Cyrillic for best-fit on mistyped Latin.
    public static var scriptCharsets: [String: Set<Character>] {
        let latin = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ[]{};':\",.<>/`~")
        let ru = Set(usToRu.values)
        let ua = Set(usToUa.values)
        return [usID: latin, ruID: ru, uaID: ua]
    }

    public static var fixtureMaps: [String: [String: [Character: Character]]] {
        [
            usID: [ruID: usToRu, uaID: usToUa],
            ruID: [usID: ruToUs],
            uaID: [usID: uaToUs],
        ]
    }
}
