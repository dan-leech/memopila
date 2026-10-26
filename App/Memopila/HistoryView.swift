import MemopilaCore
import MemopilaServices
import SwiftUI
import UniformTypeIdentifiers

/// Pasta-style panel: sidebar, search on top, grid of cards (PLAN §8.2).
struct HistoryView: View {
    let model: AppModel
    @FocusState private var searchFocused: Bool

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
                    FilterBar(model: model)
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
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
        .onChange(of: model.focusGridToken) { _, _ in searchFocused = false }
        // A click in the search field takes the keyboard back from the cards.
        .onChange(of: searchFocused) { _, focused in if focused { model.gridHasFocus = false } }
        // The selection shows what the clipboard holds until the user moves it (§8.2).
        .onChange(of: model.monitor.clipboardRecordID) { _, _ in model.history.clipboardDidChange() }
    }

    private var topBar: some View {
        @Bindable var history = model.history
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // The sidebar choice stays visible here, also with the sidebar hidden (§8.2).
            if history.scope != .all {
                ScopeChip(model: model)
            }
            TextField(String(localized: "Search"), text: $history.search)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel(Text("Search history"))
            if !history.search.isEmpty {
                HoverIconButton(
                    systemImage: "xmark.circle.fill",
                    help: String(localized: "Clear the search (Esc)"),
                    recolorsLabel: false,
                    tint: Color(nsColor: .tertiaryLabelColor)
                ) {
                    history.search = ""
                    model.focusSearch()
                }
            }

            HoverIconButton(
                systemImage: "sidebar.left",
                help: String(localized: "Show or hide the sidebar (⌥⌘S)"),
                recolorsLabel: false,
                tint: .secondary
            ) {
                model.settings.showSidebar.toggle()
            }

            HoverIconButton(
                systemImage: model.isPinned ? "pin.fill" : "pin",
                help: model.isPinned
                    ? String(localized: "Unpin (⌘P): the window closes after Choose for Clipboard or when you switch apps")
                    : String(localized: "Pin (⌘P): keep the window open after Choose for Clipboard and when you switch apps"),
                emphasized: model.isPinned
            ) {
                model.isPinned.toggle()
            }

            HoverIconMenu(
                systemImage: "gearshape",
                help: String(localized: "Pause, Clear History, Settings and more")
            ) {
                PanelMenu(model: model)
            }
        }
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
            Menu("Pause Capture") {
                Button("5 Minutes") { monitor.pause(minutes: 5) }
                Button("15 Minutes") { monitor.pause(minutes: 15) }
                Button("1 Hour") { monitor.pause(minutes: 60) }
                Button("Until I Resume") { monitor.pauseIndefinitely() }
                    .keyboardShortcut(".")
            }
        }
        if monitor.skipArmed {
            Button("Cancel Skip") { monitor.toggleSkip() }
        } else {
            Button("Skip Next Copy") { monitor.toggleSkip() }
        }
        // Filtered or searched: everything the panel shows now; else all of history.
        if model.history.isFiltered || !model.history.search.isEmpty {
            Button(String(localized: "Delete \(model.history.totalCount) Shown…")) { model.deleteAllShown() }
                .disabled(monitor.isBusy || model.history.totalCount == 0)
        }
        Button("Clear History…") { model.present(.confirmClear) }
            .disabled(monitor.isBusy)
        Divider()
        Button("Keyboard Shortcuts") { model.present(.shortcuts) }
            .keyboardShortcut("/")
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
        Button("About Memopila") { model.openSettings(.about) }
        // A tool for reporting problems: with ⌥ held, as in many Mac apps.
        if model.isOptionHeld {
            Button("Diagnostics…") { model.openDiagnostics() }
        }
        Button("Quit Memopila") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Filters (§8.2)

/// The sidebar choice in the search field, with ✕ to go back to all of History.
private struct ScopeChip: View {
    let model: AppModel

