import AppKit
import Carbon.HIToolbox
import MemopilaCore
import MemopilaServices
import SwiftUI

/// Stack editor window (PLAN §3.11): floating, replaces the panel like Edit Record.
final class StackWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

struct StackWindowContent: View {
    let model: AppModel

    var body: some View {
        Group {
            if let state = model.stackEditor {
                StackEditorView(model: model, state: state)
                    .id(state.stackID)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) { ToastView(center: model.toasts) }
        .animation(.easeOut(duration: 0.15), value: model.toasts.current?.id)
    }
}

@MainActor
enum StackKeys {
    static func handle(_ event: NSEvent, in window: NSWindow, model: AppModel) -> Bool {
        guard let state = model.stackEditor else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = KeyPress(event)
        let editingField = window.firstResponder is NSText

        if key.code == kVK_Escape {
            // Title / filter field editor: first Esc only leaves the field (spaces must type).
            if let field = window.firstResponder as? NSTextView, field.isFieldEditor {
                window.makeFirstResponder(nil)
                return true
            }
            if !state.search.isEmpty {
                state.search = ""
                return true
            }
            model.closeStackEditor()
            return true
        }

        // While the title or filter has focus, Space / ↩ type or commit the field — not Edit / Choose.
        if editingField { return false }

        if flags == [.option, .command], key.letter == "i" {
            NotificationCenter.default.post(name: .stackEditorToggleInspector, object: nil)
            return true
        }
        if flags == .command, key.letter == "e", let id = state.selectedID {
            model.openRecord(id)
            return true
        }
        if flags == .command, key.letter == "d" {
            model.toggleStackFavorite(state.stackID)
            return true
        }
        if flags.isEmpty, key.code == kVK_Return || key.code == kVK_ANSI_KeypadEnter {
            model.chooseStackFromEditor(paste: false)
            return true
        }
        if flags == .option, key.code == kVK_Return || key.code == kVK_ANSI_KeypadEnter {
            model.chooseStackFromEditor(paste: true)
            return true
        }
        if flags.isEmpty, key.code == kVK_Space, let id = state.selectedID {
            model.openRecord(id)
            return true
        }
        return false
    }
}

private extension Notification.Name {
    static let stackEditorToggleInspector = Notification.Name("MemopilaStackEditorToggleInspector")
}

/// Card grid + right inspector (same pattern as Edit Record).
private struct StackEditorView: View {
    let model: AppModel
    @Bindable var state: StackEditorState
    @AppStorage("stackInspectorShown") private var showsInspector = true
    @State private var width: CGFloat = 1_000
    @State private var showsInspectorWhenNarrow = false
    @FocusState private var titleFocused: Bool

    private static let spacing: CGFloat = 10
    private static let columns = 3
    private static let rows: CGFloat = 3
    private static let inspectorWidth: CGFloat = 260
    private static let inspectorMinWidth: CGFloat = 780

    private var isNarrow: Bool { width < Self.inspectorMinWidth }
    private var inspectorVisible: Bool { isNarrow ? showsInspectorWhenNarrow : showsInspector }

