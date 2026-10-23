import MemopilaCore
import SwiftUI

/// Pasta-style panel: search on top, grid of cards below (PLAN §8.2). Phase 1 shell: no sidebar yet.
struct HistoryView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            AccessBanner(monitor: model.monitor)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        if let current = model.monitor.current, model.searchText.isEmpty {
                            CurrentCard(current: current, monitor: model.monitor)
                        }
                        ForEach(model.filteredHistory) { entry in
                            CardView(entry: entry, isSelected: entry.id == model.selectedID)
                                .id(entry.id)
                                .onTapGesture(count: 2) { model.restore(entry) }
                                .onTapGesture { model.selectedID = entry.id }
                                .contextMenu { contextMenu(for: entry) }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                }
            }
            .overlay {
                if model.filteredHistory.isEmpty && model.monitor.current == nil {
                    Text(model.searchText.isEmpty ? "Copy something to start your history." : "No matches.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.openCount) { _, _ in searchFocused = true }
        .onChange(of: model.searchText) { _, _ in model.selectedID = model.filteredHistory.first?.id }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { model.restoreSelected() }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.restoreSelected(plainText: true)
                    return .handled
                }
            Button {
                model.isPinned.toggle()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(model.isPinned ? "Unpin: close after copying and on focus loss" : "Pin: keep the window open")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        Button("Copy to Clipboard") { model.restore(entry) }
        if entry.plainTextItems != nil {
            Button("Copy as Plain Text") { model.restore(entry, plainText: true) }
        }
        if let text = TextDecoding.plainText(of: entry.snapshot.items) {
            Menu("Copy As") {
                ForEach(TextAction.allCases, id: \.self) { action in
                    Button(action.title) { model.copy(text: action.apply(to: text), from: entry) }
                        .disabled(!action.isAvailable(for: text))
                }
            }
        }
        if let url = entry.snapshot.sourceURL, let link = URL(string: url) {
            Button("Open Source Page") { NSWorkspace.shared.open(link) }
        }
        if !entry.filePaths.isEmpty {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(entry.filePaths.map { URL(fileURLWithPath: $0) })
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.monitor.delete(entry) }
    }
}

private struct AccessBanner: View {
    let monitor: ClipboardMonitor

    var body: some View {
        if let message {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.callout)
                Spacer()
                action
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.12))
        }
    }

    private var message: String? {
        if let until = monitor.pausedUntil {
            return "Capture paused until \(until.formatted(date: .omitted, time: .shortened))."
        }
        if monitor.isPaused { return "Capture paused." }
        switch monitor.access {
        case .allowed: return nil
        case .needsEnable: return "Memopila needs to read the clipboard in the background to build your history."
        case .ask, .denied: return "Capture paused: allow Memopila in System Settings → Privacy & Security, then choose Always Allow."
        }
    }

    @ViewBuilder
    private var action: some View {
        if monitor.isPaused {
            Button("Resume") { monitor.resume() }
        } else if monitor.access == .needsEnable {
            Button("Enable capture") { _ = monitor.enableCapture() }
        } else {
            Button("Check again") { monitor.refreshAccess() }
        }
    }
}

private struct CurrentCard: View {
    let current: CurrentClipboard
    let monitor: ClipboardMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Current — not saved", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(current.title).font(.callout)
            Text(current.change.declaredTypes.map(\.rawValue).joined(separator: ", "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                Button("Save anyway") { monitor.saveCurrentAnyway() }
                Button("Dismiss") { monitor.dismissCurrent() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(height: 150, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.red.opacity(0.6), lineWidth: 1.5))
    }
}

struct CardView: View {
    let entry: HistoryEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(10)
        .frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Checkerboard().opacity(0.25))
        } else if let text = entry.previewText {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(entry.snapshot.displayType == .url ? Color.accentColor : .primary)
                .lineLimit(5)
        } else if !entry.filePaths.isEmpty {
            Label(entry.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), systemImage: "doc")
                .lineLimit(3)
        } else {
            Text(entry.snapshot.items.first?.representations.first?.type.rawValue ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let icon = AppInfo.icon(for: entry.metadata.lastSourceAppBundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(entry.metric).lineLimit(1)
            Spacer()
            Text(RelativeTime.short(entry.metadata.lastCopiedAt))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray))
                }
            }
        }
    }
}

/// *Now*, *2m*, *3h*, *4d* (§8.2).
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "Now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

extension TextAction {
    var title: String {
        switch self {
        case .trimWhitespace: "Trim Whitespace"
        case .removeLineBreaks: "Remove Line Breaks"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .sortLines: "Sort Lines"
        case .removeDuplicateLines: "Remove Duplicate Lines"
        case .formatJSON: "Format JSON"
        case .minifyJSON: "Minify JSON"
        case .urlEncode: "URL-Encode"
        case .urlDecode: "URL-Decode"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        }
    }
}
