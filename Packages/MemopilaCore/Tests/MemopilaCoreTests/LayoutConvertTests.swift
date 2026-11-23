import Foundation
import Testing
@testable import MemopilaCore

@Suite("Layout convert")
struct LayoutConvertTests {
    private let us = LayoutConvertFixtures.usID
    private let ru = LayoutConvertFixtures.ruID
    private let ua = LayoutConvertFixtures.uaID
    private let layouts = [LayoutConvertFixtures.usID, LayoutConvertFixtures.ruID, LayoutConvertFixtures.uaID]

    @Test func applyMapsGhbdtnToPrivet() {
        #expect(LayoutConverter.apply("ghbdtn", map: LayoutConvertFixtures.usToRu) == "привет")
        #expect(LayoutConverter.apply("Привет", map: LayoutConvertFixtures.ruToUs) == "Ghbdtn")
    }

    @Test func applyLeavesUnmappedAndDigits() {
        #expect(LayoutConverter.apply("hi 42 😀", map: LayoutConvertFixtures.usToRu) == "рш 42 😀")
    }

    @Test func withoutSessionCyrillicBestFitIsAmbiguousBetweenRuAndUa() {
        // After EN→RU, letters are Cyrillic; RU and UA charsets both score high → uncertain / wrong from.
        let cyrillic = LayoutConverter.apply("hello", map: LayoutConvertFixtures.usToRu)
        let result = LayoutConverter.bestFit(
            text: cyrillic,
            layouts: LayoutConvertFixtures.scriptCharsets,
            preferredID: nil
        )
        if case .confident(let fit) = result {
            // Even a confident pick may not be US — continuing without an anchor risks the wrong orbit.
            #expect(fit.layoutID != us)
        }
    }

    @Test func bestFitPrefersLatinForMistype() {
        let result = LayoutConverter.bestFit(
            text: "ghbdtn",
            layouts: LayoutConvertFixtures.scriptCharsets,
            preferredID: us
        )
        #expect(result == .confident(.init(layoutID: us, coverage: 1)))
    }

    @Test func bestFitRejectsShortText() {
        #expect(LayoutConverter.bestFit(text: "a", layouts: LayoutConvertFixtures.scriptCharsets, preferredID: nil) == .uncertain)
    }

    @Test func anchoredCycleSecondStepUsesOriginalNotChained() {
        let maps = LayoutConvertFixtures.fixtureMaps
        let charsets = LayoutConvertFixtures.scriptCharsets

        let step1 = LayoutConverter.cycle(
            selection: "hello",
            layoutIDs: layouts,
            maps: maps,
            charsets: charsets,
            currentID: us,
            session: nil
        )
        guard case .output(let text1, let target1, let session1, let isNew1) = step1 else {
            Issue.record("expected first output, got \(step1)")
            return
        }
        #expect(isNew1)
        #expect(target1 == ru)
        #expect(text1 == LayoutConverter.apply("hello", map: LayoutConvertFixtures.usToRu))

        let step2 = LayoutConverter.cycle(
            selection: text1,
            layoutIDs: layouts,
            maps: maps,
            charsets: charsets,
            currentID: ru,
            session: session1
        )
        guard case .output(let text2, let target2, let session2, _) = step2 else {
            Issue.record("expected second output, got \(step2)")
            return
        }
        #expect(target2 == ua)
        #expect(text2 == LayoutConverter.apply("hello", map: LayoutConvertFixtures.usToUa))
        #expect(session2.original == "hello")
        #expect(session2.fromID == us)
    }

    @Test func fullCircleRestoresOriginal() {
        let maps = LayoutConvertFixtures.fixtureMaps
        let charsets = LayoutConvertFixtures.scriptCharsets
        var session: LayoutConverter.CycleSession?
        var selection = "ghbdtn"
        var lastTarget = ""

        for _ in 0..<layouts.count {
            let step = LayoutConverter.cycle(
                selection: selection,
                layoutIDs: layouts,
                maps: maps,
                charsets: charsets,
                currentID: lastTarget.isEmpty ? us : lastTarget,
                session: session
            )
            guard case .output(let text, let target, let next, _) = step else {
                Issue.record("cycle failed: \(step)")
                return
            }
            selection = text
            session = next
            lastTarget = target
        }
        #expect(selection == "ghbdtn")
        #expect(lastTarget == us)
    }

    @Test func newSessionWhenSelectionUnrelated() {
        let maps = LayoutConvertFixtures.fixtureMaps
        let charsets = LayoutConvertFixtures.scriptCharsets
        let first = LayoutConverter.cycle(
            selection: "ghbdtn",
            layoutIDs: layouts,
            maps: maps,
            charsets: charsets,
            currentID: us,
            session: nil
        )
        guard case .output(_, _, let session, _) = first else { return }

        let other = LayoutConverter.cycle(
            selection: "qwerty",
            layoutIDs: layouts,
            maps: maps,
            charsets: charsets,
            currentID: us,
            session: session
        )
        guard case .output(_, _, let newSession, let isNew) = other else {
            Issue.record("expected new cycle, got \(other)")
            return
        }
        #expect(isNew)
        #expect(newSession.original == "qwerty")
    }
}
