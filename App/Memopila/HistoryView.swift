import MemopilaCore
import MemopilaServices
import SwiftUI

/// Pasta-style panel: sidebar, search on top, grid of cards (PLAN §8.2).
struct HistoryView: View {
    let model: AppModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.settings.showSidebar {
                    SidebarView(model: model)
                        .frame(width: 168)
                    Divider()
                }
                VStack(spacing: 0) {
                    topBar
                    BannerStack(model: model)
                    HistoryGrid(model: model)
                }
            }
            OverlayHost(model: model)
        }
        .overlay(alignment: .bottom) { ToastView(center: model.toasts) }
        .animation(.easeOut(duration: 0.15), value: model.toasts.current?.id)
        .animation(.easeOut(duration: 0.12), value: model.overlay)
        // The title bar is transparent and its buttons hidden: content starts at the top edge, like Pasta.
        .ignoresSafeArea()
        .frame(minWidth: 520, minHeight: 360)
        .background(.regularMaterial)
        .onAppear {
            model.openSettingsAction = openSettings
            searchFocused = true
        }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
    }

    private var topBar: some View {
        @Bindable var history = model.history
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $history.search)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel(Text("Search history"))

            if model.monitor.isPaused || model.monitor.skipArmed {
                Image(systemName: model.monitor.isPaused ? "pause.circle.fill" : "forward.end.circle.fill")
                    .foregroundStyle(.orange)
                    .help(model.monitor.isPaused ? String(localized: "Capture is paused") : String(localized: "The next copy will be skipped"))
            }

            Button {
                model.settings.showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left").foregroundStyle(.secondary)
            }
            .help(String(localized: "Show or hide the sidebar (⌥⌘S)"))
            .accessibilityLabel(Text("Sidebar"))

            Button {
                model.isPinned.toggle()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(model.isPinned ? Color.accentColor : Color.secondary)
            }
            .help(model.isPinned ? String(localized: "Unpin: close after copying and on focus loss") : String(localized: "Pin: keep the window open"))
            .accessibilityLabel(model.isPinned ? Text("Unpin window") : Text("Pin window"))

            Menu {
                PanelMenu(model: model)
            } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Menu"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// The gear menu, as in Pasta: capture controls, window options, Settings, Quit.
private struct PanelMenu: View {
    let model: AppModel

