import Observation
import SwiftUI

/// Short confirmations in the panel, with Undo for settings changes (PLAN §5.1).
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
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, isError: Bool = false, actions: [Toast.Action] = []) {
        // Sacred Undo: do not replace a delete-Undo toast with a transient message.
        if actions.isEmpty, current.map({ !$0.actions.isEmpty && !$0.isError }) == true {
            return
        }
        present(message, isError: isError, actions: actions)
    }

    /// Delete / stack-delete Undo toast — always replaces the current toast.
    func showUndo(_ message: String, undo: @escaping @MainActor () -> Void) {
        present(message, actions: [.init(title: String(localized: "Undo"), run: undo)])
    }

    func clearUndo() {
        guard let current, !current.actions.isEmpty, !current.isError else { return }
        dismiss()
    }

    private func present(_ message: String, isError: Bool = false, actions: [Toast.Action] = []) {
        let toast = Toast(message: message, isError: isError, actions: actions)
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