    var body: some View {
        let history = model.history
        HStack(spacing: 4) {
            Image(systemName: symbol(history.scope))
            Text(title(history.scope)).lineLimit(1)
            Button {
                history.scope = .all
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolbarIconStyle(recolorsLabel: false))
            .floatingHelp(String(localized: "Show all of History"))
            .accessibilityLabel(Text("Show all of History"))
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .frame(maxWidth: 180)
        .fixedSize()
    }

    private func title(_ scope: HistoryScope) -> String {
        switch scope {
        case .all:
            return String(localized: "History")
        case .favorites:
            return String(localized: "Favorites")
        case .app(let bundleID):
            return AppInfo.displayName(for: bundleID, fallback: model.history.apps.first { $0.bundleID == bundleID }?.name)
        case .type(let type):
            return type.title
        case .collection(let id):
            return model.history.collections.first { $0.id == id }?.name ?? String(localized: "Collection")
        case .stack(let id):
            let name = model.history.allStacks.first { $0.id == id }?.title ?? ""
            return name.isEmpty ? String(localized: "Stack") : name
        }
    }

    private func symbol(_ scope: HistoryScope) -> String {
        switch scope {
        case .all: "clock"
        case .favorites: "heart"
        case .app: "app"
        case .type(let type): type.systemImage
        case .collection: "folder"
        case .stack: "rectangle.stack"
        }
    }
}

/// Kind and period above the grid; they combine with the sidebar and the search.
private struct FilterBar: View {
    let model: AppModel

