import Observation
import SwiftUI

/// Short confirmations in the panel, with Undo for settings changes (PLAN §5.1).
/// Delete-Undo is a leased channel: while armed, errors and settings-Undo must not replace it
/// (`pendingDeletion` would keep committing with no matching toast).
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable {
        struct Action: Identifiable {
            let id = UUID()
            let title: String
            let run: @MainActor () -> Void
        }

        let id = UUID()
        let message: String
        var isError = false
        var actions: [Action] = []
        /// History/stack delete Undo — not settings Undo.
        var isDeleteUndo = false
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, isError: Bool = false, actions: [Toast.Action] = []) {
        // Sacred delete-Undo: notices, errors, and settings-Undo wait until it clears.
        if hasUndo { return }
        present(message, isError: isError, actions: actions)
    }

    /// Delete / stack-delete Undo toast — always replaces the current toast. Returns the toast id
    /// so a background commit of an *older* delete cannot dismiss a newer Undo.
    @discardableResult
    func showUndo(_ message: String, undo: @escaping @MainActor () -> Void) -> UUID {
        present(message, actions: [.init(title: String(localized: "Undo"), run: undo)], isDeleteUndo: true)
        return current!.id
    }

    /// Dismiss Undo only when it is still the toast that owned this delete.
    func clearUndo(ifMatches id: UUID) {
        guard current?.id == id, current?.isDeleteUndo == true else { return }
        dismiss()
    }

    /// Armed history/stack delete Undo (not settings Undo).
    var hasUndo: Bool { current?.isDeleteUndo == true }

    func dismissTransient() {
        guard !hasUndo else { return }
        dismiss()
    }

    private func present(
        _ message: String,
        isError: Bool = false,
        actions: [Toast.Action] = [],
        isDeleteUndo: Bool = false
    ) {
        let toast = Toast(message: message, isError: isError, actions: actions, isDeleteUndo: isDeleteUndo)
        current = toast
        dismissTask?.cancel()
        let seconds = actions.isEmpty ? 3.0 : 6.0
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            withAnimation { self?.current = nil }
        }
    }

    func error(_ message: String) {
        // Do not steal delete-Undo; the failure still surfaces via Diagnostics / next notice.
        if hasUndo { return }
        present(message, isError: true)
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastView: View {
    let center: ToastCenter

    var body: some View {
        if let toast = center.current {
            HStack(spacing: 12) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Color.orange : Color.green)
                Text(toast.message)
                    .lineLimit(2)
                ForEach(toast.actions) { action in
                    Button(action.title) {
                        center.dismiss()
                        action.run()
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thickMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .accessibilityElement(children: .contain)
        }
    }
}