    private func toggleInspector() {
        if isNarrow { showsInspectorWhenNarrow.toggle() } else { showsInspector.toggle() }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                memberGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspectorVisible {
                    Divider()
                    inspector
                        .frame(width: Self.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: inspectorVisible)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: isNarrow) { _, _ in showsInspectorWhenNarrow = false }
        .onReceive(NotificationCenter.default.publisher(for: .stackEditorToggleInspector)) { _ in
            toggleInspector()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let _ = model.stackStatusRevision
        return HStack(spacing: 4) {
            Text(state.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 4)

            if model.stackSession.armedStackID == state.stackID,
               let progress = model.stackSession.progressLabel {
                Label(String(localized: "Armed \(progress)"), systemImage: "bolt.fill")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .padding(.leading, 4)
                    .floatingHelp(String(localized: "This stack is armed — ⌘V pastes the next member"))
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                TextField(String(localized: "Filter members"), text: $state.search)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 160)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Button {
                toggleInspector()
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolbarIconStyle(emphasized: inspectorVisible))
            .floatingHelp(inspectorVisible
                ? String(localized: "Hide stack details (⌥⌘I)")
                : String(localized: "Show stack details (⌥⌘I)"))
            .accessibilityLabel(Text("Inspector"))

            Button { model.chooseStackFromEditor(paste: false) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                    ShortcutLabel(title: String(localized: "Choose Stack"), shortcut: "↩")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .floatingHelp(String(localized: "Put the first member on the clipboard and arm the stack (↩)"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Inspector (right drawer)

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorSection(String(localized: "Title"), systemImage: "textformat") {
                    TextField(String(localized: "Stack title"), text: titleBinding)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .floatingHelp(String(localized: "Shown on the stack card and found by search"))
                }

                Divider()

                inspectorSection(String(localized: "Deal"), systemImage: "rectangle.stack") {
                    VStack(alignment: .leading, spacing: 4) {
                        dealOption(
                            String(localized: "In order"),
                            systemImage: ActionRegistry.dealSymbol(mode: .sequential),
                            mode: .sequential,
                            help: String(localized: "Paste members in the order shown here")
                        )
                        dealOption(
                            String(localized: "Shuffle"),
                            systemImage: ActionRegistry.dealSymbol(mode: .shuffleBag),
                            mode: .shuffleBag,
                            help: String(localized: "Shuffle once at Choose, then paste through that order")
                        )
                        dealOption(
                            String(localized: "Random"),
                            systemImage: ActionRegistry.dealSymbol(mode: .shuffleRandom),
                            mode: .shuffleRandom,
                            help: String(localized: "Pick a random member each paste; never runs out")
                        )
                        loopButton
                            .padding(.top, 4)
                    }
                }

                Divider()

                inspectorSection(String(localized: "Stack"), systemImage: "rectangle.stack.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        favoriteButton
                        Label(
                            String(localized: "\(state.totalMemberCount) members"),
                            systemImage: "square.stack.3d.up"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .floatingHelp(String(localized: "How many cards are in this stack"))
                        if state.isTruncated {
                            Label(
                                String(localized: "Showing the first \(state.order.count) — reorder is off for this size."),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Label(
                            String(localized: "Drop history cards onto this window to add them. Pin the panel to drag from History."),
                            systemImage: "hand.draw"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .floatingHelp(String(localized: "Pin the panel, open this stack, then drag cards from History into the grid"))
                    }
                }

                if let card = state.selectedCard {
                    Divider()
                    inspectorSection(String(localized: "Selected"), systemImage: "checkmark.square") {
                        selectedMemberActions(card)
                    }
                }

                Divider()

                Button {
                    model.deleteStack(state.stackID)
                } label: {
                    Label(String(localized: "Delete Stack"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .floatingHelp(String(localized: "Delete this stack; its cards stay in History"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            content()
        }
    }

    private var favoriteButton: some View {
        Button {
            model.toggleStackFavorite(state.stackID)
        } label: {
            inspectorRow(
                title: String(localized: "Favorites"),
                systemImage: state.stack.isFavorite ? "heart.fill" : "heart",
                tint: state.stack.isFavorite ? .pink : .secondary,
                emphasized: state.stack.isFavorite
            )
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: state.stack.isFavorite)
        .floatingHelp(state.stack.isFavorite
            ? String(localized: "Remove from Favorites (⌘D)")
            : String(localized: "Add to Favorites (⌘D)"))
        .accessibilityLabel(Text(state.stack.isFavorite
            ? String(localized: "Remove from Favorites")
            : String(localized: "Add to Favorites")))
    }

    private var loopButton: some View {
        let on = state.stack.loops
        let random = state.stack.dealMode == .shuffleRandom
        return Button {
            guard !random else { return }
            model.setStackDeal(state.stackID, mode: state.stack.dealMode, loops: !on)
        } label: {
            inspectorRow(
                title: String(localized: "Loop"),
                systemImage: "repeat",
                tint: on && !random ? .accentColor : .secondary,
                emphasized: on && !random
            )
        }
        .buttonStyle(.plain)
        .disabled(random)
        .floatingHelp(random
            ? String(localized: "Not available for Random — each paste already picks freely")
            : String(localized: "Start again when the round ends"))
    }

    private func dealOption(
        _ title: String,
        systemImage: String,
        mode: StackDealMode,
        help: String
    ) -> some View {
        let selected = state.stack.dealMode == mode
        return Button {
            let loops = mode == .shuffleRandom ? false : state.stack.loops
            model.setStackDeal(state.stackID, mode: mode, loops: loops)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .floatingHelp(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func inspectorRow(
        title: String,
        systemImage: String,
        tint: Color,
        emphasized: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(tint)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            emphasized ? tint.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func selectedMemberActions(_ card: HistoryCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.customTitle ?? card.preview)
                .lineLimit(3)
                .font(.callout)
            if let pos = state.position(of: card.id) {
                Text(String(localized: "Position \(pos) · first is pasted first"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Primary job: independent copy in this playlist, then edit it.
            Button {
                model.duplicateInStack(card.id, stackID: state.stackID)
            } label: {
                Label(String(localized: "Duplicate & Edit"), systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .floatingHelp(String(localized: "Insert a copy after this card and open it to edit. The original stays."))

            Button {
                model.openRecord(card.id)
            } label: {
                Label(String(localized: "Edit Original"), systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .floatingHelp(String(localized: "Edit this shared history card (Space). Changes apply everywhere it appears."))

            Menu {
                StackMemberMoveMenu(cardID: card.id, model: model)
            } label: {
                Label(String(localized: "Move"), systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .floatingHelp(String(localized: "Change this card’s place in the order"))

            Button(role: .destructive) {
                model.removeRecord(card.id, fromStack: state.stackID)
            } label: {
                Label(String(localized: "Remove from Stack"), systemImage: "minus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .floatingHelp(String(localized: "Take this card out of the stack; it stays in History"))
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { state.stack.title },
            set: { newValue in
                state.applyTitle(newValue)
                model.renameStack(state.stackID, title: newValue)
            }
        )
    }

    // MARK: Card grid

    private var memberGrid: some View {
        Group {
            if let error = state.loadError {
                ContentUnavailableView {
                    Label(error, systemImage: "exclamationmark.triangle")
                }
            } else if state.order.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Empty stack"), systemImage: "rectangle.stack")
                } description: {
                    Text(String(localized: "Drop history cards here to add them. Pin the panel to drag from History."))
                }
                .padding(Self.spacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if model.stackDrag.appendHighlight == .editor {
                        dropPlaceholderChrome()
                    }
                }
                .onDrop(
                    of: [.item, .text, .plainText, .utf8PlainText, .image, .fileURL],
                    delegate: StackEditorAppendDropDelegate(model: model)
                )
            } else if state.visibleMembers.isEmpty {
                ContentUnavailableView.search
            } else {
                GeometryReader { geometry in
                    let cardHeight = max(
                        56,
                        (geometry.size.height - Self.spacing * (Self.rows + 1)) / Self.rows
                    )
                    ScrollView {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: Self.spacing),
                                count: Self.columns
                            ),
                            spacing: Self.spacing
                        ) {
                            ForEach(Array(state.visibleMembers.enumerated()), id: \.element.id) { index, card in
                                memberCard(card, index: index, cardHeight: cardHeight)
                            }
                            // Reserve End while reordering so the grid does not jump each hover.
                            if state.canReorder,
                               model.stackDrag.isPositionalReorder,
                               model.stackDrag.reorderDragID != nil {
                                let endActive = model.stackDrag.reorderGap == .end
                                dropPlaceholder(
                                    title: String(localized: "End"),
                                    systemImage: "arrow.down.to.line",
                                    accessibility: String(localized: "Move to end of stack"),
                                    help: String(localized: "Drop here to move the card to the end of the stack"),
                                    emphasized: endActive
                                )
                                .frame(height: cardHeight)
                                .opacity(endActive ? 1 : 0.35)
                                .onDrop(
                                    of: [.item, .text, .plainText, .utf8PlainText, .image, .fileURL],
                                    delegate: StackEditorEndDropDelegate(model: model)
                                )
                            } else if model.stackDrag.appendHighlight == .editor {
                                dropPlaceholder(
                                    title: String(localized: "Add"),
                                    systemImage: "plus",
                                    accessibility: String(localized: "Add to stack"),
                                    help: String(localized: "Drop here to add the card to this stack")
                                )
                                .frame(height: cardHeight)
                                .onDrop(
                                    of: [.item, .text, .plainText, .utf8PlainText, .image, .fileURL],
                                    delegate: StackEditorAppendDropDelegate(model: model)
                                )
                            }
                        }
                        // No layout animation on reorderGap — phantom cells made cards fly.
                        .padding(Self.spacing)
                        .onDrop(
                            of: [.item, .text, .plainText, .utf8PlainText, .image, .fileURL],
                            delegate: StackEditorAppendDropDelegate(model: model)
                        )
                    }
                }
            }
        }
    }

    private func dropPlaceholderChrome(emphasized: Bool = true) -> some View {
        let radius: CGFloat = 9
        let stroke: CGFloat = emphasized ? 3 : 1.5
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.accentColor.opacity(emphasized ? 0.10 : 0.04))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(emphasized ? 1 : 0.55),
                        style: StrokeStyle(lineWidth: stroke, dash: emphasized ? [] : [6, 4])
                    )
            }
    }

    /// Insert-before marker in the column gutter (same as Favorites pinboard — no grid reflow).
    @ViewBuilder
    private func reorderInsertOverlay(active: Bool) -> some View {
        if active {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(24, geo.size.height - 16))
                    .position(x: -Self.spacing / 2, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
            .accessibilityLabel(Text("Insert before this card"))
        }
    }

    private func dropPlaceholder(
        title: String,
        systemImage: String,
        accessibility: String,
        help: String,
        emphasized: Bool = true
    ) -> some View {
        dropPlaceholderChrome(emphasized: emphasized)
            .overlay {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor.opacity(emphasized ? 1 : 0.7))
            }
            .accessibilityLabel(Text(accessibility))
            .floatingHelp(help)
    }

    @ViewBuilder
    private func memberCard(_ card: HistoryCard, index: Int, cardHeight: CGFloat) -> some View {
        let selected = state.selectedID == card.id
        let dragging = model.stackDrag.reorderDragID == .record(card.id)
        let insertBefore = model.stackDrag.reorderGap == .before(.record(card.id))
        let memberMenu = StackMemberContextMenu(cardID: card.id, stackID: state.stackID, model: model)
        CardView(
            card: card,
            index: index,
            hasCursor: selected,
            model: model,
            onDoubleClick: { model.openRecord(card.id) },
            moreMenu: AnyView(memberMenu)
        )
        .opacity(dragging ? 0.35 : 1)
        .frame(height: cardHeight)
        .overlay { reorderInsertOverlay(active: insertBefore) }
        .simultaneousGesture(TapGesture().onEnded {
            state.select(card.id)
            // Surface the Selected inspector so Duplicate & Edit is one click away.
            if !inspectorVisible { toggleInspector() }
        })
        .onDrag {
            if state.canReorder {
                model.beginStackEditorDrag(card.id)
            } else {
                model.beginCardDrag(card.id)
            }
            return DragSupport.provider(for: card, store: model.store)
        }
        .onDrop(
            of: [.item, .text, .plainText, .utf8PlainText, .image, .fileURL],
            delegate: StackEditorMemberDropDelegate(targetID: card.id, model: model)
        )
        .contextMenu { memberMenu }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Label(statusText, systemImage: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(String(localized: "↩ Choose · Space Edit · ⌥⌘I Inspector · Esc close"))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var statusText: String {
        let n = state.totalMemberCount
        let visible = state.visibleMembers.count
        if state.isTruncated {
            return String(localized: "\(visible) of \(n) members · reorder off")
        }
        if !state.search.isEmpty {
            return String(localized: "\(visible) of \(n) members")
        }
        return String(localized: "\(n) members")
    }
}

/// Compact title + shortcut, same idea as Record's Choose button.
private struct ShortcutLabel: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut)
                .foregroundStyle(.secondary)
                .font(.caption.monospaced())
        }
    }
}

/// Stack Window member actions SSOT — ⋯ menu, right-click, and Selected inspector share this.
private struct StackMemberContextMenu: View {
    let cardID: UUID
    let stackID: UUID
    let model: AppModel

    var body: some View {
        Button {
            model.duplicateInStack(cardID, stackID: stackID)
        } label: {
            Label(String(localized: "Duplicate & Edit"), systemImage: "plus.square.on.square")
        }
        Button {
            model.openRecord(cardID)
        } label: {
            Label(String(localized: "Edit Original"), systemImage: "pencil")
        }
        Menu {
            StackMemberMoveMenu(cardID: cardID, model: model)
        } label: {
            Label(String(localized: "Move"), systemImage: "arrow.up.arrow.down")
        }
        Divider()
        Button(String(localized: "Remove from Stack"), role: .destructive) {
            model.removeRecord(cardID, fromStack: stackID)
        }
    }
}

private struct StackMemberMoveMenu: View {
    let cardID: UUID
    let model: AppModel

    var body: some View {
        Button { model.moveStackEditorMember(cardID, toStart: true) } label: {
            Label(String(localized: "Move to Top"), systemImage: "arrow.up.to.line")
        }
        Button { model.moveStackEditorMember(cardID, by: -1) } label: {
            Label(String(localized: "Move Up"), systemImage: "arrow.up")
        }
        Button { model.moveStackEditorMember(cardID, by: 1) } label: {
            Label(String(localized: "Move Down"), systemImage: "arrow.down")
        }
        Button { model.moveStackEditorMember(cardID, toStart: false) } label: {
            Label(String(localized: "Move to Bottom"), systemImage: "arrow.down.to.line")
        }
    }
}

private struct StackEditorMemberDropDelegate: DropDelegate {
    let targetID: UUID
    let model: AppModel

    private var canReorderHere: Bool {
        guard model.stackDrag.isPositionalReorder,
              let state = model.stackEditor, state.canReorder,
              let from = model.stackDrag.recordID,
              from != targetID else { return false }
        return true
    }

    private var canAppendHere: Bool {
        guard let state = model.stackEditor,
              model.stackDrag.isFresh,
              !model.stackDrag.isPositionalReorder,
              let id = model.stackDrag.recordID,
              !state.order.contains(id) else { return false }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        canReorderHere || canAppendHere
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if canReorderHere {
            model.stackDrag.setAppendHighlight(nil)
            model.stackDrag.setReorderGap(.before(.record(targetID)))
            return DropProposal(operation: .move)
        }
        if canAppendHere {
            model.stackDrag.setReorderGap(nil)
            model.stackDrag.setAppendHighlight(.editor)
            return DropProposal(operation: .copy)
        }
        model.stackDrag.setAppendHighlight(nil)
        return DropProposal(operation: .cancel)
    }

    func dropExited(info: DropInfo) {
        if model.stackDrag.appendHighlight == .editor {
            model.stackDrag.setAppendHighlight(nil)
        }
        if model.stackDrag.reorderGap == .before(.record(targetID)) {
            model.stackDrag.setReorderGap(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if canReorderHere {
            return model.dropStackEditorReorder(before: targetID, atEnd: false)
        }
        return model.dropOntoOpenStackEditor()
    }
}

private struct StackEditorEndDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        model.stackDrag.isPositionalReorder && (model.stackEditor?.canReorder ?? false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .cancel) }
        model.stackDrag.setReorderGap(.end)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.stackDrag.reorderGap == .end {
            model.stackDrag.setReorderGap(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dropStackEditorReorder(before: nil, atEnd: true)
    }
}

/// Membership append onto empty state / grid chrome (panel stays when pinned).
private struct StackEditorAppendDropDelegate: DropDelegate {
    let model: AppModel

    private var canAppend: Bool {
        guard let state = model.stackEditor,
              model.stackDrag.isFresh,
              !model.stackDrag.isPositionalReorder,
              let id = model.stackDrag.recordID,
              !state.order.contains(id) else { return false }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool { canAppend }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if canAppend {
            model.stackDrag.setAppendHighlight(.editor)
            return DropProposal(operation: .copy)
        }
        model.stackDrag.setAppendHighlight(nil)
        return DropProposal(operation: .cancel)
    }

    func dropExited(info: DropInfo) {
        if model.stackDrag.appendHighlight == .editor {
            model.stackDrag.setAppendHighlight(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dropOntoOpenStackEditor()
    }
}
