import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

/// One action with its availability (PLAN §8.4). The context menu, the ⌘K panel, the Apps sidebar
/// menu and the red card all build from these lists, so they always match.
struct ActionItem: Identifiable {
    let id: String
    var title: String
    var systemImage: String?
    var shortcut: String?
    /// `nil` = enabled; otherwise shown disabled with this reason as the tooltip.
    var disabledReason: String?
    /// When set, the menu row is a macOS checkmark toggle (membership / deal mode), not a leading icon.
    var isChecked: Bool? = nil
    var isDestructive = false
    var children: [ActionItem] = []
    var isDivider = false
    var run: (@MainActor () -> Void)?

    var isEnabled: Bool { disabledReason == nil }

    static func divider(_ id: String) -> ActionItem {
        ActionItem(id: "divider." + id, title: "", isDivider: true)
    }

    /// Leaves with their menu path, for the ⌘K panel. A disabled submenu disables its leaves.
    func flattened(prefix: String = "", inheritedReason: String? = nil) -> [ActionItem] {
        guard !isDivider else { return [] }
        let path = prefix.isEmpty ? title : prefix + " ▸ " + title
        let reason = disabledReason ?? inheritedReason
        guard children.isEmpty else { return children.flatMap { $0.flattened(prefix: path, inheritedReason: reason) } }
        var leaf = self
        leaf.title = path
        leaf.disabledReason = reason
        return [leaf]
    }
}

@MainActor
enum ActionRegistry {
    // MARK: Card (§8.4)

