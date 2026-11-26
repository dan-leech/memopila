import Foundation
import Testing
@testable import MemopilaCore

private typealias F = LayoutConvertFixtures
private let us = F.usID
private let ru = F.ruID
private let ua = F.uaID

private extension LayoutConverter.CycleStep {
    var output: (text: String, targetID: String, session: LayoutConverter.CycleSession, isNewCycle: Bool)? {
        guard case .output(let text, let targetID, let session, let isNewCycle) = self else { return nil }
        return (text, targetID, session, isNewCycle)
    }
}

/// One cycle step over the fixture layouts (US · Russian · Ukrainian-like, in that order).
private func cycle(
    _ selection: String,
    current: String?,
    session: LayoutConverter.CycleSession? = nil,
    layouts: [String] = [us, ru, ua],
    maps: [String: [String: [Character: Character]]] = F.maps,
    charsets: [String: Set<Character>] = F.scriptCharsets,
    preferredTarget: String? = nil
) -> LayoutConverter.CycleStep {
    LayoutConverter.cycle(
        selection: selection, layoutIDs: layouts, maps: maps, charsets: charsets,
        currentID: current, session: session, preferredTargetID: preferredTarget
    )
}

@Suite("Layout convert")
struct LayoutConvertTests {
    // MARK: - Remap

    @Suite("Remap")
    struct Remap {
        @Test func mapsAMistypedWordBothWays() {
            #expect(LayoutConverter.apply("ghbdtn", map: F.usToRu) == "привет")
            #expect(LayoutConverter.apply("Привет", map: F.ruToUs) == "Ghbdtn")
        }

        @Test func leavesDigitsAndUnmappedCharacters() {
            #expect(LayoutConverter.apply("hi 42 😀", map: F.usToRu) == "рш 42 😀")
        }

        @Test func convertibleLengthCapIsInclusive() {
            #expect(LayoutConverter.isConvertibleLength("ghbdtn"))
            #expect(LayoutConverter.isConvertibleLength(String(repeating: "a", count: LayoutConverter.maxConvertibleUTF16)))
            #expect(!LayoutConverter.isConvertibleLength(String(repeating: "a", count: LayoutConverter.maxConvertibleUTF16 + 1)))
        }

