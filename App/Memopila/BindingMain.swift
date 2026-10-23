import SwiftUI

extension Binding where Value: Sendable {
    /// A binding over main-actor state that compiles the same whether or not the SDK marks
    /// `Binding(get:set:)` closures `@Sendable`.
    @MainActor
    static func main(get: @escaping @MainActor @Sendable () -> Value, set: @escaping @MainActor @Sendable (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { get() } },
            set: { value in MainActor.assumeIsolated { set(value) } }
        )
    }
}