    /// The card menu, also used by the ⌘K panel: actions that do not apply are left out, not
    /// shown disabled, so the menu stays short.
    static func cardActions(_ card: HistoryCard, model: AppModel) -> [ActionItem] {
        let id = card.id
        // The same as a double-click (§3.4): the record becomes what the clipboard holds (the selected
        // card) and the focus goes back to the app.
        var items: [ActionItem] = [
            ActionItem(id: "choose", title: String(localized: "Choose for Clipboard"), systemImage: "checkmark.circle", shortcut: "↩") {
                model.restore(id)
            },
            // Once, without turning on auto-paste in Settings.
            ActionItem(id: "choose.paste", title: String(localized: "Choose and Paste"), systemImage: "doc.on.clipboard", shortcut: "⌥↩") {
                model.restore(id, paste: true)
            },
            ActionItem(
                id: "favorite",
                title: card.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                systemImage: card.isFavorite ? "heart.slash" : "heart",
                shortcut: "⌘D"
            ) { model.toggleFavorite(id) },
        ]
        // Inside a collection, taking the card out of it is one click.
        if case .collection(let collectionID) = model.history.scope,
           model.history.memberships[id]?.contains(collectionID) == true,
           let collection = model.history.collections.first(where: { $0.id == collectionID }) {
            items.append(ActionItem(
                id: "collection.removeCurrent",
                title: String(localized: "Remove from “\(collection.name)”"),
                systemImage: "folder.badge.minus"
            ) { model.setMembership(id, collection: collectionID, isMember: false) })
        }
        items += [
            collectionsMenu(for: card, model: model),
            stacksMenu(for: card, model: model),
        ]
        items += [
            .divider("view"),
            // One window to look at a record and edit its title and text (§8.5).
            ActionItem(id: "edit", title: String(localized: "Edit Record"), systemImage: "pencil", shortcut: "⌘E") {
                model.openRecord(id)
            },
        ]
        items.append(ActionItem(id: "rename", title: String(localized: "Rename…"), systemImage: "tag", shortcut: "⌘R") {
            model.present(.rename(.record(id)))
        })
        if let duplicate = duplicateMenu(for: card, model: model) { items.append(duplicate) }

        var open: [ActionItem] = []
        if let url = card.sourceURL.flatMap(URL.init(string:)) {
            open.append(ActionItem(id: "source", title: String(localized: "Open Source Page"), systemImage: "safari") {
                // `SourcePage` already allowed http / https / file — announce so floating windows step down.
                External.open(url)
            })
        }
        if !card.filePaths.isEmpty {
            // Existence is checked when the action runs, not while every card's menu is built.
            let paths = card.filePaths
            open.append(ActionItem(id: "reveal", title: String(localized: "Reveal in Finder"), systemImage: "folder") {
                // Network files are left to Finder: checking them could block (review finding).
                let existing = paths.filter { !FileVolumes.isLocal($0) || FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                if existing.isEmpty {
                    model.toasts.error(String(localized: "The file is no longer available."))
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(existing)
                }
            })
            // The full path as text: to the clipboard and into history, as Copy Text does.
            open.append(ActionItem(
                id: "copyPath",
                title: paths.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path"),
                systemImage: "doc.on.clipboard"
            ) { model.copyNewText(paths.joined(separator: "\n"), from: id) })
        }
        if !open.isEmpty { items += [.divider("open")] + open }

        if let bundleID = card.sourceAppBundleID {
            items.append(.divider("app"))
            items.append(appMenu(
                bundleID: bundleID,
                fallbackName: card.sourceAppName,
                storedTypes: card.storedTypes,
                skippedTypes: card.skippedTypes,
                deleting: id,
                model: model
            ))
        }
        items.append(.divider("delete"))
        items.append(ActionItem(id: "delete", title: String(localized: "Delete"), systemImage: "trash", shortcut: "⌘⌫", isDestructive: true) {
            model.delete([id])
        })
        return items
    }

    /// Several selected cards: favorites, collections and delete for all of them. *Choose for
    /// Clipboard* stays so that it can say why it does not apply: the clipboard holds one record.
    static func selectionActions(_ entryIDs: [HistoryEntry.ID], model: AppModel) -> [ActionItem] {
        let ids = entryIDs.compactMap { if case .record(let id) = $0 { return id }; return nil }
        let cards = model.history.cards.filter { ids.contains($0.id) }
        let count = entryIDs.count
        let allFavorites = !cards.isEmpty && cards.allSatisfy(\.isFavorite)
        let collections = model.history.collections.map { collection in
            let allIn = !ids.isEmpty && ids.allSatisfy { model.history.memberships[$0]?.contains(collection.id) == true }
            return ActionItem(
                id: "selection.collection." + collection.id.uuidString,
                title: collection.name,
                isChecked: allIn
            ) { model.setMembership(ids, collection: collection.id, isMember: !allIn) }
        }
        var items: [ActionItem] = [
            ActionItem(id: "selection.choose", title: String(localized: "Choose for Clipboard"), systemImage: "checkmark.circle", shortcut: "↩") {
                model.restoreSelected()
            },
        ]
        if !ids.isEmpty {
            items.append(ActionItem(
                id: "selection.stack",
                title: String(localized: "New Stack…"),
                systemImage: "rectangle.stack"
            ) { model.presentNewStack(records: ids) })
            items.append(ActionItem(
                id: "selection.favorites",
                title: allFavorites ? String(localized: "Remove \(ids.count) from Favorites") : String(localized: "Add \(ids.count) to Favorites"),
                systemImage: allFavorites ? "heart.slash" : "heart",
                shortcut: "⌘D"
            ) { model.toggleFavorites(ids) })
        }
        if !collections.isEmpty, !ids.isEmpty {
            items.append(ActionItem(
                id: "selection.collections",
                title: String(localized: "Add \(ids.count) to Collection"),
                systemImage: "folder.badge.plus",
                children: collections
            ))
        }
        items.append(.divider("selection.delete"))
        items.append(ActionItem(
            id: "selection.delete",
            title: String(localized: "Delete \(count) Items"),
            systemImage: "trash",
            shortcut: "⌘⌫",
            isDestructive: true
        ) { model.deleteSelection() })
        return items
    }

    static func stackActions(_ stack: StackCard, model: AppModel) -> [ActionItem] {
        let id = stack.id
        var items: [ActionItem] = [
            ActionItem(id: "stack.open", title: String(localized: "Edit Stack…"), systemImage: "rectangle.stack") {
                model.openStackEditor(id)
            },
            ActionItem(id: "stack.choose", title: String(localized: "Choose Stack"), systemImage: "checkmark.circle", shortcut: "↩") {
                model.chooseStack(id)
            },
            ActionItem(id: "stack.choose.paste", title: String(localized: "Choose and Paste"), systemImage: "doc.on.clipboard", shortcut: "⌥↩") {
                model.chooseStack(id, paste: true)
            },
            ActionItem(
                id: "stack.favorite",
                title: stack.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                systemImage: stack.isFavorite ? "heart.slash" : "heart",
                shortcut: "⌘D"
            ) { model.toggleStackFavorite(id) },
            ActionItem(id: "stack.rename", title: String(localized: "Rename…"), systemImage: "tag", shortcut: "⌘R") {
                model.present(.rename(.stack(id)))
            },
            stackDealMenu(for: stack, model: model),
            stackCollectionsMenu(for: stack, model: model),
        ]
        items.append(.divider("stack.delete"))
        items.append(ActionItem(
            id: "stack.delete",
            title: String(localized: "Delete Stack"),
            systemImage: "trash",
            shortcut: "⌘⌫",
            isDestructive: true
        ) { model.deleteStack(id) })
        return items
    }

    /// Deal mode + Loop in one submenu. Parent shows the scalar value; rows keep checkmarks (§3.11).
    private static func stackDealMenu(for stack: StackCard, model: AppModel) -> ActionItem {
        let id = stack.id
        var children: [ActionItem] = [
            ActionItem(
                id: "stack.deal.sequential",
                title: String(localized: "In order"),
                isChecked: stack.dealMode == .sequential
            ) { model.setStackDeal(id, mode: .sequential, loops: stack.loops) },
            ActionItem(
                id: "stack.deal.shuffle",
                title: String(localized: "Shuffle"),
                isChecked: stack.dealMode == .shuffleBag
            ) { model.setStackDeal(id, mode: .shuffleBag, loops: stack.loops) },
            ActionItem(
                id: "stack.deal.random",
                title: String(localized: "Random"),
                isChecked: stack.dealMode == .shuffleRandom
            ) { model.setStackDeal(id, mode: .shuffleRandom, loops: false) },
            .divider("stack.loop"),
        ]
        if stack.dealMode == .shuffleRandom {
            children.append(ActionItem(
                id: "stack.loop",
                title: String(localized: "Loop"),
                disabledReason: String(localized: "Not available for Random"),
                isChecked: false
            ))
        } else {
            children.append(ActionItem(
                id: "stack.loop",
                title: String(localized: "Loop"),
                isChecked: stack.loops
            ) { model.setStackDeal(id, mode: stack.dealMode, loops: !stack.loops) })
        }
        return ActionItem(
            id: "stack.deal",
            title: submenuTitle(String(localized: "Deal"), dealState(mode: stack.dealMode, loops: stack.loops)),
            systemImage: "arrow.triangle.2.circlepath",
            children: children
        )
    }

    /// Compact parent cue: noun alone when empty; `Noun · state` otherwise (never a name list).
    private static func submenuTitle(_ noun: String, _ state: String?) -> String {
        guard let state, !state.isEmpty else { return noun }
        return String(localized: "\(noun) · \(state)")
    }

    static func dealState(mode: StackDealMode, loops: Bool) -> String {
        let modeName: String = switch mode {
        case .sequential: String(localized: "In order")
        case .shuffleBag: String(localized: "Shuffle")
        case .shuffleRandom: String(localized: "Random")
        }
        if loops, mode != .shuffleRandom {
            return String(localized: "\(modeName) · \(String(localized: "Loop"))")
        }
        return modeName
    }

    /// *Duplicate As ▸*: a new card with transformed text appears at the top; the original stays.
    private static func duplicateMenu(for card: HistoryCard, model: AppModel) -> ActionItem? {
        let id = card.id
        var children: [ActionItem] = []
        if card.hasText, card.displayType != .text {
            children.append(ActionItem(id: "duplicate.plain", title: String(localized: "Plain Text, No Formatting"), systemImage: "textformat") {
                model.duplicate(id, as: .plainText)
            })
        }
        if card.hasRecognizedText {
            children.append(ActionItem(id: "duplicate.ocr", title: String(localized: "Text from Image"), systemImage: "text.viewfinder") {
                model.duplicate(id, as: .recognizedText)
            })
        }
        if card.hasText {
            if !children.isEmpty { children.append(.divider("duplicate.text")) }
            children += textActions(for: card) { action in model.duplicate(id, as: .textAction(action)) }
        }
        guard !children.isEmpty else { return nil }
        return ActionItem(id: "duplicate", title: String(localized: "Duplicate As"), systemImage: "plus.square.on.square", children: children)
    }

    static func textActions(for card: HistoryCard, run: @escaping @MainActor (TextAction) -> Void) -> [ActionItem] {
        // The card preview is the whole text when the counts match, so availability is exact;
        // for longer text an action that does not apply reports it when run.
        let text = card.textLength == card.preview.count ? card.preview : nil
        return TextAction.allCases.map { action in
            let available = text.map(action.isAvailable(for:)) ?? true
            return ActionItem(
                id: "textAction." + action.rawValue,
                title: action.title,
                disabledReason: available ? nil : action.unavailableReason
            ) { run(action) }
        }
    }

    /// Membership: card badges name *which*; parent shows *count*; rows keep checkmarks (§3.11).
    private static func stacksMenu(for card: HistoryCard, model: AppModel) -> ActionItem {
        let id = card.id
        let stacks = model.history.allStacks
        let memberCount = stacks.filter { $0.memberIDs.contains(id) }.count
        var children = stacks.map { stack in
            let isMember = stack.memberIDs.contains(id)
            let title = stack.title.isEmpty ? String(localized: "Stack") : stack.title
            return ActionItem(
                id: "stack.member." + stack.id.uuidString,
                title: title,
                isChecked: isMember
            ) {
                if isMember {
                    model.removeRecord(id, fromStack: stack.id)
                } else {
                    model.addRecord(id, toStack: stack.id)
                }
            }
        }
        if !children.isEmpty { children.append(.divider("newStack")) }
        children.append(ActionItem(
            id: "stack.new",
            title: String(localized: "New Stack…"),
            systemImage: "plus"
        ) { model.presentNewStack(records: [id]) })
        return ActionItem(
            id: "stacks",
            title: submenuTitle(String(localized: "Stacks"), memberCount > 0 ? "\(memberCount)" : nil),
            systemImage: memberCount > 0 ? "rectangle.stack.fill" : "rectangle.stack.badge.plus",
            children: children
        )
    }

    private static func collectionsMenu(for card: HistoryCard, model: AppModel) -> ActionItem {
        let id = card.id
        let members = model.history.memberships[id] ?? []
        let memberCount = members.count
        var children = model.history.collections.map { collection in
            let isMember = members.contains(collection.id)
            return ActionItem(
                id: "collection." + collection.id.uuidString,
                title: collection.name,
                isChecked: isMember
            ) { model.setMembership(id, collection: collection.id, isMember: !isMember) }
        }
        if !children.isEmpty { children.append(.divider("newCollection")) }
        children.append(ActionItem(id: "collection.new", title: String(localized: "New Collection…"), systemImage: "plus") {
            model.present(.newCollection(addingRecord: id))
        })
        return ActionItem(
            id: "collections",
            title: submenuTitle(String(localized: "Collections"), memberCount > 0 ? "\(memberCount)" : nil),
            systemImage: memberCount > 0 ? "folder.fill" : "folder.badge.plus",
            children: children
        )
    }

    private static func stackCollectionsMenu(for stack: StackCard, model: AppModel) -> ActionItem {
        let id = stack.id
        let members = stack.collectionIDs
        let memberCount = members.count
        var children = model.history.collections.map { collection in
            let isMember = members.contains(collection.id)
            return ActionItem(
                id: "stack.collection." + collection.id.uuidString,
                title: collection.name,
                isChecked: isMember
            ) { model.setStackMembership(stack: id, collection: collection.id, isMember: !isMember) }
        }
        return ActionItem(
            id: "stack.collections",
            title: submenuTitle(String(localized: "Collections"), memberCount > 0 ? "\(memberCount)" : nil),
            systemImage: memberCount > 0 ? "folder.fill" : "folder.badge.plus",
            children: children.isEmpty
                ? [ActionItem(id: "stack.collection.empty", title: String(localized: "No collections yet"), disabledReason: String(localized: "Create a collection first."))]
                : children
        )
    }

    // MARK: <App> ▸ quick actions (§5.1)

    /// *Rules for <App> ▸* (§5.1).
    static func appMenu(
        bundleID: String,
        fallbackName: String?,
        storedTypes: [String],
        skippedTypes: [String],
        deleting recordID: UUID? = nil,
        model: AppModel
    ) -> ActionItem {
        let name = AppInfo.displayName(for: bundleID, fallback: fallbackName)
        return ActionItem(
            id: "app",
            title: String(localized: "Rules for \(name)"),
            systemImage: "slider.horizontal.3",
            children: appActions(bundleID: bundleID, name: name, storedTypes: storedTypes, skippedTypes: skippedTypes, deleting: recordID, model: model)
        )
    }

    static func appActions(
        bundleID: String,
        name: String,
        storedTypes: [String],
        skippedTypes: [String],
        deleting recordID: UUID? = nil,
        model: AppModel
    ) -> [ActionItem] {
        let settings = model.settings.settings(for: bundleID)
        var items: [ActionItem] = [
            ActionItem(
                id: "app.dontSave",
                title: String(localized: "Don't Save from \(name)"),
                systemImage: "hand.raised",
                disabledReason: settings.captureMode == .dontSave ? String(localized: "Already set") : nil
            ) { model.setCaptureMode(.dontSave, for: bundleID) },
            ActionItem(
                id: "app.deleteAfter",
                title: String(localized: "Delete from \(name) After"),
                systemImage: "clock",
                children: [15, 60, 1_440].map { minutes in
                    ActionItem(
                        id: "app.deleteAfter.\(minutes)",
                        title: RetentionText.duration(minutes: minutes),
                        isChecked: settings.retentionMinutes == minutes
                    ) { model.setCaptureMode(.deleteAfter(minutes: minutes), for: bundleID) }
                }
            ),
        ]
        let skippable = storedTypes.filter { !PasteboardType($0).isMetadataOnly }
        items.append(ActionItem(
            id: "app.skipFormat",
            title: String(localized: "Don't Save Format"),
            systemImage: "minus.circle",
            disabledReason: skippable.isEmpty ? String(localized: "No stored formats") : nil,
            children: skippable.map { type in
                ActionItem(id: "app.skipFormat." + type, title: FormatNames.name(type)) {
                    model.addFormatRule(FormatRule(appBundleID: bundleID, typePattern: type, action: .skip), app: name)
                }
            }
        ))
        items.append(ActionItem(
            id: "app.keepFormat",
            title: String(localized: "Keep Skipped Formats"),
            systemImage: "plus.circle",
            disabledReason: skippedTypes.isEmpty ? String(localized: "No formats were skipped") : nil,
            children: skippedTypes.map { type in
                ActionItem(id: "app.keepFormat." + type, title: FormatNames.name(type)) {
                    model.addFormatRule(FormatRule(appBundleID: bundleID, typePattern: type, action: .keep), app: name)
                }
            }
        ))
        items.append(raiseLimitMenu(bundleID: bundleID, name: name, model: model))
        items.append(ActionItem(
            id: "app.recognize",
            title: String(localized: "Recognize Text in Images from \(name)"),
            isChecked: settings.recognizeText
        ) { model.setRecognition(!settings.recognizeText, for: bundleID, name: name) })
        if let recordID {
            items.append(.divider("app.delete"))
            items.append(ActionItem(
                id: "app.deleteDontSave",
                title: String(localized: "Delete This and Stop Saving from \(name)"),
                systemImage: "hand.raised",
                isDestructive: true
            ) { model.deleteAndDontSave(recordID, bundleID: bundleID) })
        }
        items.append(.divider("app.settings"))
        if settings.captureMode != .save {
            items.append(ActionItem(id: "app.save", title: String(localized: "Save from \(name) Again"), systemImage: "arrow.uturn.backward") {
                model.setCaptureMode(.save, for: bundleID)
            })
        }
        items.append(ActionItem(id: "app.settings", title: String(localized: "\(name) Settings…"), systemImage: "gearshape") {
            model.openSettings(.apps, app: bundleID)
        })
        return items
    }

    static func raiseLimitMenu(bundleID: String, name: String, model: AppModel) -> ActionItem {
        let current = model.settings.settings(for: bundleID).sizeLimitMiB ?? model.settings.maxItemMiB
        return ActionItem(
            id: "app.raiseLimit",
            title: String(localized: "Raise Size Limit for \(name)"),
            systemImage: "arrow.up.circle",
            children: [64, 128, 256].map { mib in
                ActionItem(
                    id: "app.raiseLimit.\(mib)",
                    title: "\(mib) MB",
                    disabledReason: mib <= current ? String(localized: "Not above the current limit") : nil
                ) { model.setSizeLimit(mib, for: bundleID, name: name) }
            }
        )
    }

    // MARK: Red Current card (§3.2.3)

    static func currentCardActions(_ current: CurrentClipboard, model: AppModel) -> [ActionItem] {
        guard let bundleID = current.change.identity.bundleID else {
            return [ActionItem(id: "app", title: String(localized: "App"), disabledReason: String(localized: "App unknown"))]
        }
        let name = AppInfo.displayName(for: bundleID)
        var items: [ActionItem] = []
        if current.hasNoSupportedFormats {
            items.append(ActionItem(
                id: "current.keep",
                title: String(localized: "Keep Formats from \(name)"),
                children: current.change.declaredTypes.map { type in
                    ActionItem(id: "current.keep." + type.rawValue, title: FormatNames.name(type.rawValue)) {
                        model.addFormatRule(FormatRule(appBundleID: bundleID, typePattern: type.rawValue, action: .keep), app: name)
                    }
                }
            ))
        }
        if current.isTooLarge {
            items.append(raiseLimitMenu(bundleID: bundleID, name: name, model: model))
        }
        items.append(ActionItem(id: "current.dontSave", title: String(localized: "Don't Save from \(name)")) {
            model.setCaptureMode(.dontSave, for: bundleID)
        })
        items.append(ActionItem(id: "current.settings", title: String(localized: "\(name) Settings…")) {
            model.openSettings(.apps, app: bundleID)
        })
        return items
    }
}

struct ActionMenuItems: View {
    let items: [ActionItem]

