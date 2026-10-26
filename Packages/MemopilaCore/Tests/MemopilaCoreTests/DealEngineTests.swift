import Foundation
import Testing
@testable import MemopilaCore

@Suite struct DealEngineTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let stack = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    @Test func startRound_empty_returnsNil() {
        #expect(DealEngine.startRound(stackID: stack, uiOrder: [], dealMode: .sequential, loops: false) == nil)
    }

    @Test func sequential_n1_withoutLoop_exhaustsAfterOnePaste() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a], dealMode: .sequential, loops: false
        )!
        #expect(session.current == a)
        #expect(session.progress?.k == 1 && session.progress?.n == 1)
        #expect(DealEngine.afterPaste(session) == .exhausted)
    }

    @Test func sequential_n1_withLoop_rewritesSame() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a], dealMode: .sequential, loops: true
        )!
        switch DealEngine.afterPaste(session) {
        case .write(let id, let next):
            #expect(id == a)
            #expect(next.progress?.k == 1 && next.progress?.n == 1)
        case .exhausted:
            Issue.record("loop must restart n=1")
        }
    }

    @Test func rebuild_emptyOrder_returnsNil() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a], dealMode: .sequential, loops: false
        )!
        #expect(DealEngine.rebuild(session, uiOrder: []) == nil)
    }

    @Test func sequential_withoutLoop_exhausts() {
        var session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b], dealMode: .sequential, loops: false
        )!
        #expect(session.current == a)
        #expect(session.progress?.k == 1 && session.progress?.n == 2)

        switch DealEngine.afterPaste(session) {
        case .write(let id, let next):
            #expect(id == b)
            session = next
            #expect(session.progress?.k == 2 && session.progress?.n == 2)
        case .exhausted:
            Issue.record("expected write")
        }

        #expect(DealEngine.afterPaste(session) == .exhausted)
    }

    @Test func sequential_withLoop_restarts() {
        var session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b], dealMode: .sequential, loops: true
        )!
        if case .write(_, let s1) = DealEngine.afterPaste(session) { session = s1 }
        switch DealEngine.afterPaste(session) {
        case .write(let id, let next):
            #expect(id == a)
            #expect(next.progress?.k == 1)
        case .exhausted:
            Issue.record("expected loop restart")
        }
    }

    @Test func shuffleBag_visitsEachOnce() {
        let identity: (Int) -> Int = { _ in 0 } // Fisher–Yates with 0 → reverse-ish but always valid
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b, c], dealMode: .shuffleBag, loops: false, random: identity
        )!
        var seen = [session.current]
        var s = session
        while case .write(let id, let next) = DealEngine.afterPaste(s, random: identity) {
            seen.append(id)
            s = next
        }
        #expect(Set(seen) == Set([a, b, c]))
        #expect(seen.count == 3)
        #expect(DealEngine.afterPaste(s, random: identity) == .exhausted)
    }

    @Test func shuffleRandom_neverExhausts_withMembers() {
        let pick0: (Int) -> Int = { _ in 0 }
        var session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b], dealMode: .shuffleRandom, loops: false, random: pick0
        )!
        for _ in 0..<5 {
            switch DealEngine.afterPaste(session, random: pick0) {
            case .write(_, let next):
                session = next
            case .exhausted:
                Issue.record("random must not exhaust while n≥1")
            }
        }
        #expect(session.progress == nil)
    }

    @Test func rebuild_dropsRemoved_keepsCurrent() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b, c], dealMode: .sequential, loops: false
        )!
        // After writing a, paste → b current, remaining [c]
        guard case .write(_, let mid) = DealEngine.afterPaste(session) else {
            Issue.record("expected write"); return
        }
        let rebuilt = DealEngine.rebuild(mid, uiOrder: [a, b])!
        #expect(rebuilt.current == b)
        #expect(rebuilt.progress?.n == 2)
    }

    @Test func rebuild_currentGone_takesNext() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b, c], dealMode: .sequential, loops: false
        )!
        let rebuilt = DealEngine.rebuild(session, uiOrder: [b, c])!
        #expect(rebuilt.current == b)
    }

    @Test func rebuild_sequential_followsNewUIOrder() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b, c], dealMode: .sequential, loops: false
        )!
        // current a; reorder UI to a, c, b → remaining should be [c, b]
        let rebuilt = DealEngine.rebuild(session, uiOrder: [a, c, b])!
        #expect(rebuilt.current == a)
        guard case .bag(let bag) = rebuilt else {
            Issue.record("expected bag"); return
        }
        #expect(bag.remaining == [c, b])
    }

    @Test func retarget_keepsCurrent_updatesLoopsAndRemaining() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b, c], dealMode: .sequential, loops: false
        )!
        guard case .write(_, let mid) = DealEngine.afterPaste(session) else {
            Issue.record("expected write"); return
        }
        #expect(mid.current == b)
        let next = DealEngine.retarget(
            mid, uiOrder: [a, b, c], dealMode: .sequential, loops: true
        )!
        #expect(next.current == b)
        guard case .bag(let bag) = next else {
            Issue.record("expected bag"); return
        }
        #expect(bag.loops == true)
        #expect(bag.remaining == [c])
        #expect(bag.dealt == [a])
    }

    @Test func retarget_toRandom_keepsCurrent() {
        let session = DealEngine.startRound(
            stackID: stack, uiOrder: [a, b, c], dealMode: .sequential, loops: false
        )!
        let next = DealEngine.retarget(
            session, uiOrder: [a, b, c], dealMode: .shuffleRandom, loops: false
        )!
        #expect(next.current == a)
        #expect(next.dealMode == .shuffleRandom)
        #expect(next.progress == nil)
    }
}
