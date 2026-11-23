import AppKit
import MemopilaCore
import MemopilaServices
import UniformTypeIdentifiers

/// Dragging a card into another app, as in Pasta. Data is loaded from the store only when the drop
/// target asks for a type; file cards drag as their file.
enum DragSupport {
    /// Stack drag-out: current dealt while armed (clipboard), else first UI member. Card face stays first.
    /// Empty stacks still register plain text (title) so in-app pinboard reorder can start a drag session.
    /// - Parameter memberLooksLikeColor: dealt/preview member — when true, register colour UTI
    ///   (utf8-only stack drag left Color Wells empty while card drag worked).
    static func provider(
        for stack: StackCard,
        store: ClipboardStore,
        armedMemberID: UUID?,
        memberLooksLikeColor: Bool = false
    ) -> NSItemProvider {
        let memberID = (armedMemberID.flatMap { id in stack.memberIDs.contains(id) ? id : nil })
            ?? stack.previewRecordID
            ?? stack.memberIDs.first
        let provider = NSItemProvider()
        let title = stack.title.isEmpty ? "Stack" : stack.title
        guard let memberID else {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                completion(Data(title.utf8), nil)
                return nil
            }
            return provider
        }
        let typeIDs: [String] = memberLooksLikeColor
            ? [PasteboardType.color.rawValue, UTType.utf8PlainText.identifier]
            : [UTType.utf8PlainText.identifier]
        for type in typeIDs {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                let reply = Transfer(value: completion)
                Task {
                    do {
                        let payload = try await store.payload(for: memberID)
                        // Normalize before identity — raw CSS text / legacy UTI have nil identity.
                        if ColorPayload.identity(of: ColorPayload.normalized(payload.items)) != nil {
                            reply.value(data(of: type, in: payload), nil)
                        } else if PasteboardType.plainTextTypes.contains(PasteboardType(type)) {
                            reply.value(payload.text.map { Data($0.utf8) } ?? Data(title.utf8), nil)
                        } else {
                            reply.value(nil, nil)
                        }
                    } catch {
                        if PasteboardType.plainTextTypes.contains(PasteboardType(type)) {
                            reply.value(Data(title.utf8), nil)
                        } else {
                            reply.value(nil, error)
                        }
                    }
                }
                return nil
            }
        }
        return provider
    }

    static func provider(for card: HistoryCard, store: ClipboardStore) -> NSItemProvider {
        if card.displayType == .file, let path = card.filePaths.first {
            let url = URL(fileURLWithPath: path)
            // A network file drags as its address: reading it could block the drag (review finding).
            guard FileVolumes.isLocal(path) else { return NSItemProvider(object: url as NSURL) }
            if let provider = NSItemProvider(contentsOf: url) { return provider }
        }
        let provider = NSItemProvider()
        let id = card.id
        // Colour types from looksLikeColor / CSS preview — launch heal keeps caches aligned.
        let previewCSS = ColorValues(css: card.preview.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        let typeIDs: [String]
        if card.looksLikeColor || previewCSS {
            typeIDs = [
                PasteboardType.color.rawValue,
                UTType.utf8PlainText.identifier,
            ]
        } else {
            var types = card.storedTypes.filter { type in
                let pasteboardType = PasteboardType(type)
                return !pasteboardType.isFileReference && !pasteboardType.isMetadataOnly
                    && !type.contains(" ") && UTType(type) != nil
            }
            let plainText = UTType.utf8PlainText.identifier
            if card.hasText, !types.contains(plainText) { types.append(plainText) }
            typeIDs = types
        }
        for type in typeIDs {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                let reply = Transfer(value: completion)
                Task {
                    do {
                        let payload = try await store.payload(for: id)
                        reply.value(data(of: type, in: payload), nil)
                    } catch {
                        reply.value(nil, error)
                    }
                }
                return nil
            }
        }
        return provider
    }

    private static func data(of type: String, in payload: RestorePayload) -> Data? {
        // Prefer normalized identity (lone CSS / legacy UTI) — raw identity misses promotable text.
        let normalized = ColorPayload.normalized(payload.items)
        let items = ColorPayload.identity(of: normalized) == nil ? payload.items : normalized
        if let bytes = items.lazy.flatMap(\.representations).first(where: { $0.type.rawValue == type })?.bytes {
            return bytes
        }
        // Legacy storedTypes may still request utf16/plain; serve the canonical CSS string.
        if PasteboardType.plainTextTypes.contains(PasteboardType(type)) {
            return ColorPayload.pastePlainText(of: items).map { Data($0.utf8) }
                ?? payload.text.map { Data($0.utf8) }
        }
        return nil
    }
}