    var body: some View {
        ForEach(items) { item in
            if item.isDivider {
                Divider()
            } else if !item.children.isEmpty {
                Menu {
                    ActionMenuItems(items: item.children)
                } label: {
                    label(for: item)
                }
                .disabled(!item.isEnabled)
            } else if item.isChecked != nil {
                // Native macOS menu checkmarks (same pattern as the record inspector).
                Toggle(isOn: Binding(
                    get: { item.isChecked == true },
                    set: { _ in item.run?() }
                )) {
                    Text(item.title)
                }
                .disabled(!item.isEnabled)
                .floatingHelp(item.disabledReason ?? "")
            } else {
                Button(role: item.isDestructive ? .destructive : nil) {
                    item.run?()
                } label: {
                    label(for: item)
                }
                .disabled(!item.isEnabled)
                // Context menus open from the floating panel: bare `.help` often never appears.
                .floatingHelp(item.disabledReason ?? "")
            }
        }
    }

    @ViewBuilder
    private func label(for item: ActionItem) -> some View {
        if let systemImage = item.systemImage {
            Label(item.title, systemImage: systemImage)
        } else {
            Text(item.title)
        }
    }
}

/// Readable names for common pasteboard types; others show the raw identifier.
enum FormatNames {
    /// The readable name and the identifier, for format rules.
    static func name(_ type: String) -> String {
        guard let name = known[type] else { return type }
        return "\(name) — \(type)"
    }