    private var history: HistoryModel { model.history }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(visibleKinds, id: \.self) { kind in
                    let isOn = history.kindFilter == kind
                    Button {
                        history.kindFilter = kind
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .background(isOn ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .floatingHelp(kindHelp(kind))
                    .accessibilityLabel(Text(kindHelp(kind)))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PanelStatus(model: model)
            Menu {
                ForEach(PeriodFilter.allCases, id: \.self) { period in
                    Button {
                        history.periodFilter = period
                    } label: {
                        if period == history.periodFilter {
                            Label(period.title, systemImage: "checkmark")
                        } else {
                            Text(period.title)
                        }
                    }
                }
            } label: {
                Label(history.periodFilter.title, systemImage: "calendar")
                    .font(.system(size: 12, weight: history.periodFilter == .anyTime ? .regular : .semibold))
                    .foregroundStyle(history.periodFilter == .anyTime ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ToolbarIconStyle(recolorsLabel: false))
            .fixedSize()
            .floatingHelp(String(localized: "Only items copied in this period"))
            .accessibilityLabel(Text("Only items copied in this period"))
            .accessibilityValue(Text(history.periodFilter.title))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    /// Colours only when there are any.
    private var visibleKinds: [KindFilter] {
        KindFilter.allCases.filter { kind in
            kind != .colors || history.types.contains(.color) || history.kindFilter == .colors
        }
    }

    private func kindHelp(_ kind: KindFilter) -> String {
        switch kind {
        case .all: String(localized: "Every kind of item")
        case .stacks: String(localized: "Only paste stacks")
        default: String(localized: "Only \(kind.title.lowercased())")
        }
    }
}

/// Rows of chips that wrap instead of shrinking labels letter-by-letter.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(proposal: proposal, subviews: subviews).frames
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frames[index].minX, y: bounds.minY + frames[index].minY),
                proposal: ProposedViewSize(frames[index].size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            widest = max(widest, x - spacing)
        }

        let width = maxWidth.isFinite ? maxWidth : widest
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}

/// How many records the panel shows and whether capture runs (§8.2). First-run feedback: the
/// panel showed neither; problems also have a banner, this is the state at a glance.
private struct PanelStatus: View {
    let model: AppModel

    var body: some View {
        let status = captureStatus
        // A narrow panel keeps the number, then only the dot.
        ViewThatFits(in: .horizontal) {
            label(status, countText)
            label(status, "\(model.history.totalCount)")
            label(status, nil)
        }
        .font(.system(size: 11).monospacedDigit())
        .floatingHelp(status.help + " · " + countText)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if model.history.totalCount > 0 {
                Button(String(localized: "Delete \(model.history.totalCount) Shown…")) { model.deleteAllShown() }
            }
        }
    }

    private func label(_ status: (symbol: String, tint: Color, help: String), _ text: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .imageScale(.small)
            if let text {
                Text(verbatim: text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var countText: String {
        let history = model.history
        var parts: [String] = []
        if !history.markedIDs.isEmpty {
            parts.append(String(localized: "\(history.selection.count) selected"))
        }
        if let armed = model.stackSession.armedStackID,
           history.stacks.contains(where: { $0.id == armed }) || history.allStacks.contains(where: { $0.id == armed }),
           let progress = model.stackSession.progressLabel {
            parts.append(String(localized: "Armed \(progress)"))
        }
        if !history.search.isEmpty || history.isFiltered {
            parts.append(String(localized: "\(history.totalCount) found"))
        } else {
            parts.append(String(localized: "\(history.totalCount) items"))
        }
        return parts.joined(separator: " · ")
    }

    private var captureStatus: (symbol: String, tint: Color, help: String) {
        let monitor = model.monitor
        if monitor.storageError != nil || monitor.access != .allowed || monitor.isPaused {
            return ("pause.circle.fill", .orange, String(localized: "Capture is paused: new copies are not added to history"))
        }
        if monitor.skipArmed {
            return ("forward.end.circle.fill", .orange, String(localized: "The next copy will be skipped"))
        }
        return ("circle.fill", .green, String(localized: "Capturing: every copy is added to history"))
    }
}

// MARK: - Sidebar

/// A collection in the sidebar: a card dropped on it joins it (§3.5).
private struct CollectionRow: View {
    let collection: CollectionSummary
    let model: AppModel
    @State private var isTargeted = false

    var body: some View {
        Label {
            Text(collection.name)
        } icon: {
            Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder")
        }
        .padding(.vertical, 1)
        .background(isTargeted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onDrop(of: [.item], isTargeted: $isTargeted) { _ in model.dropDraggedCard(on: collection.id) }
        .floatingHelp(String(localized: "Drop a card here to add it"))
        .contextMenu {
            Button("Rename…") { model.present(.renameCollection(collection.id)) }
            Button("Delete All Items in It…") {
                model.deleteAll(matching: HistoryQuery(scope: .collection(collection.id)), scope: .collection(collection.name))
            }
            Divider()
            Button("Delete Collection…", role: .destructive) { model.present(.confirmDeleteCollection(collection.id)) }
        }
    }
}

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
            Section("Collections") {
                ForEach(history.collections) { collection in
                    CollectionRow(collection: collection, model: model)
                        .tag(HistoryScope.collection(collection.id))
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
            .floatingHelp(String(localized: "Create a collection for grouping records"))
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
            Divider()
            Button(String(localized: "Delete All from \(name)…")) {
                model.deleteAll(matching: HistoryQuery(scope: .app(app.bundleID)), scope: .app(name))
            }
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
            if let folder = model.storeMovedAside {
                Banner(
                    systemImage: "externaldrive.badge.exclamationmark",
                    tint: .orange,
                    message: String(localized: "The history could not be opened, so a new one was started. The old files are kept in “\(folder.lastPathComponent)”.")
                ) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Button("Dismiss") { model.dismissStoreRecovery() }
                }
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
            // The panel's shortcut could not be registered: said where it is seen, not only in
            // Settings (review finding).
            if let error = model.hotKeyErrors[.window] {
                Banner(systemImage: "keyboard", tint: .orange, message: error) {
                    Button("Change Shortcut…") { model.openSettings(.general) }
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

    private static let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            // Columns × rows fill the visible area, as in Pasta (3 × 3 by default); cards resize with the window.
            let grid = model.settings.gridSize
            let columns = max(1, grid.columns)
            let rows = CGFloat(max(1, grid.rows))
            let cardHeight = max(56, (geometry.size.height - Self.spacing * (rows + 1)) / rows)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                        spacing: Self.spacing
                    ) {
                        if let current = model.monitor.current, model.history.search.isEmpty, model.history.scope == .all {
                            if current.status == .concealed {
                                ConcealedCardView(current: current, model: model)
                                    .frame(height: cardHeight)
                            } else {
                                CurrentCardView(current: current, model: model)
                                    .frame(height: cardHeight)
                            }
                        }
                        ForEach(Array(model.history.entries.enumerated()), id: \.element.id) { index, entry in
                            entryCell(entry, index: index, cardHeight: cardHeight)
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
    private func entryCell(_ entry: HistoryEntry, index: Int, cardHeight: CGFloat) -> some View {
        switch entry {
        case .record(let card):
            CardView(
                card: card,
                index: index,
                hasCursor: model.history.isSelected(entry.id),
                model: model,
                onDoubleClick: {
                    model.restore(card.id, paste: NSEvent.modifierFlags.contains(.option) ? true : nil)
                }
            )
            .frame(height: cardHeight)
            .simultaneousGesture(TapGesture().onEnded {
                model.history.click(entry.id, modifiers: NSEvent.modifierFlags)
                model.focusGrid()
            })
            .contextMenu { CardContextMenu(card: card, model: model) }
            .onDrag {
                model.beginCardDrag(card.id)
                return DragSupport.provider(for: card, store: model.store)
            }
            .id(entry.id)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .opacity
            ))
            .accessibilityAction(named: Text("Choose for Clipboard")) { model.restore(card.id) }
            .accessibilityAction(named: Text("Choose and Paste")) { model.restore(card.id, paste: true) }
            .accessibilityAction(named: Text("Edit Record")) { model.openRecord(card.id) }
            .onAppear { model.history.entryAppeared(entry) }
        case .stack(let stack):
            StackCardView(
                stack: stack,
                index: index,
                hasCursor: model.history.isSelected(entry.id),
                model: model,
                onDoubleClick: {
                    model.chooseStack(stack.id, paste: NSEvent.modifierFlags.contains(.option) ? true : nil)
                }
            )
                .frame(height: cardHeight)
                .id(entry.id)
                .simultaneousGesture(TapGesture().onEnded {
                    model.history.click(entry.id, modifiers: NSEvent.modifierFlags)
                    model.focusGrid()
                })
                .contextMenu {
                    ActionMenuItems(items: ActionRegistry.stackActions(stack, model: model))
                }
                .onDrag {
                    guard stack.memberCount > 0 else { return NSItemProvider() }
                    model.beginStackDrag(stack.id)
                    return DragSupport.provider(for: stack, store: model.store, armedMemberID: model.stackSession.currentMemberID)
                }
                .onDrop(of: [.item], isTargeted: nil) { _ in
                    model.dropDraggedCard(onStack: stack.id)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .opacity
                ))
                .accessibilityAction(named: Text("Choose Stack")) { model.chooseStack(stack.id) }
                .accessibilityAction(named: Text("Choose and Paste")) { model.chooseStack(stack.id, paste: true) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let history = model.history
        if history.entries.isEmpty, model.monitor.current == nil, history.loadError == nil {
            VStack(spacing: 6) {
                Image(systemName: history.search.isEmpty ? "list.clipboard" : "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(emptyMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if history.isFiltered {
                    Button("Show All of History") { history.clearFilters() }
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
    }

    private var emptyMessage: String {
        let history = model.history
        if !history.search.isEmpty {
            return history.isFiltered ? String(localized: "No matches with these filters.") : String(localized: "No matches.")
        }
        if history.kindFilter == .stacks {
            return String(localized: "No stacks yet. Choose New Stack… on a card, then drag more onto it.")
        }
        if history.kindFilter != .all || history.periodFilter != .anyTime {
            return String(localized: "Nothing matches the filters.")
        }
        switch history.scope {
        case .all: return String(localized: "Copy something to start your history.")
        case .favorites: return String(localized: "No favorites yet. Press ⌘D on a card to add one.")
        case .collection: return String(localized: "This collection is empty. Drop a card on it in the sidebar, or use Collections in a card's menu.")
        case .stack(let id):
            let name = history.allStacks.first { $0.id == id }?.title
            let title = (name?.isEmpty == false) ? name! : String(localized: "Stack")
            return String(localized: "“\(title)” is empty. Drop cards here to add them.")
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
        case .rename(let entryID):
            switch entryID {
            case .record(let id):
                let card = model.history.cards.first { $0.id == id }
                NameOverlay(
                    title: String(localized: "Rename"),
                    prompt: String(localized: "Title (empty removes it)"),
                    initial: card?.customTitle ?? "",
                    confirm: String(localized: "Rename"),
                    allowsEmpty: true
                ) { model.rename(id, title: $0) } cancel: { model.present(nil) }
            case .stack(let id):
                let stack = model.history.stacks.first { $0.id == id }
                NameOverlay(
                    title: String(localized: "Rename Stack"),
                    prompt: String(localized: "Title"),
                    initial: stack?.title ?? "",
                    confirm: String(localized: "Rename"),
                    allowsEmpty: false
                ) { model.renameStack(id, title: $0); model.present(nil) } cancel: { model.present(nil) }
            }
        case .newStack:
            NameOverlay(
                title: String(localized: "New Stack"),
                prompt: String(localized: "Title"),
                initial: String(localized: "Stack"),
                confirm: String(localized: "Create"),
                allowsEmpty: false
            ) { model.createStackFromSelection(title: $0); model.present(nil) } cancel: { model.present(nil) }
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
        case .confirmDeleteMany(let scope, let others, let favorites):
            ConfirmDeleteManyOverlay(scope: scope, others: others.count, favorites: favorites.count) {
                model.present(nil)
                model.delete(others, confirmed: true)
            } deleteFavoritesToo: {
                model.present(nil)
                model.delete(others + favorites, confirmed: true)
            } cancel: {
                model.present(nil)
            }
        case .confirmDeleteCollection(let id):
            ConfirmDeleteCollectionOverlay(name: model.history.collections.first { $0.id == id }?.name ?? "") {
                model.deleteCollection(id)
            } cancel: {
                model.present(nil)
            }
        case .confirmUnfavorite(let ids, let old):
            ConfirmUnfavoriteOverlay(count: ids.count, old: old, maxAgeDays: model.settings.maxAgeDays) {
                model.toggleFavorites(ids, confirmed: true)
            } cancel: {
                model.present(nil)
            }
        case .shortcuts:
            ShortcutsOverlay { model.present(nil) }
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
            Text("Delete all items except favorites and stack members?").font(.headline)
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

/// ⌘/ — every shortcut of the panel in one place (§8.3).
private struct ShortcutsOverlay: View {
    let close: () -> Void

    private struct Row: Hashable {
        let keys: String
        let action: String
    }

    private struct Group: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    private let groups: [Group] = [
        Group(title: String(localized: "Choose"), rows: [
            Row(keys: "↩ / " + String(localized: "double-click"), action: String(localized: "Choose for Clipboard: put the record on the clipboard and go back")),
            Row(keys: "⌥↩ / ⌥ " + String(localized: "double-click"), action: String(localized: "Choose and Paste into the app you were in")),
            Row(keys: "⌘1 … ⌘9", action: String(localized: "Choose for Clipboard: the first nine cards")),
            Row(keys: "⌘C", action: String(localized: "Choose for Clipboard without pasting")),
        ]),
        Group(title: String(localized: "Move and select"), rows: [
            Row(keys: "↑ ↓ ← →", action: String(localized: "Move between cards")),
            Row(keys: "⇧ ↑ ↓ ← →, ⌘-" + String(localized: "click") + ", ⇧-" + String(localized: "click"), action: String(localized: "Select several cards")),
            Row(keys: "⌘F", action: String(localized: "Search")),
            Row(keys: "Esc", action: String(localized: "Clear the search, then close; stop an armed stack")),
        ]),
        Group(title: String(localized: "Records"), rows: [
            Row(keys: String(localized: "Space") + " / ⌘E", action: String(localized: "Edit Record")),
            Row(keys: "⌘R", action: String(localized: "Rename…")),
            Row(keys: "⌘D", action: String(localized: "Add to or remove from Favorites")),
            Row(keys: "⌘⌫", action: String(localized: "Delete (Undo in the message that follows)")),
            Row(keys: "⌘K", action: String(localized: "All actions for the card")),
        ]),
        Group(title: String(localized: "Window"), rows: [
            Row(keys: "⌘P", action: String(localized: "Pin the window")),
            Row(keys: "⌥⌘S", action: String(localized: "Show or hide the sidebar")),
            Row(keys: "⌘+ / ⌘−", action: String(localized: "Bigger or smaller cards")),
            Row(keys: "⌘.", action: String(localized: "Pause or resume capture (in the panel)")),
            Row(keys: "⌘,", action: String(localized: "Settings")),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(groups) { group in
                        GridRow {
                            Text(group.title).font(.subheadline.bold()).gridCellColumns(2).padding(.top, 6)
                        }
                        ForEach(group.rows, id: \.self) { row in
                            GridRow {
                                Text(row.keys).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                Text(row.action).font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 540, height: 460)
    }
}

private struct ConfirmDeleteCollectionOverlay: View {
    let name: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Delete the collection “\(name)”?")).font(.headline)
            Text("Its items stay in history and in other collections.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Delete Collection", role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

/// *Delete All…*: how many, what happens to favorites, and that Undo is there for a moment.
private struct ConfirmDeleteManyOverlay: View {
    let scope: DeleteManyScope
    let others: Int
    let favorites: Int
    let delete: () -> Void
    let deleteFavoritesToo: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question).font(.headline)
            if favorites > 0 {
                Text(String(localized: "Favorites or stack members among them: \(favorites). They are kept unless you delete them too."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("You can undo it for a few seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                if favorites > 0 {
                    Button(String(localized: "Delete Favorites Too"), role: .destructive, action: deleteFavoritesToo)
                }
                if others > 0 {
                    Button(String(localized: "Delete \(others) Items"), role: .destructive, action: delete)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private var question: String {
        let total = others + favorites
        switch scope {
        case .shown: return String(localized: "Delete the \(total) items shown?")
        case .app(let name): return String(localized: "Delete all \(total) items from \(name)?")
        case .collection(let name): return String(localized: "Delete all \(total) items in “\(name)”?")
        }
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

private struct ConfirmUnfavoriteOverlay: View {
    let count: Int
    let old: Int
    let maxAgeDays: Int
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? String(localized: "Remove from Favorites and delete?") : String(localized: "Remove \(count) items from Favorites?"))
                .font(.headline)
            Text(count == 1
                ? String(localized: "It is older than History keeps (\(maxAgeDays) days), so it is deleted. This can't be undone.")
                : String(localized: "\(old) of them are older than History keeps (\(maxAgeDays) days) and are deleted. This can't be undone."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(count == 1 ? String(localized: "Remove and Delete") : String(localized: "Remove"), role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
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
