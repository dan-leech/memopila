import MemopilaCore
import SwiftUI

/// *Changes…* in the record window (PLAN §8.5): the edited text against the saved one, line by
/// line, before saving. Computed once when the sheet opens, off the main thread, and bounded
/// (`LineDiff`), so it costs nothing until asked for.
struct ChangesSheet: View {
    let original: String
    let edited: String
    /// Formatted text whose formatting changed: said when the words did not.
    var formattingChanged = false
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var diff: LineDiff?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Changes", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                if let diff, !diff.isEmpty {
                    HStack(spacing: 6) {
                        Text(verbatim: "+\(diff.added)").foregroundStyle(.green)
                        Text(verbatim: "−\(diff.removed)").foregroundStyle(.red)
                    }
                    .font(.callout.monospacedDigit())
                    .floatingHelp(String(localized: "Lines added and removed"))
                }
                Spacer()
            }
            .padding(12)
            Divider()
            Group {
                if let diff {
                    if diff.isEmpty {
                        (formattingChanged ? Text("Only the formatting changed.") : Text("The text is the same as the saved text."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        rows(diff)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                if diff?.isTruncated == true {
                    Text("Only the first changes are shown.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    dismiss()
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .floatingHelp(String(localized: "Save the changes; the window stays open"))
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
        .task {
            let original = original
            let edited = edited
            diff = await Task.detached(priority: .userInitiated) { LineDiff.compare(original, edited) }.value
        }
    }

    private func rows(_ diff: LineDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.rows.indices, id: \.self) { index in
                    switch diff.rows[index] {
                    case .line(let line):
                        LineRow(line: line)
                    case .skipped(let count):
                        Text(String(localized: "⋯ \(count) unchanged lines"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 3)
                            .padding(.leading, 92)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private struct LineRow: View {
        let line: LineDiff.Line

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(line.oldNumber)
                number(line.newNumber)
                Text(verbatim: marker)
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 18)
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.vertical, 1)
            .background(tint.map { $0.opacity(0.12) } ?? .clear)
        }

        private func number(_ value: Int?) -> some View {
            Text(verbatim: value.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)
        }

        private var marker: String {
            switch line.kind {
            case .same: " "
            case .removed: "−"
            case .added: "+"
            }
        }

        private var tint: Color? {
            switch line.kind {
            case .same: nil
            case .removed: .red
            case .added: .green
            }
        }
    }
}
