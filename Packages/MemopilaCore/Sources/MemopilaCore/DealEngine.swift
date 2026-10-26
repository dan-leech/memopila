import Foundation

/// Deal mode for a paste stack (PLAN §3.11).
public enum StackDealMode: String, Sendable, Codable, CaseIterable, Equatable {
    case sequential
    case shuffleBag
    case shuffleRandom
}

/// Pure paste-stack deal math: UI order vs session deal queue (PLAN §3.11).
public enum DealEngine {
    public enum Session: Sendable, Equatable {
        case bag(BagSession)
        case random(RandomSession)

        public var stackID: UUID {
            switch self {
            case .bag(let s): s.stackID
            case .random(let s): s.stackID
            }
        }

        public var current: UUID {
            switch self {
            case .bag(let s): s.current
            case .random(let s): s.current
            }
        }

        public var dealMode: StackDealMode {
            switch self {
            case .bag(let s): s.dealMode
            case .random: .shuffleRandom
            }
        }

        /// Progress for bag modes: `k/n` with current included (P37). `nil` for random.
        public var progress: (k: Int, n: Int)? {
            switch self {
            case .bag(let s):
                let k = s.dealt.count + 1
                let n = s.dealt.count + s.remaining.count + 1
                return (k, n)
            case .random:
                return nil
            }
        }
    }

    public struct BagSession: Sendable, Equatable {
        public var stackID: UUID
        public var dealMode: StackDealMode
        public var loops: Bool
        public var current: UUID
        public var remaining: [UUID]
        public var dealt: [UUID]

        public init(
            stackID: UUID,
            dealMode: StackDealMode,
            loops: Bool,
            current: UUID,
            remaining: [UUID],
            dealt: [UUID]
        ) {
            self.stackID = stackID
            self.dealMode = dealMode
            self.loops = loops
            self.current = current
            self.remaining = remaining
            self.dealt = dealt
        }
    }

    public struct RandomSession: Sendable, Equatable {
        public var stackID: UUID
        public var current: UUID
        public var members: [UUID]

        public init(stackID: UUID, current: UUID, members: [UUID]) {
            self.stackID = stackID
            self.current = current
            self.members = members
        }
    }

    public enum Advance: Sendable, Equatable {
        case write(UUID, Session)
        case exhausted
    }

    /// Start a deal round from UI order. Returns `nil` when `uiOrder` is empty.
    public static func startRound(
        stackID: UUID,
        uiOrder: [UUID],
        dealMode: StackDealMode,
        loops: Bool,
        random: (Int) -> Int = { n in Int.random(in: 0..<n) }
    ) -> Session? {
        guard !uiOrder.isEmpty else { return nil }
        switch dealMode {
        case .sequential:
            return .bag(BagSession(
                stackID: stackID,
                dealMode: .sequential,
                loops: loops,
                current: uiOrder[0],
                remaining: Array(uiOrder.dropFirst()),
                dealt: []
            ))
        case .shuffleBag:
            let order = permute(uiOrder, random: random)
            return .bag(BagSession(
                stackID: stackID,
                dealMode: .shuffleBag,
                loops: loops,
                current: order[0],
                remaining: Array(order.dropFirst()),
                dealt: []
            ))
        case .shuffleRandom:
            let index = random(uiOrder.count)
            return .random(RandomSession(stackID: stackID, current: uiOrder[index], members: uiOrder))
        }
    }

    /// After the current item was pasted: next write target or exhausted.
    public static func afterPaste(
        _ session: Session,
        random: (Int) -> Int = { n in Int.random(in: 0..<n) }
    ) -> Advance {
        switch session {
        case .bag(var bag):
            bag.dealt.append(bag.current)
            if let next = bag.remaining.first {
                bag.remaining.removeFirst()
                bag.current = next
                return .write(next, .bag(bag))
            }
            if bag.loops {
                let uiOrder = bag.dealt
                guard let restarted = startRound(
                    stackID: bag.stackID,
                    uiOrder: uiOrder,
                    dealMode: bag.dealMode,
                    loops: true,
                    random: random
                ) else { return .exhausted }
                return .write(restarted.current, restarted)
            }
            return .exhausted

        case .random(let rand):
            guard !rand.members.isEmpty else { return .exhausted }
            let index = random(rand.members.count)
            let next = rand.members[index]
            return .write(next, .random(RandomSession(stackID: rand.stackID, current: next, members: rand.members)))
        }
    }