    /// The readable name alone (record details); unknown types keep their identifier.
    static func short(_ type: String) -> String {
        known[type] ?? type
    }

    private static let known: [String: String] = [
        PasteboardType.utf8PlainText.rawValue: "Plain text",
        PasteboardType.plainText.rawValue: "Plain text",
        PasteboardType.utf16PlainText.rawValue: "Plain text (UTF-16)",
        PasteboardType.rtf.rawValue: "Rich text (RTF)",
        PasteboardType.flatRTFD.rawValue: "Rich text with attachments (RTFD)",
        PasteboardType.html.rawValue: "HTML",
        PasteboardType.webArchive.rawValue: "Web archive",
        PasteboardType.url.rawValue: "Link",
        PasteboardType.fileURL.rawValue: "File",
        PasteboardType.filenames.rawValue: "File names",
        PasteboardType.png.rawValue: "PNG image",
        PasteboardType.tiff.rawValue: "TIFF image",
        PasteboardType.jpeg.rawValue: "JPEG image",
        PasteboardType.heic.rawValue: "HEIC image",
        PasteboardType.gif.rawValue: "GIF image",
        PasteboardType.pdf.rawValue: "PDF",
        PasteboardType.color.rawValue: "Color",
    ]
}

@MainActor
enum RetentionText {
    private static let days = formatter(.day)
    private static let hours = formatter(.hour)
    private static let minutes = formatter(.minute)

