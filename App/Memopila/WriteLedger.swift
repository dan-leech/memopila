import Foundation

/// Counts store writes that started on the main actor and have not finished yet, so ⌘Q can wait
/// for them. A fire-and-forget `Task { await store.x() }` is otherwise killed at exit before it
/// reaches the store (favorite, rename, membership, a capture still being saved).
@MainActor
final class WriteLedger {
    private(set) var inFlight = 0

    /// Call synchronously on the main actor, before the write's first suspension, so ⌘Q sees it.
    func begin() { inFlight += 1 }

    func end() {
        inFlight = max(0, inFlight - 1)
    }

    /// Drop-in for `Task { … }` around store writes.
    func run(@_implicitSelfCapture _ body: @escaping @MainActor () async -> Void) {
        begin()
        Task {
            await body()
            end()
        }
    }

    /// Waits until no tracked write is running. Bounded: a stuck store must not block quitting forever.
    func drain(timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while inFlight > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