        @Test func mixedScriptRemapsTheLatinIslandToo() throws {
            // «отдаёт AX»: Cyrillic goes Russian→ABC and the Latin island ABC→Russian — it is not
            // left behind unmapped.
            let maps: [String: [String: [Character: Character]]] = [
                F.russian: [F.abc: F.ruToUs],
                F.abc: [F.russian: F.usToRu],
            ]
            let selection = LayoutConverter.apply("otdaet", map: F.usToRu) + " AX"
            let step = try #require(cycle(
                selection, current: F.russian, layouts: [F.russian, F.abc], maps: maps,
                charsets: [F.abc: F.latin, F.russian: F.cyrillic]
            ).output)
            #expect(step.targetID == F.abc)
            #expect(step.text == "otdaet " + LayoutConverter.apply("AX", map: F.usToRu))
        }

        @Test func failsWithoutLettersOrASecondLayout() {
            #expect(cycle("123 !", current: us) == .failed(.emptyText))
            #expect(cycle("ghbdtn", current: us, layouts: [us]) == .failed(.needMoreLayouts))
        }
    }

    // MARK: - Source detection

    @Suite("Source detection")
    struct SourceDetection {
        @Test func prefersLatinForALatinMistype() {
            #expect(LayoutConverter.bestFit(text: "ghbdtn", layouts: F.scriptCharsets, preferredID: us)
                == .confident(.init(layoutID: us, coverage: 1)))
        }

        @Test func rejectsTooFewLetters() {
            #expect(LayoutConverter.bestFit(text: "a", layouts: F.scriptCharsets, preferredID: nil) == .uncertain)
        }

        @Test func acceptsTiedLatinLayouts() throws {
            // ABC and Spanish both cover a Latin mistype; demanding a coverage lead rejected real setups.
            let result = LayoutConverter.bestFit(text: "ghbdtn", layouts: F.realCharsets, preferredID: F.russian)
            guard case .confident(let fit) = result else {
                Issue.record("expected a confident fit among tied Latin layouts, got \(result)")
                return
            }
            #expect([F.abc, F.spanish].contains(fit.layoutID))
            #expect(fit.coverage == 1)
        }

        @Test func cyrillicIsNeverReadAsLatin() {
            // Russian and Ukrainian-like both cover Cyrillic; whichever wins, it is not US.
            let cyrillic = LayoutConverter.apply("hello", map: F.usToRu)
            if case .confident(let fit) = LayoutConverter.bestFit(text: cyrillic, layouts: F.scriptCharsets, preferredID: nil) {
                #expect(fit.layoutID != us)
            }
        }
    }

    // MARK: - Orbit

    @Suite("Orbit")
    struct Orbit {
        @Test func secondStepMapsTheOriginalNotTheLastOutput() throws {
            let first = try #require(cycle("hello", current: us).output)
            #expect(first.isNewCycle)
            #expect(first.targetID == ru)
            #expect(first.text == LayoutConverter.apply("hello", map: F.usToRu))

            let second = try #require(cycle(first.text, current: ru, session: first.session).output)
            #expect(second.targetID == ua)
            #expect(second.text == LayoutConverter.apply("hello", map: F.usToUa))
            #expect(second.session.original == "hello")
            #expect(second.session.fromID == us)
        }

        @Test func fullCircleRestoresTheOriginal() throws {
            var session: LayoutConverter.CycleSession?
            var text = "ghbdtn"
            var current = us
            for _ in 0..<3 {
                let step = try #require(cycle(text, current: current, session: session).output)
                text = step.text
                current = step.targetID
                session = step.session
            }
            #expect(text == "ghbdtn")
            #expect(current == us)
        }

        @Test func unrelatedSelectionStartsANewOrbit() throws {
            let first = try #require(cycle("ghbdtn", current: us).output)
            let other = try #require(cycle("qwerty", current: us, session: first.session).output)
            #expect(other.isNewCycle)
            #expect(other.session.original == "qwerty")
        }

        @Test func skipsALatinLayoutThatTypesTheSameLetters() throws {
            // From Russian (current = source) the next source is Spanish, but its letters equal
            // ABC's — the first useful target is ABC, like the system switcher.
            let maps: [String: [String: [Character: Character]]] = [
                F.russian: [F.abc: F.ruToUs, F.spanish: F.ruToUs],
            ]
            let step = try #require(cycle(
                LayoutConverter.apply("ghbdtn", map: F.usToRu), current: F.russian,
                layouts: [F.russian, F.spanish, F.abc], maps: maps, charsets: F.realCharsets
            ).output)
            #expect(step.session.fromID == F.russian)
            #expect(step.targetID == F.abc)
            #expect(step.text == "ghbdtn")
        }

        @Test func skipsALatinVariantThatDiffersOnlyInPunctuation() throws {
            // Spanish sits between ABC and Russian (real Input Sources order); its map changes
            // only punctuation, so it is a no-op for the letters and the orbit skips it.
            var nearIdentity = Dictionary(uniqueKeysWithValues: "ghbdtn".map { ($0, $0) })
            nearIdentity["."] = ","
            let maps: [String: [String: [Character: Character]]] = [
                F.abc: [F.spanish: nearIdentity, F.russian: F.usToRu],
            ]
            let layouts = [F.abc, F.spanish, F.russian]
            let first = try #require(cycle(
                "ghbdtn", current: F.abc, layouts: layouts, maps: maps, charsets: F.realCharsets
            ).output)
            #expect(first.targetID == F.russian)
            #expect(first.text == "привет")

            let second = try #require(cycle(
                first.text, current: F.russian, session: first.session, layouts: layouts, maps: maps,
                charsets: F.realCharsets
            ).output)
            #expect(second.targetID == F.abc)
            #expect(second.text == "ghbdtn")
        }
    }

    // MARK: - Ambiguous punctuation

    /// Apple Russian also types `[ ] "` (on other keys), so they are in both charsets. Without the
    /// word-majority rule `[jhjij]` with Russian current came out as `~орошо``.
    @Suite("Ambiguous punctuation")
    struct AmbiguousPunctuation {
        private let fixture: (maps: [String: [String: [Character: Character]]], charsets: [String: Set<Character>]) = {
            var ruToUs = F.ruToUs
            ruToUs["["] = "~"
            ruToUs["]"] = "`"
            ruToUs["\""] = "@"
            var usToRu = F.usToRu
            usToRu["@"] = "\""
            let latin = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ[]{};':\",.<>/`~@ ")
            let cyrillic = Set(F.usToRu.values).union(Set("[]\" "))
            return ([us: [ru: usToRu], ru: [us: ruToUs]], [us: latin, ru: cyrillic])
        }()

        private func convert(_ text: String, current: String) throws -> String {
            try #require(cycle(
                text, current: current, layouts: [us, ru], maps: fixture.maps, charsets: fixture.charsets
            ).output).text
        }

        @Test func bracketsFollowTheLatinMajority() throws {
            #expect(try convert("[jhjij]", current: ru) == "хорошоъ")
        }

        @Test func quotesFollowTheWordMajority() throws {
            #expect(try convert("\"[j\"", current: ru) == "ЭхоЭ")
        }

        @Test func uniformMistypeIsUnaffected() throws {
            #expect(try convert("[jhjij", current: us) == "хорошо")
        }
    }

    // MARK: - Caret span (no selection)

    /// “Everything back to the first correctly typed letter” — macOS flipped the layout back
    /// after the first letter of a word.
    @Suite("Caret span")
    struct CaretSpanRules {
        private let charsets: [String: Set<Character>] = {
            var sets = F.scriptCharsets
            sets[us]?.formUnion(" 0123456789")
            sets[ru]?.formUnion(" 0123456789")
            return sets
        }()

        private func span(_ prefix: String, current: String, layouts: [String] = [us, ru]) -> LayoutConverter.CaretSpan? {
            LayoutConverter.caretSpan(prefix: prefix, currentID: current, layoutIDs: layouts, charsets: charsets)
        }

        @Test func stopsAtTheFirstCorrectLetter() {
            #expect(span("Пhbdtn vbh", current: us) == .init(text: "hbdtn vbh", boundaryLayoutID: ru, sourceLayoutID: us))
        }

        @Test func skipsTheSpaceAfterACorrectWord() {
            #expect(span("Привет vbh", current: us) == .init(text: "vbh", boundaryLayoutID: ru, sourceLayoutID: us))
        }

        @Test func keepsPunctuationTypedOnLetterKeys() {
            let found = span("Я k.,k. nt,z", current: us)
            #expect(found?.text == "k.,k. nt,z")
            #expect(found?.boundaryLayoutID == ru)
        }

        @Test func worksFromRussianToLatin() {
            #expect(span("Hуддщ", current: ru) == .init(text: "уддщ", boundaryLayoutID: us, sourceLayoutID: ru))
        }

        @Test func includesATrailingSpace() {
            #expect(span("Пhbdtn ", current: us) == .init(text: "hbdtn ", boundaryLayoutID: ru, sourceLayoutID: us))
        }

        @Test func withoutABoundaryTakesTheLastWord() {
            #expect(span("const s = ghbdtn", current: us) == .init(text: "ghbdtn", boundaryLayoutID: nil, sourceLayoutID: us))
        }

        @Test func correctTextInTheOtherLayoutTakesTheLastWord() {
            // Line fully in Russian, current ABC: the source is Russian, no boundary.
            #expect(span("Привет мир", current: us) == .init(text: "мир", boundaryLayoutID: nil, sourceLayoutID: ru))
        }

        @Test func onlyTheLastLineCounts() {
            #expect(span("Пhbdtn vbh\nПривет vbh", current: us)?.text == "vbh")
        }

        @Test func blankLineHasNoSpan() {
            #expect(span("   ", current: us) == nil)
            #expect(span("", current: us) == nil)
            #expect(span("ghbdtn\n", current: us) == nil)
        }

        @Test func dropsLeadingWordsToFitTheCap() throws {
            let long = "П" + Array(repeating: "ghbdtn", count: 30).joined(separator: " ")
            let text = try #require(span(long, current: us)).text
            #expect((text as NSString).length <= LayoutConverter.maxConvertibleUTF16)
            #expect(text.hasPrefix("ghbdtn"))
            #expect(text.hasSuffix("ghbdtn"))
        }

        @Test func detectsTheSourceWhenCurrentIsAlreadyTheTarget() throws {
            // Our own switch had made Russian current; «Пhbdtn vbh» still converts.
            let found = try #require(span("Пhbdtn vbh", current: ru))
            #expect(found == .init(text: "hbdtn vbh", boundaryLayoutID: ru, sourceLayoutID: us))
            let step = try #require(cycle(
                found.text, current: found.sourceLayoutID, layouts: [us, ru], charsets: charsets,
                preferredTarget: found.boundaryLayoutID
            ).output)
            #expect(step.targetID == ru)
            #expect(step.text == "ривет мир")
        }

        @Test func boundaryLayoutIsTheFirstTargetAmongThree() throws {
            // Orbit us → ua → ru, but the boundary word is Russian («ы» exists only there), so the
            // first target is ru, not ua.
            var sets = charsets
            sets[ua]?.formUnion(" ")
            let found = try #require(LayoutConverter.caretSpan(
                prefix: "Мыhbdtn vbh", currentID: us, layoutIDs: [us, ua, ru], charsets: sets
            ))
            #expect(found.text == "hbdtn vbh")
            #expect(found.boundaryLayoutID == ru)
            let step = try #require(cycle(
                found.text, current: us, layouts: [us, ua, ru], charsets: sets, preferredTarget: found.boundaryLayoutID
            ).output)
            #expect(step.targetID == ru)
            #expect(step.text == "ривет мир")
        }
    }

    // MARK: - Caret span with a dictionary (NSSpellChecker in the app)

    @Suite("Caret span with a dictionary")
    struct CaretSpanDictionary {
        private let charsets: [String: Set<Character>] = {
            var sets = F.scriptCharsets
            sets[us]?.formUnion(" 0123456789")
            sets[ru]?.formUnion(" 0123456789")
            return sets
        }()

        private let dictionary: LayoutConverter.WordValidator = { word, layout in
            let english: Set<String> = ["use", "react", "const", "s", "bp", "hello", "world", "ok", "fix"]
            let russian: Set<String> = ["привет", "медвед", "из", "леса", "мир"]
            switch layout {
            case F.usID: return english.contains(word.lowercased())
            case F.ruID: return russian.contains(word.lowercased())
            default: return nil
            }
        }

        private func span(
            _ prefix: String,
            current: String,
            dictionary: LayoutConverter.WordValidator? = nil
        ) -> LayoutConverter.CaretSpan? {
            LayoutConverter.caretSpan(
                prefix: prefix, currentID: current, layoutIDs: [us, ru], charsets: charsets,
                maps: F.maps, isValidWord: dictionary ?? self.dictionary
            )
        }

        @Test func convertsAWholeMistypedLine() {
            // Without the dictionary only «ktcf» (the last word) converted.
            #expect(span("ghbdtn vtldtl bp ktcf", current: us)
                == .init(text: "ghbdtn vtldtl bp ktcf", boundaryLayoutID: ru, sourceLayoutID: us))
        }

        @Test func keepsACorrectEnglishPrefix() {
            #expect(span("use React ghbdtn", current: us)?.text == "ghbdtn")
            #expect(span("const s = ghbdtn", current: us)?.text == "ghbdtn")
        }

        @Test func fixesTheRunBeforeACorrectTrailingWord() {
            // The user switched layout, typed «леса» correctly, then pressed convert at the end.
            for current in [us, ru] {
                #expect(span("ghbdtn vtldtl bp леса", current: current)
                    == .init(text: "ghbdtn vtldtl bp", boundaryLayoutID: ru, sourceLayoutID: us, tail: " леса"))
            }
        }

        @Test func keepsTheMacOSFlipRule() {
            #expect(span("Пhbdtn vbh", current: us) == .init(text: "hbdtn vbh", boundaryLayoutID: ru, sourceLayoutID: us))
            #expect(span("Привет vbh", current: us)?.text == "vbh")
        }

        @Test func maybeWordsJoinOnlyInsideOrAfterTheGroup() {
            // «bp» is valid both as typed (English) and converted («из»).
            #expect(span("ghbdtn bp", current: us)?.text == "ghbdtn bp")
            #expect(span("ghbdtn bp hello", current: us)
                == .init(text: "ghbdtn bp", boundaryLayoutID: ru, sourceLayoutID: us, tail: " hello"))
        }

        @Test func allCorrectConvertsTheWholeRun() {
            // Toggling correct text on purpose: the whole line, not only «леса».
            #expect(span("привет медвед из леса", current: ru)
                == .init(text: "привет медвед из леса", boundaryLayoutID: nil, sourceLayoutID: ru))
            #expect(span("hello world", current: us)?.text == "hello world")
            // A correct word after a letter of the other layout: back to that letter only.
            #expect(span("Привет hello", current: us)?.text == "hello")
        }

        @Test func noVerdictFallsBackToTheLastWord() {
            #expect(span("ghbdtn vbh", current: us, dictionary: { _, _ in nil })?.text == "vbh")
        }
    }
}