    static func duration(minutes value: Int) -> String {
        let formatter = value % 1_440 == 0 ? days : value % 60 == 0 ? hours : minutes
        return formatter.string(from: TimeInterval(value * 60)) ?? "\(value) min"
    }

    private static func formatter(_ unit: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [unit]
        return formatter
    }
}

/// Builds a card's menu only when SwiftUI shows it, not on every grid pass (§7.3).
struct CardContextMenu: View {
    let card: HistoryCard
    let model: AppModel

    var body: some View {
        let selection = model.history.selection
        if selection.count > 1, model.history.isSelected(.record(card.id)) {
            ActionMenuItems(items: ActionRegistry.selectionActions(selection, model: model))
        } else {
            ActionMenuItems(items: ActionRegistry.cardActions(card, model: model))
        }
    }
}

extension TextAction {
    var title: String {
        switch self {
        case .trimWhitespace: String(localized: "Trim Whitespace")
        case .removeLineBreaks: String(localized: "Remove Line Breaks")
        case .uppercase: String(localized: "UPPERCASE")
        case .lowercase: String(localized: "lowercase")
        case .titleCase: String(localized: "Title Case")
        case .sortLines: String(localized: "Sort Lines A→Z")
        case .removeDuplicateLines: String(localized: "Remove Duplicate Lines")
        case .formatJSON: String(localized: "Format JSON")
        case .minifyJSON: String(localized: "Minify JSON")
        case .urlEncode: String(localized: "URL-Encode")
        case .urlDecode: String(localized: "URL-Decode")
        case .base64Encode: String(localized: "Base64 Encode")
        case .base64Decode: String(localized: "Base64 Decode")
        }
    }

    var unavailableReason: String {
        switch self {
        case .removeLineBreaks, .sortLines, .removeDuplicateLines: String(localized: "Needs text with several lines.")
        case .formatJSON, .minifyJSON: String(localized: "The text is not valid JSON.")
        case .urlDecode: String(localized: "The text has no valid percent-encoding.")
        case .base64Decode: String(localized: "The text is not Base64 for UTF-8 text.")
        default: String(localized: "Not available for this text.")
        }
    }
}