    var body: some View {
        let monitor = model.monitor
        if monitor.isPaused {
            Button("Resume Capture") { monitor.resume() }
                .keyboardShortcut(".")
        } else {
            Button("Pause Capture") { monitor.pauseIndefinitely() }
                .keyboardShortcut(".")
        }
        if monitor.skipArmed {
            Button("Cancel Skip") { monitor.toggleSkip() }
        } else {
            Button("Skip Next Copy") { monitor.toggleSkip() }
        }
        Button("Clear History…") { model.present(.confirmClear) }
            .disabled(monitor.isBusy)
        Divider()
        if model.isPinned {
            Button("Unpin Window") { model.isPinned = false }
                .keyboardShortcut("p")
        } else {
            Button("Pin Window") { model.isPinned = true }
                .keyboardShortcut("p")
        }
        if model.settings.showSidebar {
            Button("Hide Sidebar") { model.settings.showSidebar = false }
                .keyboardShortcut("s", modifiers: [.option, .command])
        } else {
            Button("Show Sidebar") { model.settings.showSidebar = true }
                .keyboardShortcut("s", modifiers: [.option, .command])
        }
        Divider()
        Button("Settings…") { model.openSettings() }
            .keyboardShortcut(",")
        Button("Quit Memopila") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let model: AppModel

    private var history: HistoryModel { model.history }

    var body: some View {
        @Bindable var history = model.history
        return List(selection: $history.sidebarSelection) {
            Section {
                Label("History", systemImage: "clock").tag(HistoryScope.all)
                Label("Favorites", systemImage: "heart").tag(HistoryScope.favorites)
            }
            if !history.apps.isEmpty {
                Section("Apps") {
                    ForEach(history.apps) { app in
                        appRow(app)
                    }
                }
            }
            if !history.types.isEmpty {
                Section("Types") {
                    ForEach(history.types, id: \.self) { type in
                        Label(type.title, systemImage: type.systemImage).tag(HistoryScope.type(type))
                    }
                }
            }
            Section("Collections") {
                ForEach(history.collections) { collection in
                    Label {
                        Text(collection.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(HistoryScope.collection(collection.id))
                    .contextMenu {
                        Button("Rename…") { model.present(.renameCollection(collection.id)) }
                        Button("Delete Collection", role: .destructive) { model.deleteCollection(collection.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.present(.newCollection(addingRecord: nil))
            } label: {
                Label("New Collection", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func appRow(_ app: AppSummary) -> some View {
        let name = AppInfo.displayName(for: app.bundleID, fallback: app.name)
        return Label {
            Text(name).lineLimit(1)
        } icon: {
            if let icon = AppInfo.icon(for: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app")
            }
        }
        .tag(HistoryScope.app(app.bundleID))
        .contextMenu {
            ActionMenuItems(items: ActionRegistry.appActions(
                bundleID: app.bundleID,
                name: name,
                storedTypes: [],
                skippedTypes: [],
                model: model
            ))
        }
    }
}

// MARK: - Banners (§8.2)

private struct BannerStack: View {
    let model: AppModel

    private var monitor: ClipboardMonitor { model.monitor }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.storeOpenError {
                Banner(
                    systemImage: "externaldrive.badge.exclamationmark",
                    tint: .red,
                    message: String(localized: "History could not be opened (\(error)). Items are kept in memory until Memopila quits.")
                )
            }
            if let error = monitor.storageError {
                Banner(systemImage: "externaldrive.badge.exclamationmark", tint: .red, message: String(localized: "Capture paused: storage error (\(error)).")) {
                    Button("Resume") { monitor.resumeAfterStorageError() }
                }
            }
            if let until = monitor.pausedUntil {
                Banner(systemImage: "pause.circle.fill", tint: .orange, message: String(localized: "Capture paused until \(until.formatted(date: .omitted, time: .shortened)).")) {
                    Button("Resume") { monitor.resume() }
                }
            } else if monitor.isPaused {
                Banner(systemImage: "pause.circle.fill", tint: .orange, message: String(localized: "Capture paused.")) {
                    Button("Resume") { monitor.resume() }
                }
            }
            switch monitor.access {
            case .allowed:
                EmptyView()
            case .needsEnable:
                Banner(
                    systemImage: "hand.raised.fill",
                    tint: .yellow,
                    message: monitor.enableHint ?? String(localized: "Memopila needs to read the clipboard in the background to build your history.")
                ) {
                    Button("Enable Capture") { monitor.enableCapture() }
                }
            case .ask, .denied:
                Banner(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .yellow,
                    message: String(localized: "Capture paused: allow Memopila to read the clipboard in System Settings → Privacy & Security, then choose Always Allow.")
                ) {
                    Button("Open Settings") { PasteboardAccess.openSystemSettings() }
                    Button("Check Again") { monitor.refreshAccess() }
                }
            }
            if let error = model.history.loadError {
                Banner(systemImage: "exclamationmark.triangle.fill", tint: .red, message: String(localized: "History could not be loaded: \(error)"))
            }
        }
    }
}

private struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(systemImage: String, tint: Color, message: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.systemImage = systemImage
        self.tint = tint
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(systemImage: String, tint: Color, message: String) {
        self.init(systemImage: systemImage, tint: tint, message: message) { EmptyView() }
    }
}

// MARK: - Grid (§8.2)

private struct HistoryGrid: View {
    let model: AppModel

    private static let spacing: CGFloat = 12
    private static let minimumCardWidth: CGFloat = 190

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - Self.spacing * 2
            let columns = max(1, Int((available + Self.spacing) / (Self.minimumCardWidth + Self.spacing)))
            let cardWidth = (available - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cardHeight = min(max(cardWidth * 0.75, 120), 240)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                        spacing: Self.spacing
                    ) {
                        if let current = model.monitor.current, model.history.search.isEmpty, model.history.scope == .all {
                            CurrentCardView(current: current, model: model)
                                .frame(height: cardHeight)
                        }
                        ForEach(Array(model.history.cards.enumerated()), id: \.element.id) { index, card in
                            CardView(
                                card: card,
                                index: index,
                                isSelected: card.id == model.history.selectedID,
                                showsShortcut: model.isCommandHeld,
                                thumbnails: model.thumbnails
                            )
                            .frame(height: cardHeight)
                            .id(card.id)
                            .onTapGesture(count: 2) { model.restore(card.id) }
                            .simultaneousGesture(TapGesture().onEnded { model.history.selectedID = card.id })
                            .contextMenu { CardContextMenu(card: card, model: model) }
                            .accessibilityAction(named: Text("Copy to Clipboard")) { model.restore(card.id) }
                            .accessibilityAction(named: Text("Preview")) { model.present(.preview(card.id)) }
                            .onAppear { model.history.cardAppeared(card) }
                        }
                    }
                    .padding(Self.spacing)
                }
                .onChange(of: model.history.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .onChange(of: columns, initial: true) { _, value in model.history.columns = value }
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        let history = model.history
        if history.cards.isEmpty, model.monitor.current == nil, history.loadError == nil {
            VStack(spacing: 6) {
                Image(systemName: history.search.isEmpty ? "list.clipboard" : "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(emptyMessage).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyMessage: String {
        let history = model.history
        if !history.search.isEmpty { return String(localized: "No matches.") }
        switch history.scope {
        case .all: return String(localized: "Copy something to start your history.")
        case .favorites: return String(localized: "No favorites yet. Press ⌘D on a card to add one.")
        case .collection: return String(localized: "This collection is empty. Add items from a card's menu.")
        case .app, .type: return String(localized: "Nothing here.")
        }
    }
}

// MARK: - Overlays

private struct OverlayHost: View {
    let model: AppModel

    var body: some View {
        if let overlay = model.overlay {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { model.present(nil) }
                content(for: overlay)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                    .shadow(radius: 20, y: 6)
                    .padding(24)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func content(for overlay: PanelOverlay) -> some View {
        switch overlay {
        case .preview(let id):
            PreviewOverlay(model: model, id: id)
        case .editor:
            if let state = model.editorState { EditorOverlay(model: model, state: state) }
        case .rename(let id):
            let card = model.history.cards.first { $0.id == id }
            NameOverlay(
                title: String(localized: "Rename"),
                prompt: String(localized: "Title (empty removes it)"),
                initial: card?.customTitle ?? "",
                confirm: String(localized: "Rename"),
                allowsEmpty: true
            ) { model.rename(id, title: $0) } cancel: { model.present(nil) }
        case .actions:
            if let state = model.actionsState { ActionsPanel(state: state, model: model) }
        case .newCollection(let recordID):
            NameOverlay(
                title: String(localized: "New Collection"),
                prompt: String(localized: "Name"),
                initial: "",
                confirm: String(localized: "Create"),
                allowsEmpty: false
            ) { model.createCollection(named: $0, adding: recordID) } cancel: { model.present(nil) }
        case .renameCollection(let id):
            NameOverlay(
                title: String(localized: "Rename Collection"),
                prompt: String(localized: "Name"),
                initial: model.history.collections.first { $0.id == id }?.name ?? "",
                confirm: String(localized: "Rename"),
                allowsEmpty: false
            ) { model.renameCollection(id, to: $0) } cancel: { model.present(nil) }
        case .confirmDelete(let ids):
            ConfirmDeleteOverlay(count: ids.count) {
                model.delete(ids, confirmed: true)
            } cancel: {
                model.present(nil)
            }
        case .confirmClear:
            ConfirmClearOverlay {
                model.present(nil)
                model.clear(.nonFavorites)
            } cancel: {
                model.present(nil)
            }
        }
    }
}

private struct NameOverlay: View {
    let title: String
    let prompt: String
    let initial: String
    let confirm: String
    let allowsEmpty: Bool
    let onConfirm: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(
        title: String,
        prompt: String,
        initial: String,
        confirm: String,
        allowsEmpty: Bool,
        onConfirm: @escaping (String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.title = title
        self.prompt = prompt
        self.initial = initial
        self.confirm = confirm
        self.allowsEmpty = allowsEmpty
        self.onConfirm = onConfirm
        self.cancel = cancel
        _text = State(initialValue: initial)
    }

    private var canConfirm: Bool {
        allowsEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if canConfirm { onConfirm(text) } }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(confirm) { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}

/// Clear from the gear menu (§3.2 Clear History scopes): non-favorites only; Settings → Storage
/// also offers clearing everything.
private struct ConfirmClearOverlay: View {
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete all items except favorites?").font(.headline)
            Text("This can't be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Clear History", role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

private struct ConfirmDeleteOverlay: View {
    let count: Int
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? String(localized: "Delete this favorite?") : String(localized: "Delete \(count) items, including favorites?"))
                .font(.headline)
            Text("Favorites are never removed automatically. This can't be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Delete", role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

// MARK: - Display helpers

extension DisplayType {
    var title: String {
        switch self {
        case .text: String(localized: "Text")
        case .richText: String(localized: "Rich Text")
        case .url: String(localized: "Links")
        case .image: String(localized: "Images")
        case .pdf: String(localized: "PDF")
        case .color: String(localized: "Colors")
        case .file: String(localized: "Files")
        case .mixed: String(localized: "Mixed")
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .url: "link"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .color: "paintpalette"
        case .file: "doc"
        case .mixed: "square.stack"
        }
    }
}