    /// Soft-apply Deal/Loop while armed: keep clipboard `current`; never closes the panel.
    /// Same mode → only flip `loops` (preserve dealt/remaining). Mode change → rebuild after current.
    public static func retarget(
        _ session: Session,
        uiOrder: [UUID],
        dealMode: StackDealMode,
        loops: Bool,
        random: (Int) -> Int = { n in Int.random(in: 0..<n) }
    ) -> Session? {
        guard !uiOrder.isEmpty else { return nil }
        // Loop-only: keep progress.
        if dealMode == session.dealMode {
            switch session {
            case .bag(var bag):
                bag.loops = loops
                return .bag(bag)
            case .random(let rand):
                return .random(RandomSession(stackID: rand.stackID, current: rand.current, members: uiOrder))
            }
        }
        let current = uiOrder.contains(session.current) ? session.current : uiOrder[0]
        switch dealMode {
        case .sequential:
            let idx = uiOrder.firstIndex(of: current) ?? 0
            return .bag(BagSession(
                stackID: session.stackID,
                dealMode: .sequential,
                loops: loops,
                current: current,
                remaining: Array(uiOrder.suffix(from: idx + 1)),
                dealt: Array(uiOrder.prefix(idx))
            ))
        case .shuffleBag:
            let rest = uiOrder.filter { $0 != current }
            let shuffled = permute(rest, random: random)
            return .bag(BagSession(
                stackID: session.stackID,
                dealMode: .shuffleBag,
                loops: loops,
                current: current,
                remaining: shuffled,
                dealt: []
            ))
        case .shuffleRandom:
            return .random(RandomSession(stackID: session.stackID, current: current, members: uiOrder))
        }
    }

    /// Rebuild after membership/order change without blind reshuffle (P24).
    public static func rebuild(
        _ session: Session,
        uiOrder: [UUID],
        random: (Int) -> Int = { n in Int.random(in: 0..<n) }
    ) -> Session? {
        guard !uiOrder.isEmpty else { return nil }
        let uiSet = Set(uiOrder)

        switch session {
        case .bag(var bag):
            bag.dealt = bag.dealt.filter { uiSet.contains($0) }
            let dealtSet = Set(bag.dealt)

            if bag.dealMode == .sequential {
                // Remaining follows current UI order among not-yet-dealt (P24).
                if uiSet.contains(bag.current) {
                    bag.remaining = uiOrder.filter { $0 != bag.current && !dealtSet.contains($0) }
                    return .bag(bag)
                }
                bag.remaining = uiOrder.filter { !dealtSet.contains($0) }
            } else {
                // Shuffle bag: keep remaining set; append adds; do not reshuffle.
                bag.remaining = bag.remaining.filter { uiSet.contains($0) }
                let known = dealtSet.union(bag.remaining).union(uiSet.contains(bag.current) ? [bag.current] : [])
                bag.remaining.append(contentsOf: uiOrder.filter { !known.contains($0) })
                if uiSet.contains(bag.current) {
                    return .bag(bag)
                }
            }

            if let next = bag.remaining.first {
                bag.remaining.removeFirst()
                bag.current = next
                return .bag(bag)
            }
            if bag.loops {
                return startRound(
                    stackID: bag.stackID,
                    uiOrder: uiOrder,
                    dealMode: bag.dealMode,
                    loops: true,
                    random: random
                )
            }
            return nil

        case .random(let rand):
            if uiSet.contains(rand.current) {
                return .random(RandomSession(stackID: rand.stackID, current: rand.current, members: uiOrder))
            }
            let index = random(uiOrder.count)
            return .random(RandomSession(stackID: rand.stackID, current: uiOrder[index], members: uiOrder))
        }
    }

    private static func permute(_ order: [UUID], random: (Int) -> Int) -> [UUID] {
        var result = order
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = random(i + 1)
            result.swapAt(i, j)
        }
        return result
    }
}
